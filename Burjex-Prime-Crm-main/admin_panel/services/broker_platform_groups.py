"""
broker_platform_groups.py
─────────────────────────
Build the platform group tree consumed by the Group Management UI
(mt5_platform_groups_json view → /admin/crm/group-management/).

Returns a list of platform dicts:
  [
    {
      "code":    "MT5",
      "label":   "MetaTrader 5",
      "live_ok": True,
      "groups":  ["New_Setup\\Pro", "New_Setup\\Standard", …],
    },
    …
  ]
"""
from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────────────
# MT5
# ─────────────────────────────────────────────────────────────────────────────

def _fetch_mt5_groups() -> tuple[bool, list[str]]:
    """Connect to MT5 server and retrieve all group names via GROUP_TOTAL / GROUP_NEXT."""
    try:
        from mt5_integration.client import MT5Client
        from mt5_integration.services import _get_mt5_settings, is_mt5_configured

        if not is_mt5_configured():
            return False, []

        cfg = _get_mt5_settings()
        # Cap connect time so a dead MT5 host cannot stall Group Management.
        timeout = min(float(cfg.get("timeout") or 3.0), 3.0)

        with MT5Client(
            host=cfg["host"],
            port=cfg["port"],
            login=cfg["login"],
            password=cfg["password"],
            timeout=timeout,
            use_encryption=cfg.get("encrypt", False),
        ) as client:
            total = client.group_total()
            groups: list[str] = []
            for i in range(total):
                try:
                    grp = client.group_next(i)
                    if not grp:
                        continue
                    # SDK returns {"Group": "New_Setup\\Pro", ...}
                    name = (
                        grp.get("Group")
                        or grp.get("Name")
                        or grp.get("name")
                        or ""
                    ).strip()
                    if name:
                        groups.append(name)
                except Exception as e:
                    logger.debug("MT5 group_next(%d) error: %s", i, e)
            return True, groups

    except Exception as exc:
        logger.warning("MT5 group fetch failed: %s", exc)
        return False, []


# ─────────────────────────────────────────────────────────────────────────────
# Match-Trader
# ─────────────────────────────────────────────────────────────────────────────

def _match_trader_connected() -> bool:
    """Return True if Match-Trader integration is enabled and configured."""
    try:
        from admin_panel.models import TradingPlatformIntegration
        row = TradingPlatformIntegration.objects.filter(
            platform=TradingPlatformIntegration.Platform.MATCH_TRADER,
            enabled=True,
        ).first()
        return bool(row and row.api_server_url and row.api_key)
    except Exception:
        return False


def _fetch_match_trader_groups() -> tuple[bool, list[str]]:
    """Fetch broker groups from the Match-Trader catalog (MatchTraderBrokerGroup)."""
    try:
        from admin_panel.models import MatchTraderBrokerGroup
        names = list(
            MatchTraderBrokerGroup.objects.values_list("name", flat=True).order_by("name")
        )
        connected = _match_trader_connected()
        return connected, names
    except Exception as exc:
        logger.debug("Match-Trader group fetch: %s", exc)
        return False, []


# ─────────────────────────────────────────────────────────────────────────────
# cTrader
# ─────────────────────────────────────────────────────────────────────────────

def _fetch_ctrader_groups() -> tuple[bool, list[str]]:
    """Return cTrader groups if the integration is active (stub — no live API yet)."""
    try:
        from admin_panel.models import TradingPlatformIntegration
        row = TradingPlatformIntegration.objects.filter(
            platform=TradingPlatformIntegration.Platform.CTRADER,
            enabled=True,
        ).first()
        if not row:
            return False, []
        # cTrader groups are not fetched live yet; return empty but show as connected.
        return True, []
    except Exception:
        return False, []


# ─────────────────────────────────────────────────────────────────────────────
# BTrader
# ─────────────────────────────────────────────────────────────────────────────

def _fetch_btrader_groups() -> tuple[bool, list[str]]:
    """Fetch trading group names via BTrader HMAC GET /v1/crm/groups."""
    try:
        from btrader_integration.services import fetch_btrader_groups
        return fetch_btrader_groups()
    except Exception as exc:
        logger.warning("BTrader group fetch failed: %s", exc)
        return False, []


# ─────────────────────────────────────────────────────────────────────────────
# Public entry point
# ─────────────────────────────────────────────────────────────────────────────

def _safe_platform_entry(
    *,
    code: str,
    label: str,
    fetcher,
) -> dict[str, Any]:
    """Never let one platform's hang/exception omit the others from the tree."""
    try:
        live_ok, groups = fetcher()
    except Exception as exc:
        logger.warning("%s group fetch crashed: %s", code, exc)
        live_ok, groups = False, []
    return {
        "code": code,
        "label": label,
        "live_ok": bool(live_ok),
        "groups": sorted(groups or []),
    }


def build_platform_group_tree() -> list[dict[str, Any]]:
    """
    Return the full platform group tree for the Group Management UI.
    Only platforms that are enabled in TradingPlatformIntegration are included.
    """
    from admin_panel.models import TradingPlatformIntegration

    enabled_platforms: set[str] = set(
        TradingPlatformIntegration.objects.filter(enabled=True).values_list(
            "platform", flat=True
        )
    )

    result: list[dict[str, Any]] = []

    # Fetch BTrader/Match-Trader before MT5 so a stuck MT5 manager cannot block
    # the Platform Group picker (each entry is also isolated via _safe_platform_entry).
    if TradingPlatformIntegration.Platform.BTRADER in enabled_platforms:
        result.append(
            _safe_platform_entry(
                code="BTRADER",
                label="BTrader",
                fetcher=_fetch_btrader_groups,
            )
        )

    if TradingPlatformIntegration.Platform.MATCH_TRADER in enabled_platforms:
        result.append(
            _safe_platform_entry(
                code="MATCH_TRADER",
                label="Match-Trader",
                fetcher=_fetch_match_trader_groups,
            )
        )

    if TradingPlatformIntegration.Platform.CTRADER in enabled_platforms:
        result.append(
            _safe_platform_entry(
                code="CTRADER",
                label="cTrader",
                fetcher=_fetch_ctrader_groups,
            )
        )

    if TradingPlatformIntegration.Platform.MT5 in enabled_platforms:
        result.append(
            _safe_platform_entry(
                code="MT5",
                label="MetaTrader 5",
                fetcher=_fetch_mt5_groups,
            )
        )

    return result
