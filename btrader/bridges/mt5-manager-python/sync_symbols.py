#!/usr/bin/env python3
"""
MT5 -> B-Trader symbol importer / sync.

Pulls EVERY symbol from your MT5 server (with full contract specs), classifies
each into a B-Trader InstrumentClass (FOREX / METALS / STOCKS / INDICES / CRYPTO
/ COMMODITIES / CUSTOM), makes sure a matching B-Trader *symbol group* exists,
then creates only the symbols that B-Trader doesn't have yet.

Why this exists
---------------
The tick bridge (mt5_bridge.py) streams prices for every symbol, but B-Trader
only distributes a tick if that symbol exists AND is enabled in its own DB. So
new MT5 pairs are silently dropped until they are created here.

Design goal: "take everything from MT5, give only what is required to clients."
So symbols are imported DISABLED by default. The broker admin then enables the
class(es) they want their clients to see (e.g. enable Forex + Crypto, leave
Stocks hidden) — either in the admin dashboard, with --enable-class on import,
or by re-running with --enable-class later.

Run (on the MT5 Windows VPS, same place as the bridge):
    pip install -r requirements.txt
    python sync_symbols.py --dry-run        # preview, writes nothing
    python sync_symbols.py                   # import missing symbols (disabled)
    python sync_symbols.py --enable-class FOREX,CRYPTO   # import + enable those

Config: reads config.json next to this file (same one the bridge uses) plus the
B-Trader API keys below. CLI flags override config.
"""

import argparse
import json
import os
import re
import sys
import datetime as dt

import requests

try:
    import MT5Manager  # pip install MT5Manager  (Windows, Python 3.7-3.12)
except Exception as e:  # pragma: no cover
    print("ERROR: the MT5Manager package is required: pip install MT5Manager")
    print(repr(e))
    sys.exit(1)


# ── B-Trader instrument classes (must match the Prisma InstrumentClass enum) ──
CLASSES = ("FOREX", "METALS", "STOCKS", "INDICES", "CRYPTO", "COMMODITIES", "CUSTOM")

# One symbol group per class by default. Rename here if you prefer different
# bucket names in the dashboard — the script creates whatever it finds missing.
CLASS_TO_GROUP = {
    "FOREX": "Forex",
    "METALS": "Metals",
    "STOCKS": "Stocks",
    "INDICES": "Indices",
    "CRYPTO": "Crypto",
    "COMMODITIES": "Commodities",
    "CUSTOM": "Other",
}

# Common ISO-4217 currency codes used to recognise a 6-char FX pair.
FX_CCY = {
    "AUD", "CAD", "CHF", "CNH", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF",
    "ILS", "JPY", "MXN", "NOK", "NZD", "PLN", "RUB", "SEK", "SGD", "THB", "TRY",
    "USD", "ZAR", "AED", "SAR",
}
METAL_BASES = {"XAU", "XAG", "XPT", "XPD"}
CRYPTO_TOKENS = {
    "BTC", "ETH", "XRP", "LTC", "BCH", "ADA", "DOT", "SOL", "DOGE", "BNB",
    "AVAX", "MATIC", "LINK", "TRX", "XLM", "ATOM", "ETC", "UNI", "SHIB", "USDT",
    "USDC",
}
# Index name fragments (broker naming varies a lot).
INDEX_TOKENS = {
    "US30", "US500", "USTEC", "NAS100", "NAS", "SPX", "SP500", "DJI", "DJ30",
    "GER30", "GER40", "DAX", "UK100", "FTSE", "JP225", "NIK", "NI225", "AUS200",
    "FRA40", "CAC", "EU50", "STOXX", "HK50", "HSI", "CHINA50", "VIX",
}
COMMODITY_TOKENS = {
    "WTI", "BRENT", "XBR", "XTI", "USOIL", "UKOIL", "OIL", "NGAS", "NATGAS",
    "GAS", "COCOA", "COFFEE", "SUGAR", "COTTON", "WHEAT", "CORN", "SOYBEAN",
    "COPPER", "XCU",
}

