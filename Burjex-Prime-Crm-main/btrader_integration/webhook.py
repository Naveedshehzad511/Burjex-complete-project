"""
Outbound webhook receiver: BTrader → CRM.

URL: POST /api/btrader/webhook/
Headers: X-BT-Timestamp, X-BT-Signature = HMAC_SHA256(webhookSecret, "{ts}.{rawBody}")
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time

from django.http import HttpResponse, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from .services import get_webhook_secret, persist_account_snapshot, sync_account

logger = logging.getLogger(__name__)

# Event types that imply account money/metrics may have changed.
_SYNC_EVENT_TYPES = {
    "account.snapshot",
    "BALANCE_CHANGED",
    "balance.changed",
    "deal.created",
    "POSITION_OPENED",
    "POSITION_CLOSED",
    "position.opened",
    "position.closed",
    "position.modified",
    "MARGIN_CALL",
    "margin.call",
    "stop.out",
}


def _verify_signature(raw_body: bytes, timestamp: str, signature: str, secret: str) -> bool:
    if not secret or not timestamp or not signature:
        return False
    try:
        ts_ms = int(timestamp)
    except (TypeError, ValueError):
        return False
    # ±5 minutes replay window (same as BTrader contract)
    if abs(int(time.time() * 1000) - ts_ms) > 5 * 60 * 1000:
        return False
    msg = f"{timestamp}.".encode("utf-8") + raw_body
    expected = hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()
    got = signature.strip().lower()
    if got.startswith("sha256="):
        got = got[7:]
    return hmac.compare_digest(expected.lower(), got)


def _extract_login(data: dict) -> str:
    if not isinstance(data, dict):
        return ""
    for key in ("login", "loginId", "accountLogin", "accountNumber"):
        val = data.get(key)
        if val is not None and str(val).strip():
            return str(val).strip()
    # Nested account object
    nested = data.get("account")
    if isinstance(nested, dict):
        return _extract_login(nested)
    return ""


def _looks_like_snapshot(data: dict) -> bool:
    if not isinstance(data, dict):
        return False
    return any(k in data for k in ("balance", "equity", "freeMargin", "free_margin"))


@csrf_exempt
@require_http_methods(["POST"])
def btrader_webhook(request):
    secret = get_webhook_secret()
    raw = request.body or b""
    ts = request.headers.get("X-BT-Timestamp") or request.META.get("HTTP_X_BT_TIMESTAMP") or ""
    sig = request.headers.get("X-BT-Signature") or request.META.get("HTTP_X_BT_SIGNATURE") or ""

    if not secret:
        logger.warning("BTrader webhook rejected: webhook secret not configured")
        return JsonResponse({"ok": False, "error": "webhook not configured"}, status=503)

    if not _verify_signature(raw, str(ts), str(sig), secret):
        logger.warning("BTrader webhook signature/timestamp invalid")
        return JsonResponse({"ok": False, "error": "invalid signature"}, status=401)

    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        return JsonResponse({"ok": False, "error": "invalid json"}, status=400)

    event_id = str(payload.get("id") or "")
    event_type = str(payload.get("type") or "")
    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}

    # Idempotent: balance updates are safe to re-apply; respond 2xx quickly.
    try:
        if event_type in _SYNC_EVENT_TYPES or _looks_like_snapshot(data) or _looks_like_snapshot(payload):
            snap = data if _looks_like_snapshot(data) else (payload if _looks_like_snapshot(payload) else None)
            login = _extract_login(data) or _extract_login(payload)
            if snap and login:
                persist_account_snapshot(login, snap)
            elif login:
                sync_account(login)
            elif snap and snap.get("login"):
                persist_account_snapshot(str(snap["login"]), snap)
            else:
                # Event without login (e.g. positionId only) — ignore gracefully.
                logger.debug(
                    "BTrader webhook %s id=%s has no login; acknowledged without persist",
                    event_type,
                    event_id,
                )
        if event_type in ("position.closed", "POSITION_CLOSED"):
            try:
                from ib.btrader_rebates import credit_btrader_close

                credit_btrader_close(
                    login=_extract_login(data) or _extract_login(payload),
                    deal_id=str(data.get("dealId") or data.get("deal_id") or payload.get("dealId") or ""),
                    symbol=str(data.get("symbol") or payload.get("symbol") or ""),
                    lots=data.get("volume") if data.get("volume") is not None else payload.get("volume"),
                    position_id=str(data.get("positionId") or data.get("position_id") or payload.get("positionId") or ""),
                )
            except Exception:
                logger.exception("BTrader IB rebate failed type=%s id=%s", event_type, event_id)
    except Exception:
        logger.exception("BTrader webhook handler error type=%s id=%s", event_type, event_id)
        # Still 200 would skip retries with bad data; return 500 so BTrader retries.
        return JsonResponse({"ok": False, "error": "processing failed"}, status=500)

    return HttpResponse(status=204)
