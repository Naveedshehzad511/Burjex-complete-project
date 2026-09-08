"""Match-Trader integration: admin UI, JSON APIs, and public /api/integrations routes."""

from __future__ import annotations

import json
import logging
from typing import Any

from django.contrib.auth.decorators import login_required
from django.core.cache import cache
from django.http import JsonResponse
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import (
    IntegrationConnectionLog,
    MatchTraderBrokerGroup,
    MatchTraderLog,
    MatchTraderSettings,
    TradingPlatformIntegration,
)
from .services.match_trader_catalog import (
    diagnose_match_trader_groups_get,
    fetch_match_trader_catalog,
    match_trader_test_secret_key,
    run_match_trader_catalog_sync,
    sync_match_trader_broker_groups_from_catalog,
)

logger = logging.getLogger(__name__)

_MT_TEST_LIMIT = 25
_MT_TEST_WINDOW = 60
_MT_SAVE_LIMIT = 40
_MT_SAVE_WINDOW = 60


def _mt_row() -> TradingPlatformIntegration | None:
    return TradingPlatformIntegration.objects.filter(
        platform=TradingPlatformIntegration.Platform.MATCH_TRADER
    ).first()


def _parse_payload(request) -> dict[str, Any]:
    ct = (request.content_type or "").lower()
    if "application/json" in ct and request.body:
        try:
            raw = json.loads(request.body.decode("utf-8"))
            return raw if isinstance(raw, dict) else {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}
    out: dict[str, Any] = {}
    for k in request.POST:
        out[k] = request.POST.get(k, "")
    return out


def _post(payload: dict[str, Any], key: str, default: str = "") -> str:
    v = payload.get(key, default)
    return (v if isinstance(v, str) else str(v)).strip()


def _allow_rate(user_id: int, action: str, limit: int, window: int) -> bool:
    k = f"mt_rl:{action}:{user_id}"
    try:
        n = cache.incr(k)
    except ValueError:
        cache.add(k, 1, timeout=window)
        n = 1
    return n <= limit


def _mt_write_log(kind: str, success: bool, message: str, detail: dict | None = None) -> None:
    try:
        MatchTraderLog.objects.create(
            kind=kind,
            success=success,
            message=(message or "")[:8000],
            detail=detail,
        )
    except Exception as exc:  # pragma: no cover
        logger.warning("MatchTraderLog write failed: %s", exc)