# Path keyword -> class (MT5 symbols carry a Path like "Forex\\Majors").
PATH_KEYWORDS = [
    ("metal", "METALS"), ("gold", "METALS"), ("silver", "METALS"),
    ("crypto", "CRYPTO"), ("coin", "CRYPTO"),
    ("indic", "INDICES"), ("index", "INDICES"), ("indices", "INDICES"), ("cash", "INDICES"),
    ("energ", "COMMODITIES"), ("commod", "COMMODITIES"), ("oil", "COMMODITIES"), ("agric", "COMMODITIES"),
    ("stock", "STOCKS"), ("share", "STOCKS"), ("equit", "STOCKS"),
    ("forex", "FOREX"), ("\\fx", "FOREX"), ("major", "FOREX"), ("minor", "FOREX"), ("exotic", "FOREX"),
]


def log(level, msg):
    print(f"{dt.datetime.now(dt.timezone.utc):%H:%M:%S} [{level}] {msg}", flush=True)


# ── tolerant attribute / value access (MTConSymbol fields vary by build) ──────
def attr(obj, *names, default=None):
    for n in names:
        v = getattr(obj, n, None)
        if v is None:
            continue
        if callable(v):
            try:
                v = v()
            except Exception:
                continue
        if v is not None:
            return v
    return default


def sym_name(s):
    if isinstance(s, str):
        return s.strip()
    return str(attr(s, "Symbol", "symbol", default="")).strip()


def strip_suffix(name, suffix):
    if suffix and name.upper().endswith(suffix.upper()):
        return name[: len(name) - len(suffix)]
    return name


# ── classification ────────────────────────────────────────────────────────────
def classify(name, path, base, quote):
    """Return a B-Trader InstrumentClass for an MT5 symbol.

    Priority: MT5 Path (most reliable, broker-curated) -> name/base/quote rules.
    """
    p = (path or "").lower()
    for kw, cls in PATH_KEYWORDS:
        if kw in p:
            return cls

    up = name.upper()
    b = (base or "").upper()
    q = (quote or "").upper()

    if b in METAL_BASES or up[:3] in METAL_BASES:
        return "METALS"
    if any(tok in up for tok in COMMODITY_TOKENS):
        return "COMMODITIES"
    if b in CRYPTO_TOKENS or q in CRYPTO_TOKENS or any(tok in up for tok in CRYPTO_TOKENS):
        return "CRYPTO"
    if up in INDEX_TOKENS or any(up.startswith(tok) or tok in up for tok in INDEX_TOKENS):
        return "INDICES"

    # Clean 6-letter FX pair with two known currency codes.
    alpha = re.sub(r"[^A-Z]", "", up)
    if len(alpha) == 6 and alpha[:3] in FX_CCY and alpha[3:] in FX_CCY:
        return "FOREX"
    if b in FX_CCY and q in FX_CCY and b and q:
        return "FOREX"

    # A bare ticker (AAPL, TSLA) is most likely a stock; otherwise custom.
    if re.fullmatch(r"[A-Z]{1,6}", up) and q in FX_CCY:
        return "STOCKS"
    return "CUSTOM"


def base_quote(s, name):
    base = str(attr(s, "CurrencyBase", "currencyBase", default="") or "").upper()
    quote = str(attr(s, "CurrencyProfit", "currencyProfit", "CurrencyQuote", default="") or "").upper()
    if not base or not quote:
        alpha = re.sub(r"[^A-Z]", "", name.upper())
        if len(alpha) == 6:
            base = base or alpha[:3]
            quote = quote or alpha[3:]
    return base, quote


def pip_size(digits):
    # Fractional-pip pricing (3 / 5 digits) -> pip is one order of magnitude up.
    if digits in (3, 5):
        return round(10 ** -(digits - 1), 10)
    return round(10 ** -digits, 10) if digits > 0 else 1.0


def lot(value, divisor):
    """MT5 stores volumes as integers (units). Convert to lots, guarding garbage."""
    try:
        v = float(value) / float(divisor)
    except Exception:
        return None
    if v <= 0 or v > 100000:
        return None
    return round(v, 4)


