"""
Sync CrmGroupSymbol rows from connected trading platforms for each CRM group (accounts.MT5Group).

Best-effort REST discovery; broker APIs differ. Match-Trader uses integration hub key + MatchTraderSettings base URL.
"""

from __future__ import annotations

import json
import logging
import ssl
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin
from urllib.request import Request, urlopen

from django.db import transaction
from django.utils import timezone

logger = logging.getLogger(__name__)


def _norm_sym(s: str) -> str:
    return (s or "").strip().upper()[:64]


def _dedupe(symbols: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for x in symbols:
        n = _norm_sym(x)
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    return out


def _get_json_bearer(url: str, api_key: str, timeout: int) -> tuple[int | None, Any]:
    ctx = ssl.create_default_context()
    req = Request(
        url,
        method="GET",
        headers={
            "User-Agent": "ForexCRM-SymbolSync/1.0",
            "Authorization": f"Bearer {api_key.strip()}",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            code = int(getattr(resp, "status", None) or resp.getcode())
            raw = resp.read().decode("utf-8", errors="replace")
            if not raw.strip():
                return code, None
            try:
                return code, json.loads(raw)
            except json.JSONDecodeError:
                return code, None
    except HTTPError as e:
        try:
            body = e.read().decode("utf-8", errors="replace")
            return int(e.code), json.loads(body) if body.strip() else None
        except Exception:
            return int(e.code), None
    except (URLError, TimeoutError, OSError, ssl.SSLError):
        return None, None


def _codes_from_payload(data: Any, group_name: str | None) -> list[str]:
    """Extract likely instrument codes; optional filter when dicts expose a group field."""
    gn = (group_name or "").strip().lower()
    out: list[str] = []

    def take_obj(o: dict[str, Any]) -> None:
        if gn:
            for gk in ("group", "groupName", "accountGroup", "tradingGroup", "category"):
                gv = o.get(gk)
                if isinstance(gv, str) and gv.strip().lower() != gn:
                    return
        for k in ("symbol", "ticker", "name", "instrument", "code", "Symbol", "Instrument"):
            v = o.get(k)
            if isinstance(v, str) and v.strip():
                out.append(v.strip())
                return

    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                take_obj(item)
            elif isinstance(item, str) and item.strip():
                out.append(item.strip())
    elif isinstance(data, dict):
        for key in ("data", "items", "results", "symbols", "instruments", "rows"):
            if key in data:
                return _codes_from_payload(data[key], group_name)
        take_obj(data)
    return out


def fetch_symbols_match_trader(api_key: str, api_root: str, match_trader_group_name: str, timeout: int = 20) -> tuple[list[str], str | None]:
    if not api_key.strip() or not api_root.strip():
        return [], "Platform connection required"
    root = api_root.strip().rstrip("/")
    base = root if "/api" in root.lower() else root + "/api"
    gq = quote((match_trader_group_name or "").strip())
    paths = (
        f"v1/instruments?group={gq}",
        f"v1/instruments?groupName={gq}",
        f"v1/symbols?group={gq}",
        f"instruments?group={gq}",
        f"v1/instruments",
        "instruments",
        "v1/symbols",
        "symbols",
        "broker/instruments",
    )
    collected: list[str] = []
    for p in paths:
        url = urljoin(base.rstrip("/") + "/", p.lstrip("/"))
        code, data = _get_json_bearer(url, api_key, timeout)
        if code is None:
            return [], "Platform connection required (timeout or network error)"
        if code and 200 <= code < 300 and data is not None:
            # Full list endpoints: filter client-side when group in path absent
            need_filter = "group=" not in url.lower() and "groupname" not in url.lower()
            gn = match_trader_group_name if need_filter else None
            collected.extend(_codes_from_payload(data, gn))
            if collected:
                break
        if code and code >= 400:
            continue
    if not collected:
        return [], "No symbols available (empty list or group not found on platform API)"
    return _dedupe(collected), None


def fetch_symbols_mt5_webapi(api_server_url: str, api_key: str, mt5_server_group_name: str, timeout: int = 20) -> tuple[list[str], str | None]:
    if not api_server_url.strip() or not api_key.strip():
        return [], "Platform connection required (configure MT5 integration API URL and key)"
    base = api_server_url.strip().rstrip("/")
    if not base.startswith("http://") and not base.startswith("https://"):
        base = "http://" + base
    headers_key = api_key.strip()
    paths = (
        f"api/v1/symbols?group={quote(mt5_server_group_name)}",
        "api/v1/symbols",
        "v1/symbols",
        "symbols",
    )
    errors = []
    ctx = ssl.create_default_context()
    for p in paths:
        url = urljoin(base + "/", p)
        for hdr in (
            {"Authorization": f"Bearer {headers_key}"},
            {"X-API-Key": headers_key},
        ):
            req = Request(
                url,
                method="GET",
                headers={"User-Agent": "ForexCRM-SymbolSync/1.0", "Accept": "application/json", **hdr},
            )
            try:
                with urlopen(req, timeout=timeout, context=ctx) as resp:
                    raw = resp.read().decode("utf-8", errors="replace")
                    if not raw.strip():
                        continue
                    data = json.loads(raw)
                    codes = _codes_from_payload(data, None)
                    if codes:
                        return _dedupe(codes), None
            except Exception as e:
                errors.append(f"{p} ({list(hdr.keys())[0]}): {str(e)}")
                continue
    err_msg = "No symbols found. Details: " + " | ".join(errors[:3])
    return [], err_msg[:250]


def sync_symbols_for_mt5_group(mt5_group_id: int) -> tuple[int, str | None]:
    """
    Refresh CrmGroupSymbol for one CRM group. Returns (count, error_message).
    """
    from accounts.models import MT5Group

    from admin_panel.models import CrmGroupSymbol, CrmGroupSyncStatus, TradingPlatformIntegration
    from admin_panel.services.broker_platform_groups import _match_trader_connected

    P = MT5Group.BrokerPlatform

    try:
        mg = MT5Group.objects.select_related("match_trader_broker_group").get(pk=mt5_group_id)
    except MT5Group.DoesNotExist:
        return 0, "CRM group not found"

    status, _ = CrmGroupSyncStatus.objects.get_or_create(mt5_group=mg)
    status.last_attempt_at = timezone.now()
    status.last_error = ""
    status.save(update_fields=["last_attempt_at", "last_error"])

    symbols: list[str] = []
    err: str | None = None
    platform_used = CrmGroupSymbol.SourcePlatform.UNKNOWN

    mt_row = TradingPlatformIntegration.objects.filter(platform=TradingPlatformIntegration.Platform.MT5).first()
    x9_row = TradingPlatformIntegration.objects.filter(platform=TradingPlatformIntegration.Platform.X9_TRADER).first()
    match_row = TradingPlatformIntegration.objects.filter(platform=TradingPlatformIntegration.Platform.MATCH_TRADER).first()
    live_ok = _match_trader_connected()
    mt_key = match_row.api_key if match_row else ""
    mt_base = match_row.api_server_url if match_row else ""

    if mg.platform == P.MATCH_TRADER:
        if not live_ok:
            err = "Platform connection required"
        else:
            gname = ""
            if mg.match_trader_broker_group_id:
                gname = (mg.match_trader_broker_group.name or "").strip()
            if not gname:
                gname = (mg.platform_group_name or "").strip()
            if not gname:
                err = "Platform group not connected (select Match-Trader group / platform group name)"
            else:
                symbols, err = fetch_symbols_match_trader(mt_key, mt_base, gname)
                platform_used = CrmGroupSymbol.SourcePlatform.MATCH_TRADER
    elif mg.platform == P.MT5:
        from mt5_integration.services import _mt5_client, is_mt5_configured
        if not is_mt5_configured():
            err = "Platform connection required (configure MT5 integration with API URL, login and password)"
        else:
            try:
                collected = []
                with _mt5_client() as client:
                    total = client.symbol_total()
                    
                    # Fetch symbols with intelligent connection recovery
                    for i in range(total):
                        attempts = 0
                        while attempts < 3:
                            try:
                                sym_data = client.symbol_next(i)
                                if sym_name := sym_data.get("Symbol"):
                                    collected.append(sym_name)
                                break
                            except Exception:
                                client.disconnect()
                                attempts += 1
                
                if collected:
                    symbols = _dedupe(collected)
                    err = None
                else:
                    err = "No symbols found on MT5 server"
            except Exception as e:
                err = f"MT5 connection error: {str(e)}"
            platform_used = CrmGroupSymbol.SourcePlatform.MT5
    elif mg.platform == P.X9_TRADER:
        if not (x9_row and x9_row.enabled and (x9_row.api_server_url or "").strip()):
            err = "Platform connection required (configure X9 integration)"
        else:
            grp = (mg.platform_group_name or "").strip()
            if not grp:
                err = "Platform group not connected"
            else:
                symbols, err = fetch_symbols_mt5_webapi(
                    x9_row.api_server_url,
                    x9_row.api_key or x9_row.secret_key or "",
                    grp,
                )
                platform_used = CrmGroupSymbol.SourcePlatform.X9
    else:
        err = "Unknown platform on CRM group"

    if err and not symbols:
        status.last_error = err[:2000]
        status.symbol_count = 0
        status.save(update_fields=["last_attempt_at", "last_error", "symbol_count"])
        return 0, err

    if not symbols:
        status.last_error = err or "No symbols available"
        status.symbol_count = 0
        status.save(update_fields=["last_attempt_at", "last_error", "symbol_count"])
        CrmGroupSymbol.objects.filter(mt5_group=mg).delete()
        return 0, status.last_error

    now = timezone.now()
    with transaction.atomic():
        CrmGroupSymbol.objects.filter(mt5_group=mg).delete()
        CrmGroupSymbol.objects.bulk_create(
            [
                CrmGroupSymbol(
                    mt5_group=mg,
                    symbol_name=name,
                    source_platform=platform_used,
                    raw_payload={},
                )
                for name in symbols
            ],
            batch_size=400,
        )

    status.last_success_at = now
    status.last_error = ""
    status.symbol_count = len(symbols)
    status.save(update_fields=["last_attempt_at", "last_success_at", "last_error", "symbol_count"])

    return len(symbols), None


def sync_all_crm_groups() -> dict[str, int]:
    from accounts.models import MT5Group

    totals = {"groups": 0, "symbols": 0, "errors": 0}
    for gid in MT5Group.objects.filter(is_active=True).values_list("id", flat=True):
        totals["groups"] += 1
        n, err = sync_symbols_for_mt5_group(int(gid))
        if err:
            totals["errors"] += 1
        totals["symbols"] += n
    return totals
