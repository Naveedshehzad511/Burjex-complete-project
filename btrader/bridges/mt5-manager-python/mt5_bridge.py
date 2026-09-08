#!/usr/bin/env python3
"""
MT5 Manager API -> B-Trader feed bridge (Python).

Connects to your MT5 server with the official `MT5Manager` package, streams
ticks to B-Trader's /ingest endpoint and pushes OHLC history to /ingest/candles.
Same endpoints/contract as the EA bridge, so the B-Trader side is unchanged.

    MT5 server --Manager API--> this script --HTTPS--> feed.example.com
        ticks   -> POST /ingest          (batched)
        history -> POST /ingest/candles  (M1 aggregated to 1m..1d)

Run:
    pip install -r requirements.txt
    python mt5_bridge.py            # reads config.json next to this file
"""

import json
import os
import sys
import time
import threading
import datetime as dt

import requests

try:
    import MT5Manager  # pip install MT5Manager  (Windows, Python 3.7-3.12)
except Exception as e:  # pragma: no cover
    print("ERROR: the MT5Manager package is required: pip install MT5Manager")
    print(repr(e))
    sys.exit(1)


# ── timeframe seconds (must match B-Trader) ─────────────────────────────────
TF_SECONDS = {"1m": 60, "5m": 300, "15m": 900, "30m": 1800, "1h": 3600, "4h": 14400, "1d": 86400}


def log(level, msg):
    line = f"{dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M:%S} [{level}] {msg}"
    try:
        print(line, flush=True)
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "utf-8"
        print(line.encode(enc, errors="replace").decode(enc, errors="replace"), flush=True)