def build_payload(s, name, cls, group_id, enabled, vol_divisor):
    base, quote = base_quote(s, name)
    digits = int(attr(s, "Digits", "digits", default=5) or 5)
    contract = attr(s, "ContractSize", "contractSize", default=None)
    minl = lot(attr(s, "VolumeMin", "volumeMin", default=None), vol_divisor)
    maxl = lot(attr(s, "VolumeMax", "volumeMax", default=None), vol_divisor)
    stepl = lot(attr(s, "VolumeStep", "volumeStep", default=None), vol_divisor)
    margin_ccy = str(attr(s, "CurrencyMargin", "currencyMargin", default="") or quote or "USD").upper()
    desc = str(attr(s, "Description", "description", default="") or name)

    payload = {
        "symbol": name,
        "description": desc[:120],
        "class": cls,
        "baseCurrency": base or name[:3].upper(),
        "quoteCurrency": quote or "USD",
        "digits": digits,
        "pipSize": pip_size(digits),
        "contractSize": float(contract) if contract else (100000 if cls == "FOREX" else 1),
        "minLot": minl if minl is not None else 0.01,
        "maxLot": maxl if maxl is not None else 100,
        "lotStep": stepl if stepl is not None else 0.01,
        "marginCurrency": margin_ccy or "USD",
        "marginRate": 1,
        "slippagePoints": 0,   # default slippage = 0 per spec
        "spreadMarkup": 0,
        "enabled": enabled,
        "groupId": group_id,
    }
    return payload


# ── B-Trader API client ───────────────────────────────────────────────────────
class BTrader:
    def __init__(self, base, tenant_id):
        self.base = base.rstrip("/")
        self.tenant = tenant_id
        self.s = requests.Session()
        self.s.headers["X-BT-Tenant"] = tenant_id

    def login(self, email, password):
        r = self.s.post(f"{self.base}/auth/login", json={"email": email, "password": password}, timeout=30)
        r.raise_for_status()
        tok = r.json().get("accessToken")
        if not tok:
            raise RuntimeError("login returned no accessToken")
        self.s.headers["Authorization"] = f"Bearer {tok}"

    def use_token(self, token):
        self.s.headers["Authorization"] = f"Bearer {token}"

    def symbols(self):
        r = self.s.get(f"{self.base}/symbols", timeout=60)
        r.raise_for_status()
        return r.json()

    def groups(self):
        r = self.s.get(f"{self.base}/symbols/groups/all", timeout=30)
        r.raise_for_status()
        return r.json()

    def create_group(self, name):
        r = self.s.post(f"{self.base}/symbols/groups", json={"name": name, "markupBid": 0, "markupAsk": 0}, timeout=30)
        r.raise_for_status()
        return r.json()

    def create_symbol(self, payload):
        r = self.s.post(f"{self.base}/symbols", json=payload, timeout=30)
        r.raise_for_status()
        return r.json()


# ── MT5 connection (mirrors mt5_bridge.py) ────────────────────────────────────
def mt5_connect(cfg):
    mgr = MT5Manager.ManagerAPI()
    server = cfg["Mt5Server"]
    login = int(cfg["Mt5Login"])
    pwd = cfg["Mt5Password"]
    # ManagerAPI.Connect signature varies slightly by build; try the common ones.
    ok = False
    for args in ((server, login, pwd), (login, pwd, server)):
        try:
            ok = mgr.Connect(*args)
            if ok:
                break
        except Exception:
            continue
    if not ok:
        raise RuntimeError(f"MT5 connect failed for {login}@{server}")
    return mgr


def mt5_symbols(mgr):
    """Return a list of MTConSymbol objects (preferred) or names."""
    try:
        arr = mgr.SymbolGetArray()
        if arr:
            return list(arr)
    except Exception as e:
        log("WARN", f"SymbolGetArray unavailable ({e}); falling back to names")
    out = []
    try:
        total = int(mgr.SymbolTotal())
        for i in range(total):
            out.append(mgr.SymbolNext(i))
    except Exception as e:
        raise RuntimeError(f"symbol enumeration failed: {e}")
    return out