def _apply_mt_save(mt: MatchTraderSettings, payload: dict[str, Any]) -> None:
    prev_base = (mt.base_url or "").strip()
    prev_rest = (mt.rest_base_url or "").strip()
    prev_grpc = (mt.grpc_address or "").strip()
    posted_base = _post(payload, "base_url")[:500]
    posted_grpc = _post(payload, "grpc_address")[:500]
    # Accept camelCase from alternate clients
    if not posted_grpc:
        posted_grpc = _post(payload, "grpcAddress")[:500]
    new_key = _post(payload, "api_key")
    if posted_base:
        mt.base_url = posted_base
    if posted_grpc:
        mt.grpc_address = posted_grpc
    if new_key:
        mt.set_api_key(new_key)
    if "rest_base_url" in payload or "restBaseUrl" in payload:
        mt.rest_base_url = (_post(payload, "rest_base_url") or _post(payload, "restBaseUrl"))[:500]
    base_changed = (mt.base_url or "").strip() != prev_base
    rest_changed = (mt.rest_base_url or "").strip() != prev_rest
    grpc_changed = (mt.grpc_address or "").strip() != prev_grpc
    key_changed = bool(new_key)
    if base_changed or rest_changed or grpc_changed or key_changed:
        mt.connection_status = MatchTraderSettings.ConnectionStatus.DISCONNECTED
        mt.last_connected = None
        mt.last_test_success_at = None
    mt.last_save_at = timezone.now()


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def match_trader_enterprise_page(request):
    """Integrations → Trading Platforms → Match-Trader (enterprise UI)."""
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    return render(
        request,
        "admin_panel/integrations/match_trader_enterprise.html",
        {
            "title": "Match-Trader",
            "mt": mt,
            "trading_row": row,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def match_trader_trading_monitor(request):
    """Admin → Trading Monitor (Match-Trader)."""
    mt = MatchTraderSettings.get_solo()
    logs = list(MatchTraderLog.objects.order_by("-created_at")[:200])
    return render(
        request,
        "admin_panel/trading_monitor/match_trader.html",
        {
            "title": "Trading Monitor — Match-Trader",
            "mt": mt,
            "logs": logs,
        },
    )


def _json_test(request) -> JsonResponse:
    if not _allow_rate(request.user.id, "test", _MT_TEST_LIMIT, _MT_TEST_WINDOW):
        return JsonResponse(
            {
                "ok": False,
                "status": "rate_limited",
                "error_message": "Connection failed: too many test requests; wait and retry.",
                "user_error": "Rate limited — try again shortly.",
            },
            status=429,
        )

    payload = _parse_payload(request)
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()

    base_in = _post(payload, "base_url")[:500]
    grpc_in = _post(payload, "grpc_address")[:500] or _post(payload, "grpcAddress")[:500]
    api_key_in = _post(payload, "api_key")
    rest_in = (_post(payload, "rest_base_url") or _post(payload, "restBaseUrl"))[:500]
    # Test connection always uses the values submitted in this request (no silent DB fallback).
    base = base_in
    grpc = grpc_in
    key = api_key_in

    if not base:
        return JsonResponse(
            {
                "ok": False,
                "status": "validation_error",
                "user_error": "Base URL is required",
                "error_detail": "Enter the broker base URL before testing.",
            },
            status=400,
        )
    if not grpc:
        return JsonResponse(
            {
                "ok": False,
                "status": "validation_error",
                "user_error": "gRPC address is required",
                "error_detail": "Enter the broker gRPC host (e.g. grpc-broker-api.match-trader.com).",
            },
            status=400,
        )
    if not key:
        return JsonResponse(
            {
                "ok": False,
                "status": "validation_error",
                "user_error": "Secret API key is required",
                "error_detail": "Enter the secret API key for this test (not loaded from storage).",
            },
            status=400,
        )

    result = match_trader_test_secret_key(key, base, grpc, timeout=20, rest_base_url=rest_in)
    now = timezone.now()

    if base_in:
        mt.base_url = base_in[:500]
    if grpc_in:
        mt.grpc_address = grpc_in[:500]
    if api_key_in:
        mt.set_api_key(api_key_in)
    if "rest_base_url" in payload or "restBaseUrl" in payload:
        mt.rest_base_url = (_post(payload, "rest_base_url") or _post(payload, "restBaseUrl"))[:500]

    if result["ok"]:
        mt.connection_status = MatchTraderSettings.ConnectionStatus.CONNECTED
        mt.last_connected = now
        mt.last_test_success_at = now
        mt.last_save_at = now
        mt.last_test_latency_ms = result.get("latency_ms")
        mt.last_grpc_ok = True
        mt.last_connection_error = ""
        # Persist credentials before catalog sync (sync reads MatchTraderSettings from DB).
        mt.save()
        try:
            cat_counts, _err = run_match_trader_catalog_sync(timeout=15)
            result["catalog_sync"] = cat_counts
            total = int((cat_counts or {}).get("total") or 0)
            if total <= 0:
                result["ok"] = False
                mt.connection_status = MatchTraderSettings.ConnectionStatus.ERROR
                mt.last_test_success_at = None
                mt.last_grpc_ok = False
                mt.last_connection_error = (
                    "gRPC and groups probe succeeded but no groups were stored in the CRM catalog. "
                    "Check that the REST base matches your broker API."
                )[:2000]
                result["user_error"] = "Catalog sync stored no group rows"
                result["detail"] = mt.last_connection_error
                _steps = list(result.get("diagnostic_steps") or [])
                _steps.append(
                    {
                        "step": 8,
                        "name": "catalog_sync",
                        "label": "CRM catalog sync",
                        "ok": False,
                        "message": "No group rows stored",
                        "detail": mt.last_connection_error[:1500],
                    }
                )
                result["diagnostic_steps"] = _steps
                result["failure_step"] = 8
        except Exception as exc:  # pragma: no cover
            logger.warning("Match-Trader catalog sync after test failed: %s", exc)
            result["ok"] = False
            result["catalog_sync"] = {"trading": 0, "account": 0, "servers": 0, "total": 0, "error": str(exc)}
            mt.connection_status = MatchTraderSettings.ConnectionStatus.ERROR
            mt.last_test_success_at = None
            mt.last_grpc_ok = False
            mt.last_connection_error = (str(exc) or "Catalog sync failed")[:2000]
            result["user_error"] = "Catalog sync failed"
            result["detail"] = mt.last_connection_error
            _steps = list(result.get("diagnostic_steps") or [])
            _steps.append(
                {
                    "step": 8,
                    "name": "catalog_sync",
                    "label": "CRM catalog sync",
                    "ok": False,
                    "message": "Catalog sync error",
                    "detail": (str(exc) or "Catalog sync failed")[:1500],
                }
            )
            result["diagnostic_steps"] = _steps
            result["failure_step"] = 8
        mt.save()
    else:
        mt.connection_status = MatchTraderSettings.ConnectionStatus.ERROR
        mt.last_test_latency_ms = result.get("latency_ms")
        mt.last_grpc_ok = bool(result.get("grpc_ok"))
        mt.last_connection_error = (result.get("detail") or result.get("user_error") or "")[:2000]

        mt.save()

    if row:
        row.last_test_ok = result["ok"]
        row.last_test_detail = (
            f"OK latency_ms={result.get('latency_ms')}"
            if result["ok"]
            else (result.get("user_error") or result.get("detail") or "failed")[:500]
        )
        row.last_test_at = now
        row.save(update_fields=["last_test_ok", "last_test_detail", "last_test_at"])

    IntegrationConnectionLog.objects.create(
        integration_slug="match_trader",
        category="TRADING",
        success=result["ok"],
        message=json.dumps(
            {
                "latency_ms": result.get("latency_ms"),
                "user_error": result.get("user_error"),
                "detail": result.get("detail"),
                "rest_http_status": result.get("rest_http_status"),
                "rest_verified_url": result.get("rest_verified_url"),
                "failure_step": result.get("failure_step"),
                "diagnostic_steps": result.get("diagnostic_steps"),
            },
            default=str,
        )[:4000],
    )
    _mt_write_log(
        MatchTraderLog.Kind.CONNECTION,
        result["ok"],
        result.get("user_message")
        if result["ok"]
        else (result.get("user_error") or result.get("detail") or "Connection failed"),
        {"latency_ms": result.get("latency_ms"), "detail": result.get("detail")},
    )
    if not result["ok"]:
        _mt_write_log(
            MatchTraderLog.Kind.ERROR,
            False,
            result.get("user_error") or result.get("detail") or "Connection failed",
            {"detail": result.get("detail")},
        )

    body = {
        "ok": result["ok"],
        "status": "connected" if result["ok"] else "failed",
        "latency_ms": result.get("latency_ms"),
        "platform": "Match-Trader",
        "user_message": result.get("user_message") or "",
        "user_error": result.get("user_error") or "",
        "error_detail": result.get("detail") or "",
        "resolved_base": result.get("resolved_base") or "",
        "rest_http_status": result.get("rest_http_status"),
        "rest_verified_url": result.get("rest_verified_url") or "",
        "groups_extracted_count": result.get("groups_extracted_count"),
        "groups_winning_path": result.get("groups_winning_path") or "",
        "failure_step": result.get("failure_step"),
        "diagnostic_steps": result.get("diagnostic_steps") or [],
    }
    if result.get("catalog_sync") is not None:
        body["catalog_sync"] = result["catalog_sync"]
    return JsonResponse(body)


def _json_save(request) -> JsonResponse:
    if not _allow_rate(request.user.id, "save", _MT_SAVE_LIMIT, _MT_SAVE_WINDOW):
        return JsonResponse({"ok": False, "status": "rate_limited", "message": "Too many save requests."}, status=429)

    payload = _parse_payload(request)
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()

    save_and_connect = _post(payload, "save_and_connect").lower() in (
        "1",
        "true",
        "yes",
        "on",
    ) or _post(payload, "save_and_activate").lower() in ("1", "true", "yes", "on")
    want_active = _post(payload, "is_active").lower() in ("1", "true", "yes", "on")

    _apply_mt_save(mt, payload)

    if not (mt.base_url or "").strip():
        return JsonResponse(
            {"ok": False, "status": "validation_error", "message": "Base URL is required."},
            status=400,
        )
    if not (mt.grpc_address or "").strip():
        return JsonResponse(
            {"ok": False, "status": "validation_error", "message": "gRPC address is required."},
            status=400,
        )
    if not mt.has_api_key():
        return JsonResponse(
            {"ok": False, "status": "validation_error", "message": "Secret API key is required."},
            status=400,
        )

    mt.save()
    if row:
        row.api_key = ""
        row.secret_key = ""
        row.api_version = ""
        row.payment_gateway_uuid = ""
        row.server_name = ""
        row.network_address = ""
        row.live_manager_token = ""
        row.demo_manager_token = ""
        row.broker_name = ""
        row.live_network_address = ""
        row.demo_network_address = ""
        row.api_server_url = ""
        row.save()

    if not save_and_connect:
        if not want_active:
            mt.is_active = False
            mt.sync_users = False
            mt.sync_accounts = False
            mt.sync_trades = False
            mt.sync_balance = False
            mt.sync_deposits = False
            mt.sync_withdrawals = False
            mt.sync_orders = False
            mt.sync_positions = False
            mt.save(
                update_fields=[
                    "is_active",
                    "sync_users",
                    "sync_accounts",
                    "sync_trades",
                    "sync_balance",
                    "sync_deposits",
                    "sync_withdrawals",
                    "sync_orders",
                    "sync_positions",
                    "updated_at",
                ]
            )
            if row:
                row.enabled = False
                row.save(update_fields=["enabled"])
        _mt_write_log(MatchTraderLog.Kind.API, True, "Configuration saved", {"save_and_connect": False})
        return JsonResponse({"ok": True, "status": "saved"})

    now = timezone.now()
    test_key = mt.get_api_key()
    conn = match_trader_test_secret_key(
        test_key,
        (mt.base_url or "").strip(),
        (mt.grpc_address or "").strip(),
        timeout=20,
        rest_base_url=(mt.rest_base_url or "").strip(),
    )
    if not conn["ok"]:
        mt.connection_status = MatchTraderSettings.ConnectionStatus.ERROR
        mt.last_grpc_ok = False
        mt.last_connection_error = (conn.get("detail") or conn.get("user_error") or "")[:2000]
        mt.is_active = False
        mt.sync_users = False
        mt.sync_accounts = False
        mt.sync_trades = False
        mt.sync_balance = False
        mt.sync_deposits = False
        mt.sync_withdrawals = False
        mt.sync_orders = False
        mt.sync_positions = False
        mt.save()
        if row:
            row.enabled = False
            row.save(update_fields=["enabled"])
        _mt_write_log(
            MatchTraderLog.Kind.ERROR,
            False,
            conn.get("user_error") or conn.get("detail") or "Save & connect failed",
            {"detail": conn.get("detail")},
        )
        return JsonResponse(
            {
                "ok": False,
                "status": "connection_failed",
                "message": conn.get("detail") or conn.get("user_error") or "Connection failed.",
                "user_error": conn.get("user_error") or "",
                "error_detail": conn.get("detail") or "",
                "failure_step": conn.get("failure_step"),
                "diagnostic_steps": conn.get("diagnostic_steps") or [],
            },
            status=400,
        )

    mt.connection_status = MatchTraderSettings.ConnectionStatus.CONNECTED
    mt.last_connected = now
    mt.last_test_success_at = now
    mt.last_test_latency_ms = conn.get("latency_ms")
    mt.last_connection_error = ""
    mt.last_grpc_ok = True
    https_for_catalog = (mt.rest_base_url or mt.base_url or "").strip() or (conn.get("resolved_base") or "").strip()
    catalog = fetch_match_trader_catalog(test_key, https_for_catalog, timeout=15)
    t_cnt, a_cnt, s_cnt = sync_match_trader_broker_groups_from_catalog(catalog)
    if (t_cnt + a_cnt + s_cnt) <= 0:
        mt.connection_status = MatchTraderSettings.ConnectionStatus.ERROR
        mt.last_grpc_ok = False
        mt.last_test_success_at = None
        mt.last_connection_error = (
            "Connection test passed but no platform groups were written to the catalog. "
            "Verify the broker REST API and base URL."
        )[:2000]
        mt.is_active = False
        mt.sync_users = False
        mt.sync_accounts = False
        mt.sync_trades = False
        mt.sync_balance = False
        mt.sync_deposits = False
        mt.sync_withdrawals = False
        mt.sync_orders = False
        mt.sync_positions = False
        mt.save()
        if row:
            row.enabled = False
            row.save(update_fields=["enabled"])
        _mt_write_log(
            MatchTraderLog.Kind.ERROR,
            False,
            "Save & connect: catalog sync stored zero groups",
            {"catalog": catalog},
        )
        return JsonResponse(
            {
                "ok": False,
                "status": "catalog_empty",
                "message": mt.last_connection_error,
                "user_error": "No platform groups were synced.",
                "error_detail": mt.last_connection_error,
            },
            status=400,
        )

    if want_active:
        mt.is_active = True
        mt.sync_users = True
        mt.sync_accounts = True
        mt.sync_trades = True
        mt.sync_balance = True
        mt.sync_deposits = True
        mt.sync_withdrawals = True
        mt.sync_orders = True
        mt.sync_positions = True
    else:
        mt.is_active = False
        mt.sync_users = False
        mt.sync_accounts = False
        mt.sync_trades = False
        mt.sync_balance = False
        mt.sync_deposits = False
        mt.sync_withdrawals = False
        mt.sync_orders = False
        mt.sync_positions = False
    mt.save()
    if row:
        row.enabled = bool(want_active)
        row.last_test_ok = True
        row.last_test_detail = f"save_connect latency_ms={conn.get('latency_ms')}"[:500]
        row.last_test_at = now
        row.save(update_fields=["enabled", "last_test_ok", "last_test_detail", "last_test_at"])
    _mt_write_log(
        MatchTraderLog.Kind.CONNECTION,
        True,
        "Saved, connected, and catalog synced",
        {
            "latency_ms": conn.get("latency_ms"),
            "catalog_trading": t_cnt,
            "catalog_account": a_cnt,
            "catalog_servers": s_cnt,
        },
    )
    _mt_write_log(MatchTraderLog.Kind.API, True, "Configuration saved", {"save_and_connect": True})
    return JsonResponse(
        {
            "ok": True,
            "status": "saved_and_connected",
            "latency_ms": conn.get("latency_ms"),
            "catalog": {"trading": t_cnt, "account": a_cnt, "servers": s_cnt},
        }
    )


def _json_status(request) -> JsonResponse:
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    return JsonResponse(
        {
            "platform": "Match-Trader",
            "configured": mt.has_credentials(),
            "is_active": mt.is_active,
            "connection_status": mt.connection_status,
            "environment": mt.environment,
            "last_connected": mt.last_connected.isoformat() if mt.last_connected else None,
            "last_sync_at": mt.last_sync_at.isoformat() if mt.last_sync_at else None,
            "last_test_latency_ms": mt.last_test_latency_ms,
            "accounts_connected_count": mt.accounts_connected_count,
            "open_trades_running_count": mt.open_trades_running_count,
            "pending_orders_display_count": mt.pending_orders_display_count,
            "integration_row_enabled": bool(row and row.enabled),
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_save(request):
    return _json_save(request)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_test(request):
    return _json_test(request)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_reset(request):
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    mt.base_url = ""
    mt.rest_base_url = ""
    mt.grpc_address = ""
    mt.api_key_encrypted = ""
    mt.is_active = False
    mt.environment = MatchTraderSettings.Environment.LIVE
    mt.connection_status = MatchTraderSettings.ConnectionStatus.DISCONNECTED
    mt.last_connected = None
    mt.last_save_at = None
    mt.last_test_success_at = None
    mt.last_test_latency_ms = None
    mt.last_grpc_ok = False
    mt.last_sync_at = None
    mt.last_connection_error = ""
    mt.sync_users = False
    mt.sync_accounts = False
    mt.sync_trades = False
    mt.sync_balance = False
    mt.sync_deposits = False
    mt.sync_withdrawals = False
    mt.sync_orders = False
    mt.sync_positions = False
    mt.accounts_connected_count = 0
    mt.open_trades_running_count = 0
    mt.pending_orders_display_count = 0
    mt.save()
    if row:
        row.enabled = False
        row.save(update_fields=["enabled"])
    _mt_write_log(MatchTraderLog.Kind.API, True, "Configuration reset")
    return JsonResponse({"ok": True, "status": "reset"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_activate(request):
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    if mt.connection_status != MatchTraderSettings.ConnectionStatus.CONNECTED or not mt.has_credentials():
        return JsonResponse({"status": "failed"}, status=400)
    if not mt.activation_ready():
        return JsonResponse({"status": "failed", "message": "Save configuration, then run a successful test."}, status=400)
    mt.is_active = True
    mt.sync_users = True
    mt.sync_accounts = True
    mt.sync_trades = True
    mt.sync_balance = True
    mt.sync_deposits = True
    mt.sync_withdrawals = True
    mt.sync_orders = True
    mt.sync_positions = True
    mt.save()
    if row:
        row.enabled = True
        row.save(update_fields=["enabled"])
    cat_counts: dict[str, int] = {}
    catalog_error = ""
    try:
        cat_counts, cat_err = run_match_trader_catalog_sync(timeout=15)
        if cat_err:
            catalog_error = cat_err
    except Exception as exc:  # pragma: no cover
        logger.warning("Match-Trader catalog sync on activate failed: %s", exc)
        catalog_error = str(exc)
    _mt_write_log(
        MatchTraderLog.Kind.API,
        True,
        "Integration activated",
        {"catalog_sync": cat_counts, "catalog_error": catalog_error or None},
    )
    return JsonResponse(
        {
            "status": "activated",
            "catalog_sync": cat_counts,
            "catalog_error": catalog_error or None,
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_deactivate(request):
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    mt.is_active = False
    mt.sync_users = False
    mt.sync_accounts = False
    mt.sync_trades = False
    mt.sync_balance = False
    mt.sync_deposits = False
    mt.sync_withdrawals = False
    mt.sync_orders = False
    mt.sync_positions = False
    mt.save()
    if row:
        row.enabled = False
        row.save(update_fields=["enabled"])
    _mt_write_log(MatchTraderLog.Kind.API, True, "Integration deactivated")
    return JsonResponse({"status": "deactivated"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_sync_catalog(request):
    """Manually refresh Match-Trader trading/account/server groups into CRM catalog."""
    if not _allow_rate(request.user.id, "sync_catalog", _MT_TEST_LIMIT, _MT_TEST_WINDOW):
        return JsonResponse(
            {"ok": False, "message": "Too many sync requests; wait and retry."},
            status=429,
        )
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    if not row:
        return JsonResponse({"ok": False, "message": "Match-Trader integration row missing."}, status=400)
    integration_on = bool(row.enabled)
    broker_ready = mt.connection_status == MatchTraderSettings.ConnectionStatus.CONNECTED and mt.has_credentials()
    if not integration_on and not broker_ready:
        return JsonResponse(
            {
                "ok": False,
                "message": "Turn on Match-Trader or run a successful connection test first.",
            },
            status=400,
        )
    if not mt.has_api_key() or not (mt.rest_base_url or mt.base_url or "").strip():
        return JsonResponse(
            {"ok": False, "message": "REST/Base URL and API key are required."},
            status=400,
        )
    try:
        counts, err = run_match_trader_catalog_sync(timeout=20)
    except Exception as exc:  # pragma: no cover
        logger.exception("match_trader_api_sync_catalog failed")
        return JsonResponse({"ok": False, "message": str(exc)}, status=500)
    if err:
        _mt_write_log(MatchTraderLog.Kind.API, False, f"Catalog sync failed: {err}", {})
        return JsonResponse({"ok": False, "message": err, "catalog_sync": counts}, status=400)
    _mt_write_log(MatchTraderLog.Kind.API, True, "Match-Trader catalog synced (manual)", {"catalog": counts})
    return JsonResponse({"ok": True, "catalog_sync": counts})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_test_groups_sync(request):
    """
    Diagnostic: GET {normalized REST base}/groups — verify URL, token, endpoint; full body logged server-side.
    """
    if not _allow_rate(request.user.id, "test_groups_sync", _MT_TEST_LIMIT, _MT_TEST_WINDOW):
        return JsonResponse(
            {"ok": False, "message": "Too many test requests; wait and retry."},
            status=429,
        )
    payload = _parse_payload(request)
    mt = MatchTraderSettings.get_solo()
    row = _mt_row()
    key = _post(payload, "api_key") or mt.get_api_key()
    rest = (_post(payload, "rest_base_url") or _post(payload, "restBaseUrl"))[:500]
    base = rest or _post(payload, "base_url")[:500] or (mt.rest_base_url or mt.base_url or "").strip()
    path_raw = (_post(payload, "groups_path") or "").strip()
    if not key or not base:
        return JsonResponse(
            {
                "ok": False,
                "message": "REST/Base URL and API key required (enter in form or save configuration first).",
            },
            status=400,
        )
    try:
        diag_kw: dict = {"api_key": key, "https_base": base, "timeout": 22}
        if path_raw:
            diag_kw["path"] = path_raw.lstrip("/")
        result = diagnose_match_trader_groups_get(**diag_kw)
    except Exception as exc:  # pragma: no cover
        logger.exception("match_trader_api_test_groups_sync failed")
        return JsonResponse({"ok": False, "message": str(exc)}, status=500)

    if row and not row.enabled:
        result = {**result, "integration_enabled": False, "hint": "Turn on Match-Trader in Trading Platforms so Group Management loads this catalog."}
    else:
        result = {**result, "integration_enabled": bool(row and row.enabled)}

    _mt_write_log(
        MatchTraderLog.Kind.API,
        bool(result.get("ok")),
        f"Match-Trader GET groups diagnostic: {result.get('diagnosis_code')}",
        {
            "request_url": result.get("request_url"),
            "http_status": result.get("http_status"),
            "diagnosis_code": result.get("diagnosis_code"),
            "groups_count": result.get("groups_extracted_count"),
        },
    )
    # Full body is in application logs; omit huge parsed_json from HTTP response
    safe = {k: v for k, v in result.items() if k != "parsed_json"}
    if int(result.get("full_response_length") or 0) <= 40000 and result.get("parsed_json") is not None:
        safe["parsed_json"] = result["parsed_json"]
    else:
        safe["parsed_json_omitted"] = True
    return JsonResponse({"ok": bool(result.get("ok")), **safe})


def matchtrader_test_connection(request):
    """Legacy path alias."""
    return match_trader_api_test(request)


# --- Public API paths (same auth + CSRF as admin session) ---


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def api_integrations_match_trader_test(request):
    """POST /api/integrations/match-trader/test/"""
    return _json_test(request)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def api_integrations_match_trader_save(request):
    """POST /api/integrations/match-trader/save/"""
    return _json_save(request)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def api_integrations_match_trader_status(request):
    """GET /api/integrations/match-trader/status/"""
    return _json_status(request)


def _json_map_groups(request) -> JsonResponse:
    from accounts.models import MT5Group

    payload = _parse_payload(request)
    raw = payload.get("mappings")
    if isinstance(raw, str) and raw.strip():
        try:
            raw = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raw = None
    if not isinstance(raw, list):
        return JsonResponse({"ok": False, "message": "Invalid mappings payload."}, status=400)
    for item in raw:
        if not isinstance(item, dict):
            continue
        pk = item.get("id")
        cg = item.get("crm_group_id")
        row = MatchTraderBrokerGroup.objects.filter(id=pk).first()
        if not row:
            continue
        if cg in (None, "", "null"):
            row.crm_group = None
        else:
            try:
                gid = int(cg)
            except (TypeError, ValueError):
                continue
            row.crm_group = MT5Group.objects.filter(id=gid).first()
        row.save(update_fields=["crm_group", "updated_at"])
    _mt_write_log(MatchTraderLog.Kind.API, True, "Match-Trader CRM group mappings updated", {})
    return JsonResponse({"ok": True})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def match_trader_api_map_groups(request):
    return _json_map_groups(request)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def api_integrations_match_trader_map_groups(request):
    """POST /api/integrations/match-trader/map-groups/"""
    return _json_map_groups(request)