def load_config(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        cfg = json.load(f)
    for key in ("Mt5Server", "Mt5Login", "Mt5Password", "FeedUrl", "FeedToken"):
        if not cfg.get(key) and cfg.get(key) != 0:
            raise SystemExit(f"config: missing {key}")
    return cfg


class BTraderClient:
    def __init__(self, base_url, token, tick_timeout=8, candle_timeout=15):
        base = base_url.rstrip("/")
        self.ingest = base + "/ingest"
        self.candles = base + "/ingest/candles"
        # Separate sessions: tick worker + candle seed/refresh run concurrently.
        # requests.Session is not thread-safe — sharing one pool caused hung
        # connections and read-timeouts under 458-symbol + history load.
        headers = {"X-Feed-Token": token, "Content-Type": "application/json"}
        self._tick_s = requests.Session()
        self._tick_s.headers.update(headers)
        self._candle_s = requests.Session()
        self._candle_s.headers.update(headers)
        self.tick_timeout = max(3, float(tick_timeout))
        self.candle_timeout = max(5, float(candle_timeout))
        self.ticks_sent = 0
        self.candles_sent = 0
        self.failures = 0
        self._tick_lock = threading.Lock()
        self._tick_pending = None  # latest batch waiting to ship (coalesced)
        self._tick_worker = threading.Thread(target=self._tick_sender_loop, daemon=True)
        self._tick_worker.start()
        self._stats_worker = threading.Thread(target=self._stats_loop, daemon=True)
        self._stats_worker.start()

    def send_ticks(self, batch):
        """Queue ticks without blocking the poll loop (timeouts must not stall prices)."""
        if not batch:
            return
        with self._tick_lock:
            # Keep only the newest snapshot per symbol if a prior post is still in flight.
            if self._tick_pending is None:
                self._tick_pending = list(batch)
            else:
                by_sym = {t["symbol"]: t for t in self._tick_pending}
                for t in batch:
                    by_sym[t["symbol"]] = t
                self._tick_pending = list(by_sym.values())

    def send_candles(self, symbol, tf, bars):
        self._post(self._candle_s, self.candles, {"symbol": symbol, "tf": tf, "bars": bars}, tick=False)

    def _tick_sender_loop(self):
        while True:
            with self._tick_lock:
                batch = self._tick_pending
                self._tick_pending = None
            if not batch:
                time.sleep(0.01)
                continue
            # Chunk so a 400+ symbol dump never times out the ingest handler.
            chunk_size = 80
            for i in range(0, len(batch), chunk_size):
                t0 = time.perf_counter()
                self._post(self._tick_s, self.ingest, {"ticks": batch[i : i + chunk_size]}, tick=True)
                ms = (time.perf_counter() - t0) * 1000.0
                # Sample slow posts so we can prove p99 stays under the 8s timeout.
                if ms >= 500:
                    log("WARN", f"tick post slow: {ms:.0f}ms chunk={min(chunk_size, len(batch) - i)}")
                elif self.ticks_sent and self.ticks_sent % 200 == 0:
                    log("INFO", f"tick post ok: {ms:.0f}ms (sample)")

    def _stats_loop(self):
        while True:
            time.sleep(30)
            log(
                "INFO",
                f"feed stats: ticks_ok={self.ticks_sent} candles_ok={self.candles_sent} fails={self.failures}",
            )

    def _post(self, session, url, body, tick):
        try:
            r = session.post(
                url,
                data=json.dumps(body),
                timeout=self.tick_timeout if tick else self.candle_timeout,
            )
            if r.status_code == 200:
                if tick:
                    self.ticks_sent += 1
                else:
                    self.candles_sent += 1
            else:
                self.failures += 1
                log("WARN", f"ingest {r.status_code}: {r.text[:200]}")
        except Exception as e:
            self.failures += 1
            log("WARN", f"ingest post failed: {e}")


def aggregate(m1_bars, tf_seconds, broker_offset_sec=0):
    """Build one higher-TF series from Manager ChartRequest M1 bars.

    MT5 Manager ChartRequest is M1-only; Terminal M5/M15/… are derived from the
    same M1 history. Intraday TFs (≤1h) use UTC epoch floors (identical to MT5
    for whole-hour broker offsets). H4/D1 shift by broker_offset_sec so the
    session day/H4 grid matches the LP server clock.
    """
    if tf_seconds <= 60:
        return m1_bars
    off = int(broker_offset_sec or 0)
    # H4/D1: align to broker midnight / broker H4 grid; else plain UTC floor.
    use_broker = tf_seconds >= 14400 and off != 0
    out = []
    cur = None
    for (t, o, h, l, c, v) in m1_bars:  # ascending by time
        if use_broker:
            bucket = ((int(t) + off) // tf_seconds) * tf_seconds - off
        else:
            bucket = (int(t) // tf_seconds) * tf_seconds
        if cur is None or cur[0] != bucket:
            if cur is not None:
                out.append(tuple(cur))
            cur = [bucket, o, h, l, c, v]
        else:
            if h > cur[2]:
                cur[2] = h
            if l < cur[3]:
                cur[3] = l
            cur[4] = c
            cur[5] += v
    if cur is not None:
        out.append(tuple(cur))
    return out


def broker_utc_offset_sec(src):
    """Best-effort LP server UTC offset (seconds). 0 if unknown."""
    try:
        # TimeServer often tracks wall UTC; compare to local unix.
        ts = src.m.TimeServer()
        if isinstance(ts, (list, tuple)):
            ts = ts[0]
        ts = int(ts)
        if ts > 10_000_000_000:
            ts //= 1000
        # Prefer MTConTime time zone if present.
        try:
            conf = src.m.TimeGet()
            for attr in ("TimeZone", "timezone", "Timezone", "Bias", "bias"):
                if hasattr(conf, attr):
                    v = getattr(conf, attr)
                    if callable(v):
                        v = v()
                    # Bias minutes west of UTC (Windows-style) or hours.
                    v = int(v)
                    if abs(v) <= 14:  # hours
                        return v * 3600
                    if abs(v) <= 14 * 60:  # minutes
                        return -v * 60  # Windows bias: west positive
            # Some builds expose TimeZone as seconds.
            for attr in ("TimeZone",):
                if hasattr(conf, attr):
                    v = int(getattr(conf, attr))
                    if abs(v) >= 1800:
                        return v
        except Exception:
            pass
        # Fallback: round (TimeServer - wall) to nearest hour in [-12h,+14h].
        delta = ts - int(time.time())
        hours = int(round(delta / 3600.0))
        if -12 <= hours <= 14 and hours != 0:
            return hours * 3600
    except Exception as e:
        log("WARN", f"broker offset detect failed: {e}")
    return 0


# ============================================================================
#  MT5 MANAGER API wrapper — the only place that touches the MT5Manager package.
#  Method names follow the official package; if your build differs, run
#  `python -c "import MT5Manager; help(MT5Manager.ManagerAPI)"` and adjust here.
# ============================================================================
class Mt5Source:
    def __init__(self, cfg):
        self.cfg = cfg
        self.m = MT5Manager.ManagerAPI()

    def connect(self):
        pump = MT5Manager.ManagerAPI.EnPumpModes.PUMP_MODE_FULL
        ok = self.m.Connect(self.cfg["Mt5Server"], int(self.cfg["Mt5Login"]),
                            self.cfg["Mt5Password"], pump, 120000)
        if not ok:
            raise RuntimeError(f"Connect failed: {MT5Manager.LastError()}")
        log("INFO", "Manager API connected")

    def list_symbols(self):
        # Explicit list wins if provided.
        if self.cfg.get("Symbols"):
            return [s.strip() for s in self.cfg["Symbols"].split(",") if s.strip()]
        # Otherwise enumerate ALL symbols on the server. Different MT5Manager
        # builds expose this differently, so try the known methods in order.
        names = []

        # 1) SymbolGetArray() -> list of MTConSymbol (or names)
        try:
            arr = self.m.SymbolGetArray()
            if arr:
                for s in arr:
                    n = self._sym_name(s)
                    if n:
                        names.append(n)
        except Exception as e:
            log("WARN", f"SymbolGetArray unavailable ({e}); trying SymbolTotal/Next")

        # 2) Fallback: SymbolTotal() + SymbolNext(i)
        if not names:
            try:
                total = int(self.m.SymbolTotal())
                for i in range(total):
                    n = self._sym_name(self.m.SymbolNext(i))
                    if n:
                        names.append(n)
            except Exception as e:
                raise RuntimeError(f"symbol enumeration failed: {e}")

        # de-dupe, keep order
        seen = set()
        out = []
        for n in names:
            if n not in seen:
                seen.add(n)
                out.append(n)
        return out

    @staticmethod
    def _sym_name(s):
        """Extract a symbol name from a string or MTConSymbol-like object."""
        if s is None:
            return None
        if isinstance(s, str):
            return s
        fn = getattr(s, "Symbol", None)
        if callable(fn):
            try:
                return fn()
            except Exception:
                pass
        v = getattr(s, "symbol", None)
        if isinstance(v, str):
            return v
        if isinstance(fn, str):
            return fn
        return None

    def subscribe_symbols(self, symbols):
        """Select/subscribe symbols so TickLast returns data for all of them.
        Different builds expose this as SymbolSubscribe and/or TickSubscribe —
        try both, ignore what isn't there."""
        ok = 0
        for s in symbols:
            done = False
            for meth in ('SymbolSubscribe', 'TickSubscribe', 'SelectedAdd'):
                fn = getattr(self.m, meth, None)
                if callable(fn):
                    try:
                        fn(s)
                        done = True
                    except Exception:
                        pass
            if done:
                ok += 1
        return ok

    def last_tick(self, symbol):
        """Return (bid, ask, ts_ms) or None."""
        t = self.m.TickLast(symbol)
        if not t:
            return None
        tick = t[0] if isinstance(t, (list, tuple)) else t
        bid = float(getattr(tick, "bid", 0) or 0)
        ask = float(getattr(tick, "ask", 0) or 0)
        if bid <= 0 or ask <= 0:
            return None
        # Wall-clock ms: MT5 clock skew makes market-data fresh() drop ticks.
        ms = int(time.time() * 1000)
        return (bid, ask, ms)

    def m1_bars(self, symbol, from_unix, to_unix):
        """Return list of (t,o,h,l,c,v) M1 bars (epoch seconds)."""
        bars = self.m.ChartRequest(symbol, int(from_unix), int(to_unix))
        if not bars:
            return []
        out = []
        for b in bars:
            t = int(getattr(b, "datetime", 0) or 0)
            o = float(getattr(b, "open", 0) or 0)
            h = float(getattr(b, "high", 0) or 0)
            l = float(getattr(b, "low", 0) or 0)
            c = float(getattr(b, "close", 0) or 0)
            v = float(getattr(b, "tick_volume", 0) or 0)
            if t > 0:
                out.append((t, o, h, l, c, v))
        out.sort(key=lambda x: x[0])
        return out

    # ── symbol objects + groups (for reconcile) ────────────────────────────
    def symbol_objects(self):
        """Return raw MTConSymbol objects (preferred) so we can read full specs."""
        try:
            arr = self.m.SymbolGetArray()
            if arr:
                return list(arr)
        except Exception as e:
            log("WARN", f"SymbolGetArray unavailable for specs ({e})")
        return []

    def list_groups(self):
        """Return MT5 client group names (e.g. 'real\\Standard')."""
        names = []
        try:
            arr = self.m.GroupGetArray()
            if arr:
                for g in arr:
                    n = self._group_name(g)
                    if n:
                        names.append(n)
        except Exception as e:
            log("WARN", f"GroupGetArray unavailable ({e}); trying GroupTotal/Next")
        if not names:
            try:
                total = int(self.m.GroupTotal())
                for i in range(total):
                    n = self._group_name(self.m.GroupNext(i))
                    if n:
                        names.append(n)
            except Exception as e:
                log("WARN", f"group enumeration failed: {e}")
        seen, out = set(), []
        for n in names:
            if n not in seen:
                seen.add(n)
                out.append(n)
        return out

    @staticmethod
    def _group_name(g):
        if g is None:
            return None
        if isinstance(g, str):
            return g
        fn = getattr(g, "Group", None)
        if callable(fn):
            try:
                return fn()
            except Exception:
                pass
        if isinstance(fn, str):
            return fn
        v = getattr(g, "group", None)
        return v if isinstance(v, str) else None

    # ── A-book cover execution via the dealer gateway ──────────────────────
    # NOTE: DealerSend requires a *dealer gateway* entitlement on your MT5
    # license. Method names vary by MT5Manager build; this probes the common
    # ones and raises if none exist (so the engine leaves the cover PENDING
    # rather than falsely marking it filled). Validate against your build with:
    #   python -c "import MT5Manager; help(MT5Manager.ManagerAPI)"
    def dealer_send(self, symbol, side, volume_lots, cover_login, vol_divisor):
        """Place a market cover on MT5. Return (fill_price, ticket) or raise."""
        send = getattr(self.m, "DealerSend", None)
        if not callable(send):
            raise RuntimeError("DealerSend not available (dealer gateway required)")
        req = MT5Manager.MTRequest()
        req.Login = int(cover_login)
        req.Symbol = symbol
        req.Action = MT5Manager.MTRequest.EnTradeActions.TA_DEALER_POS_EXECUTE
        req.Type = (
            MT5Manager.MTOrder.EnOrderType.OP_BUY
            if side == "BUY"
            else MT5Manager.MTOrder.EnOrderType.OP_SELL
        )
        req.Volume = int(round(float(volume_lots) * float(vol_divisor)))
        confirm = send(req)
        if not confirm:
            raise RuntimeError(f"DealerSend returned no confirm: {MT5Manager.LastError()}")
        c = confirm[0] if isinstance(confirm, (list, tuple)) else confirm
        price = float(getattr(c, "Price", 0) or 0)
        ticket = str(getattr(c, "Order", "") or getattr(c, "Deal", "") or "")
        if price <= 0:
            raise RuntimeError("DealerSend gave no fill price")
        return (price, ticket)

    def dealer_close(self, symbol, ticket, vol_divisor, volume_lots=None):
        """Close an MT5 cover position by ticket. When volume_lots is given and is
        less than the position size, MT5 performs a PARTIAL close of that many
        lots (used for proportional partial-A-book closes); otherwise the whole
        position is closed. Return close price or raise."""
        close = getattr(self.m, "DealerSend", None)
        if not callable(close):
            raise RuntimeError("DealerSend not available (dealer gateway required)")
        req = MT5Manager.MTRequest()
        req.Symbol = symbol
        req.Action = MT5Manager.MTRequest.EnTradeActions.TA_DEALER_POS_EXECUTE
        req.Position = int(ticket) if str(ticket).isdigit() else 0
        # Partial close: set the lot volume to close (MT5 closes min(volume, position)).
        if volume_lots is not None and float(volume_lots) > 0:
            req.Volume = int(round(float(volume_lots) * float(vol_divisor)))
        confirm = close(req)
        if not confirm:
            raise RuntimeError(f"close returned no confirm: {MT5Manager.LastError()}")
        c = confirm[0] if isinstance(confirm, (list, tuple)) else confirm
        price = float(getattr(c, "Price", 0) or 0)
        if price <= 0:
            raise RuntimeError("close gave no fill price")
        return price

    def disconnect(self):
        try:
            self.m.Disconnect()
        except Exception:
            pass


def clean_symbol(sym, suffix):
    s = sym.upper()
    if suffix and s.endswith(suffix.upper()):
        s = s[: -len(suffix)]
    return s


def feed_canon(sym, suffix):
    """App/storage symbol: strip configured suffix, then broker variant after first dot.

    XAUUSD / XAUUSD.s / XAUUSD.m.ME8.1 → XAUUSD so ChartRequest+TickLast share one key.
    """
    cleaned = clean_symbol(sym, suffix)
    return cleaned.split(".", 1)[0]


def _parse_chart_source_map(cfg, suffix):
    """Optional canonical→MT5 instrument map, e.g. 'XAUUSD=XAUUSD.s,EURUSD=EURUSD'."""
    out = {}
    raw = str(cfg.get("ChartSourceMap") or "").strip()
    if not raw:
        return out
    for part in raw.split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        left, right = part.split("=", 1)
        canon = feed_canon(left.strip(), suffix)
        mt5 = right.strip()
        if canon and mt5:
            out[canon] = mt5
    return out


def _pick_mt5_instrument(canon, candidates, source_map):
    """Pick one MT5 name for ChartRequest+TickLast for a canonical app symbol."""
    if not candidates:
        return None
    prefer = source_map.get(canon)
    if prefer:
        prefer_u = prefer.upper()
        for c in candidates:
            if c.upper() == prefer_u:
                return c
        # Allow suffix-stripped match on the mapped value.
        for c in candidates:
            if c.upper().startswith(prefer_u + ".") or prefer_u.startswith(c.upper() + "."):
                return c
    # Prefer exact canonical name, then shorter / fewer dots (stable, not .m/.s scramble).
    exact = [c for c in candidates if c.upper() == canon]
    if exact:
        return exact[0]
    return sorted(candidates, key=lambda s: (s.upper().count("."), len(s), s.upper()))[0]


def resolve_feed_symbols(cfg, symbols, suffix):
    """One MT5 instrument per canonical symbol for BOTH ticks and ChartRequest.

    Prevents TickLast from XAUUSD.s mixing with ChartRequest from bare XAUUSD
    while the app charts canonical XAUUSD.
    Returns (mt5_names_for_poll, canon_by_mt5).
    """
    source_map = _parse_chart_source_map(cfg, suffix)
    by_canon = {}
    for sym in symbols:
        canon = feed_canon(sym, suffix)
        by_canon.setdefault(canon, []).append(sym)
    mt5_names = []
    canon_by_mt5 = {}
    for canon in sorted(by_canon.keys()):
        chosen = _pick_mt5_instrument(canon, by_canon[canon], source_map)
        if not chosen:
            continue
        mt5_names.append(chosen)
        canon_by_mt5[chosen] = canon
    return mt5_names, canon_by_mt5


# ============================================================================
#  B-Trader management client (/bridge/* endpoints) — symbol/group reconcile and
#  A-book cover relay. Auth: X-Bridge-Token + X-BT-Tenant (separate from the
#  price-feed token). See apps/gateway-api BridgeController/BridgeGuard.
# ============================================================================
def _mgmt_ready(cfg):
    ok = bool(cfg.get("BridgeApiUrl") and cfg.get("BridgeToken") and cfg.get("BtTenantId"))
    if not ok:
        log("WARN", "reconcile/hedge needs BridgeApiUrl + BridgeToken + BtTenantId in config — skipping")
    return ok


class BridgeMgmtClient:
    def __init__(self, cfg):
        self.base = cfg["BridgeApiUrl"].rstrip("/")
        self.s = requests.Session()
        self.s.headers.update({
            "X-Bridge-Token": cfg["BridgeToken"],
            "X-BT-Tenant": str(cfg["BtTenantId"]),
            "Content-Type": "application/json",
        })

    def post(self, path, body):
        r = self.s.post(self.base + path, data=json.dumps(body), timeout=30)
        r.raise_for_status()
        return r.json() if r.content else {}

    def get(self, path):
        r = self.s.get(self.base + path, timeout=30)
        r.raise_for_status()
        return r.json() if r.content else {}


def _symbol_payload(s, suffix, vol_divisor):
    """Build a /bridge/symbols/reconcile entry from an MTConSymbol object.
    Reuses the classifier from sync_symbols.py so buckets match the importer."""
    import sync_symbols as ss
    name = ss.strip_suffix(ss.sym_name(s), suffix).upper()
    if not name:
        return None
    path = str(ss.attr(s, "Path", "path", default="") or "")
    base, quote = ss.base_quote(s, name)
    cls = ss.classify(name, path, base, quote)
    digits = int(ss.attr(s, "Digits", "digits", default=5) or 5)
    contract = ss.attr(s, "ContractSize", "contractSize", default=None)
    return {
        "symbol": name,
        "class": cls,
        "groupName": ss.CLASS_TO_GROUP[cls],
        "description": str(ss.attr(s, "Description", "description", default=name) or name)[:120],
        "baseCurrency": base or name[:3],
        "quoteCurrency": quote or "USD",
        "digits": digits,
        "pipSize": ss.pip_size(digits),
        "contractSize": float(contract) if contract else None,
        "minLot": ss.lot(ss.attr(s, "VolumeMin", "volumeMin", default=None), vol_divisor),
        "maxLot": ss.lot(ss.attr(s, "VolumeMax", "volumeMax", default=None), vol_divisor),
        "lotStep": ss.lot(ss.attr(s, "VolumeStep", "volumeStep", default=None), vol_divisor),
        "marginCurrency": str(ss.attr(s, "CurrencyMargin", "currencyMargin", default=quote or "USD") or "USD").upper(),
    }


def _do_reconcile(src, mgmt, cfg, suffix, vol_divisor, enabled_classes):
    objs = src.symbol_objects()
    payloads = [p for p in (_symbol_payload(o, suffix, vol_divisor) for o in objs) if p]
    if payloads:
        r = mgmt.post("/bridge/symbols/reconcile",
                      {"symbols": payloads, "enabledClasses": enabled_classes})
        log("INFO", f"symbols reconcile: {r}")
    # Manager trading groups (real\\Standard, etc.) — off by default; feed-only
    # setups should not pollute B-Trader with MT5 manager group trees.
    if cfg.get("GroupsReconcileEnabled", False):
        groups = src.list_groups()
        if groups:
            r = mgmt.post("/bridge/groups/reconcile", {"groups": groups})
            log("INFO", f"groups reconcile: created={r.get('created')}")
    else:
        log("INFO", "groups reconcile skipped (GroupsReconcileEnabled=false)")


def reconcile_loop(src, cfg, suffix, stop):
    """Push MT5 symbol specs + group names to B-Trader.

    Runs on a timer (ReconcileSec) AND on demand: it wakes every ~10s to poll
    /bridge/sync-requested so the admin's "Sync from MT5 now" button takes effect
    almost immediately instead of waiting for the full interval.
    """
    mgmt = BridgeMgmtClient(cfg)
    vol_divisor = float(cfg.get("Mt5VolumeDivisor", 10000))
    enabled_classes = [c.strip().upper() for c in str(cfg.get("EnableClasses", "")).split(",") if c.strip()]
    interval = max(30, int(cfg.get("ReconcileSec", 300)))
    poll = min(10, interval)
    last_run = 0.0
    last_req = None
    while not stop.is_set():
        now = time.time()
        trigger = now - last_run >= interval
        if not trigger:
            try:
                req = mgmt.get("/bridge/sync-requested").get("requestedAt")
                if req and req != last_req:
                    trigger = True
                    log("INFO", "reconcile: admin sync-now requested")
                last_req = req if req is not None else last_req
            except Exception:
                pass
        if trigger:
            try:
                _do_reconcile(src, mgmt, cfg, suffix, vol_divisor, enabled_classes)
                # remember the request we just satisfied so we don't re-run it
                try:
                    last_req = mgmt.get("/bridge/sync-requested").get("requestedAt")
                except Exception:
                    pass
            except Exception as e:
                log("WARN", f"reconcile: {e}")
            last_run = time.time()
        stop.wait(poll)


def hedge_loop(src, cfg, suffix, stop):
    """Poll pending A-book covers, execute on MT5, report fills/closes back."""
    mgmt = BridgeMgmtClient(cfg)
    vol_divisor = float(cfg.get("Mt5VolumeDivisor", 10000))
    cover_login = cfg.get("Mt5CoverLogin")
    every = max(1, int(cfg.get("HedgePollSec", 2)))
    # Phase 3 multi-venue: when this bridge represents a specific LP, scope the
    # pending poll to that provider's covers so several MT5 bridges don't fight
    # over the same hedges. Empty = legacy single-bridge (unscoped) covers.
    provider_code = str(cfg.get("LpProviderCode", "") or "").strip()
    pending_path = "/bridge/hedges/pending" + (f"?provider={provider_code}" if provider_code else "")
    if provider_code:
        log("INFO", f"hedge worker scoped to LP provider '{provider_code}'")
    if not cover_login:
        log("WARN", "HedgeEnabled but Mt5CoverLogin not set — hedge worker idle")
        return
    while not stop.is_set():
        try:
            pend = mgmt.get(pending_path)
            for h in pend.get("opens", []):
                mt5_sym = h["symbolName"] + (suffix or "")  # re-add broker suffix
                try:
                    price, ticket = src.dealer_send(mt5_sym, h["side"], h["volume"], cover_login, vol_divisor)
                    mgmt.post(f"/bridge/hedges/{h['id']}/fill", {"fillPrice": price, "externalRef": ticket})
                    log("INFO", f"cover FILLED {mt5_sym} {h['side']} {h['volume']} @ {price} #{ticket}")
                except Exception as ex:
                    mgmt.post(f"/bridge/hedges/{h['id']}/reject", {"reason": str(ex)[:200]})
                    log("WARN", f"cover REJECT {mt5_sym}: {ex}")
            for h in pend.get("closes", []):
                mt5_sym = h["symbolName"] + (suffix or "")
                try:
                    # Pass the hedge volume so partial-A-book closes close only that
                    # many lots of the cover ticket (full close when it equals the size).
                    price = src.dealer_close(mt5_sym, h.get("externalRef"), vol_divisor, h.get("volume"))
                    mgmt.post(f"/bridge/hedges/{h['id']}/closed", {"closePrice": price})
                    log("INFO", f"cover CLOSED {mt5_sym} {h.get('volume')} @ {price}")
                except Exception as ex:
                    log("WARN", f"cover close failed {mt5_sym}: {ex}")
        except Exception as e:
            log("WARN", f"hedge poll: {e}")
        stop.wait(every)


def run(cfg):
    client = BTraderClient(
        cfg["FeedUrl"],
        cfg["FeedToken"],
        tick_timeout=cfg.get("TickHttpTimeoutSec", 8),
        candle_timeout=cfg.get("CandleHttpTimeoutSec", 15),
    )
    suffix = cfg.get("SymbolSuffixStrip", "")
    stop = threading.Event()

    while not stop.is_set():
        src = Mt5Source(cfg)
        session_stop = threading.Event()  # stops this session's candle thread on reconnect
        try:
            log("INFO", f"connecting to {cfg['Mt5Server']} as manager {cfg['Mt5Login']}...")
            src.connect()
            symbols = src.list_symbols()
            feed_syms, canon_by_mt5 = resolve_feed_symbols(cfg, symbols, suffix)
            # Subscribe everything for Manager health; poll only resolved feed set.
            subbed = src.subscribe_symbols(symbols)
            mapped = ",".join(f"{canon_by_mt5[s]}<={s}" for s in feed_syms[:12])
            log(
                "INFO",
                f"streaming {len(symbols)} listed, feed={len(feed_syms)} "
                f"subscribed={subbed} map_sample={mapped}",
            )

            # Seed / refresh candles on a background thread so tick streaming is
            # never blocked by history load (anti-arbitrage prices stay live).
            if cfg.get("PushCandles", True):
                def _candle_boot():
                    # Let tick POSTs warm the path before heavy history flood.
                    delay = max(0, int(cfg.get("CandleSeedDelaySec", 15)))
                    if delay and session_stop.wait(delay):
                        return
                    try:
                        seed_candles(src, client, cfg, feed_syms, suffix, canon_by_mt5)
                        log("INFO", "candle history seeded")
                    except Exception as e:
                        log("WARN", f"candle seed failed: {e}")
                    if not session_stop.is_set():
                        candle_refresh_loop(
                            src, client, cfg, feed_syms, suffix, session_stop, canon_by_mt5
                        )

                threading.Thread(target=_candle_boot, daemon=True).start()

            # Symbol/group auto-sync into B-Trader (separate management token).
            if cfg.get("ReconcileEnabled") and _mgmt_ready(cfg):
                threading.Thread(target=reconcile_loop,
                                 args=(src, cfg, suffix, session_stop), daemon=True).start()
                log("INFO", "symbol/group reconcile worker started")

            # A-book cover execution: poll pending MT5 hedges + execute on MT5.
            if cfg.get("HedgeEnabled") and _mgmt_ready(cfg):
                threading.Thread(target=hedge_loop,
                                 args=(src, cfg, suffix, session_stop), daemon=True).start()
                log("INFO", "A-book hedge worker started")

            # Tick poll/flush loop (blocks until error).
            tick_loop(src, client, cfg, feed_syms, suffix, stop, canon_by_mt5)
        except KeyboardInterrupt:
            stop.set()
        except Exception as e:
            log("ERR ", f"session error: {e}")
        finally:
            session_stop.set()
            src.disconnect()
        if not stop.is_set():
            log("WARN", "reconnecting in 5s...")
            time.sleep(5)

    log("INFO", f"stopped. ticks={client.ticks_sent} candles={client.candles_sent} fails={client.failures}")


def tick_loop(src, client, cfg, symbols, suffix, stop, canon_by_mt5=None):
    flush_ms = max(50, int(cfg.get("TickFlushMs", 200)))
    # Self-healing: editing a symbol (e.g. spread) in the MT5 Manager resets the
    # server-side tick pump. Re-subscribe periodically, and if no ticks arrive
    # for a while, reconnect (which re-lists + re-subscribes everything).
    resub_sec = max(10, int(cfg.get("ResubscribeSec", 30)))
    stale_sec = max(8, int(cfg.get("StaleReconnectSec", 20)))
    last_data = time.time()
    last_resub = time.time()
    canon_by_mt5 = canon_by_mt5 or {}
    while not stop.is_set():
        now = time.time()
        if now - last_resub >= resub_sec:
            try:
                src.subscribe_symbols(symbols)
            except Exception:
                pass
            last_resub = now
        batch = []
        for sym in symbols:
            try:
                t = src.last_tick(sym)
            except Exception as e:
                raise RuntimeError(f"tick read failed ({sym}): {e}")
            if t:
                bid, ask, ms = t
                out_sym = canon_by_mt5.get(sym) or feed_canon(sym, suffix)
                batch.append({"symbol": out_sym, "bid": bid, "ask": ask, "ts": ms})
        if batch:
            client.send_ticks(batch)
            last_data = now
        elif now - last_data >= stale_sec:
            raise RuntimeError(f"no ticks for {stale_sec}s — reconnecting")
        time.sleep(flush_ms / 1000.0)


def _candle_tfs(cfg):
    return [
        tf.strip()
        for tf in cfg.get("Timeframes", "1m,5m,15m,30m,1h,4h,1d").split(",")
        if tf.strip() in TF_SECONDS
    ]


def _seed_symbol_set(cfg, symbols, suffix, canon_by_mt5=None):
    """Allow-list deep seed symbols. `symbols` should already be resolved feed names."""
    raw = str(cfg.get("CandleSeedSymbols") or "").strip()
    if not raw:
        return list(symbols)
    want = {feed_canon(s.strip(), suffix) for s in raw.split(",") if s.strip()}
    canon_by_mt5 = canon_by_mt5 or {}
    out = []
    for sym in symbols:
        canon = canon_by_mt5.get(sym) or feed_canon(sym, suffix)
        if canon in want:
            out.append(sym)
    return out or list(symbols)


def seed_candles(src, client, cfg, symbols, suffix, canon_by_mt5=None):
    """Push deep MT5 history so every TF has hundreds–1500+ bars for analysis."""
    want_bars = max(100, int(cfg.get("HistoryBars", 1500)))
    max_days = max(7, int(cfg.get("HistoryMaxDays", 90)))
    chunk_days = max(1, int(cfg.get("HistoryChunkDays", 7)))
    tfs = _candle_tfs(cfg)
    if not tfs:
        return
    # Span must cover the deepest TF × want_bars, capped by HistoryMaxDays.
    need_sec = max(TF_SECONDS[tf] * want_bars for tf in tfs)
    need_sec = min(need_sec, max_days * 86400)
    now = int(time.time())
    frm = now - need_sec
    seed_syms = _seed_symbol_set(cfg, symbols, suffix, canon_by_mt5)
    log("INFO", f"seeding candles: {len(seed_syms)} symbol(s), {need_sec // 86400}d M1 -> up to {want_bars} bars/TF")
    push_window(
        src, client, cfg, seed_syms, suffix, frm, now,
        want_bars=want_bars, chunk_sec=chunk_days * 86400,
        canon_by_mt5=canon_by_mt5,
    )


def candle_refresh_loop(src, client, cfg, symbols, suffix, stop, canon_by_mt5=None):
    # ≥6h so H1/M30 buckets near the window edge are rebuilt from full M1,
    # not a partial slice that shrinks wicks (seen as M30/H1 OHLC drift).
    window = max(6 * 60 * 60, int(cfg.get("CandleRefreshWindowSec", 6 * 60 * 60)))
    every = max(10, int(cfg.get("CandleRefreshSec", 30)))
    seed_syms = _seed_symbol_set(cfg, symbols, suffix, canon_by_mt5)
    while not stop.is_set():
        time.sleep(every)
        now = int(time.time())
        try:
            push_window(
                src, client, cfg, seed_syms, suffix, now - window, now,
                want_bars=800, canon_by_mt5=canon_by_mt5,
            )
        except Exception as e:
            log("WARN", f"candle refresh: {e}")


def _m1_bars_chunked(src, symbol, frm, to, chunk_sec):
    """Pull M1 in chunks so long HistoryMaxDays windows don't stall Manager API."""
    if to <= frm:
        return []
    if chunk_sec <= 0 or (to - frm) <= chunk_sec:
        return src.m1_bars(symbol, frm, to)
    out = []
    cur = frm
    while cur < to:
        end = min(cur + chunk_sec, to)
        try:
            part = src.m1_bars(symbol, cur, end)
        except Exception as e:
            log("WARN", f"bars {symbol} chunk {cur}-{end}: {e}")
            part = []
        if part:
            out.extend(part)
        cur = end
    if not out:
        return []
    # Dedupe by open time (chunk edges can overlap depending on broker).
    by_t = {}
    for b in out:
        by_t[b[0]] = b
    return [by_t[t] for t in sorted(by_t)]


def push_window(src, client, cfg, symbols, suffix, frm, to, want_bars=1500, chunk_sec=0, canon_by_mt5=None):
    """Push per-TF OHLC built from Manager ChartRequest M1 for each symbol.

    Manager API has no native M5/H1 ChartRequest — each TF series is the MT5
    rollup of that symbol's M1 ChartRequest (same source Terminal uses).
    """
    tfs = _candle_tfs(cfg)
    # Pace candle POSTs so history seed/refresh cannot starve tick HTTP.
    pace_ms = max(0, int(cfg.get("CandlePostPaceMs", 40)))
    canon_by_mt5 = canon_by_mt5 or {}
    # Detect once per window (H4/D1 session grid).
    try:
        broker_off = int(cfg.get("BrokerUtcOffsetSec", broker_utc_offset_sec(src)) or 0)
    except Exception:
        broker_off = 0
    for sym in symbols:
        try:
            m1 = _m1_bars_chunked(src, sym, frm, to, chunk_sec)
        except Exception as e:
            log("WARN", f"bars {sym}: {e}")
            continue
        if not m1:
            continue
        out_sym = canon_by_mt5.get(sym) or feed_canon(sym, suffix)
        # Oldest M1 open in this pull — do not emit higher-TF bars that start
        # before we have M1 coverage (avoids truncated O/H/L overwrites).
        m1_start = int(m1[0][0]) if m1 else 0
        for tf in tfs:
            tf_sec = TF_SECONDS[tf]
            # Each TF is stored as its own series (not "M1 served as M5").
            rolled = aggregate(m1, tf_sec, broker_offset_sec=broker_off)
            if tf_sec > 60 and m1_start:
                # Drop the first higher-TF bucket if it begins before m1_start
                # (partial left edge). Keep forming tip at the right edge.
                rolled = [b for b in rolled if int(b[0]) >= m1_start]
            if want_bars and len(rolled) > want_bars:
                rolled = rolled[-want_bars:]
            bars = [{"t": b[0], "o": b[1], "h": b[2], "l": b[3], "c": b[4], "v": b[5]} for b in rolled]
            if bars:
                # Chunk POST body so huge seeds stay under ingest limits.
                step = 800
                for i in range(0, len(bars), step):
                    client.send_candles(out_sym, tf, bars[i : i + step])
                    if pace_ms:
                        time.sleep(pace_ms / 1000.0)


if __name__ == "__main__":
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
    run(load_config(cfg_path))