# ── main ──────────────────────────────────────────────────────────────────────
def load_cfg():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "config.json"), encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser(description="Sync MT5 symbols into B-Trader.")
    ap.add_argument("--dry-run", action="store_true", help="preview only, write nothing")
    ap.add_argument("--enable-class", default=None,
                    help="comma list of classes to ENABLE on import, e.g. FOREX,CRYPTO")
    ap.add_argument("--enable-all", action="store_true", help="enable every imported symbol")
    args = ap.parse_args()

    cfg = load_cfg()
    api_url = cfg.get("BtApiUrl") or os.environ.get("BT_API_URL")
    tenant_id = cfg.get("BtTenantId") or os.environ.get("BT_TENANT_ID")
    if not api_url or not tenant_id:
        log("ERROR", "set BtApiUrl and BtTenantId in config.json (B-Trader admin API + tenant id)")
        sys.exit(2)

    suffix = cfg.get("SymbolSuffixStrip", "")
    vol_divisor = float(cfg.get("Mt5VolumeDivisor", 10000))  # MT5 volume units per lot

    enable_classes = set()
    if args.enable_all:
        enable_classes = set(CLASSES)
    elif args.enable_class is not None:
        enable_classes = {c.strip().upper() for c in args.enable_class.split(",") if c.strip()}
    elif cfg.get("EnableClasses"):
        enable_classes = {c.strip().upper() for c in str(cfg["EnableClasses"]).split(",") if c.strip()}
    bad = enable_classes - set(CLASSES)
    if bad:
        log("ERROR", f"unknown class(es) in enable list: {', '.join(sorted(bad))}")
        sys.exit(2)

    # ── connect to B-Trader ──
    bt = BTrader(api_url, tenant_id)
    if cfg.get("BtAdminToken"):
        bt.use_token(cfg["BtAdminToken"])
    elif cfg.get("BtAdminEmail") and cfg.get("BtAdminPassword"):
        bt.login(cfg["BtAdminEmail"], cfg["BtAdminPassword"])
    else:
        log("ERROR", "provide BtAdminToken OR BtAdminEmail+BtAdminPassword in config.json")
        sys.exit(2)

    existing = {str(s.get("symbol", "")).upper() for s in bt.symbols()}
    group_id = {g["name"]: g["id"] for g in bt.groups()}
    log("INFO", f"B-Trader already has {len(existing)} symbol(s), {len(group_id)} group(s)")

    # ── pull MT5 symbols ──
    mgr = mt5_connect(cfg)
    try:
        raw = mt5_symbols(mgr)
    finally:
        try:
            mgr.Disconnect()
        except Exception:
            pass
    log("INFO", f"MT5 returned {len(raw)} symbol(s)")

    created, skipped, failed = 0, 0, 0
    by_class = {c: 0 for c in CLASSES}

    for s in raw:
        raw_name = sym_name(s)
        if not raw_name:
            continue
        name = strip_suffix(raw_name, suffix).upper()
        if name in existing:
            skipped += 1
            continue

        path = str(attr(s, "Path", "path", default="") or "")
        base, quote = base_quote(s, name)
        cls = classify(name, path, base, quote)
        by_class[cls] += 1
        group_name = CLASS_TO_GROUP[cls]

        # ensure the symbol group exists (cache ids; create on demand)
        gid = group_id.get(group_name)
        if gid is None:
            if args.dry_run:
                gid = f"<new:{group_name}>"
            else:
                gid = bt.create_group(group_name)["id"]
            group_id[group_name] = gid
            log("INFO", f"+ group '{group_name}'")

        enabled = cls in enable_classes
        payload = build_payload(s, name, cls, None if args.dry_run else gid, enabled, vol_divisor)

        if args.dry_run:
            flag = "ENABLED" if enabled else "hidden"
            log("DRY", f"{name:<14} {cls:<11} -> {group_name:<11} ({flag})")
            created += 1
            continue
        try:
            bt.create_symbol(payload)
            existing.add(name)
            created += 1
        except requests.HTTPError as e:
            failed += 1
            log("ERROR", f"create {name} failed: {e.response.status_code} {e.response.text[:200]}")

    # ── summary ──
    log("INFO", "── summary ──")
    for c in CLASSES:
        if by_class[c]:
            log("INFO", f"  {c:<12} {by_class[c]}")
    verb = "would create" if args.dry_run else "created"
    log("INFO", f"{verb}: {created}   skipped(existing): {skipped}   failed: {failed}")
    if enable_classes:
        log("INFO", f"enabled on import: {', '.join(sorted(enable_classes))}")
    else:
        log("INFO", "all imported DISABLED — enable classes in the dashboard or rerun with --enable-class")


if __name__ == "__main__":
    main()
