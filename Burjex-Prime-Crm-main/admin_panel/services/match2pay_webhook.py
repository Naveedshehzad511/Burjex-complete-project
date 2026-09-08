"""
Match2Pay webhook receiver.

- Validates HMAC-SHA256 of raw body when ``api_secret`` is set (supported signature headers).
- Validates ``Authorization: Bearer <token>`` or ``X-Api-Token`` when ``api_token`` is set.
- On ``status`` = completed (and variants), credits wallet idempotently by ``payment_id``.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
from typing import Any

from django.http import HttpRequest, JsonResponse
from django.utils import timezone

logger = logging.getLogger(__name__)

_SIGNATURE_META_KEYS = (
    "HTTP_X_MATCH2PAY_SIGNATURE",
    "HTTP_X_MATCH2PAY_SIG",
    "HTTP_X_SIGNATURE",
    "HTTP_X_WEBHOOK_SIGNATURE",
    "HTTP_X_HUB_SIGNATURE",
)


def _extract_signature(request: HttpRequest) -> str:
    for key in _SIGNATURE_META_KEYS:
        raw = (request.META.get(key) or "").strip()
        if raw:
            return raw
    return ""


def _extract_bearer_token(request: HttpRequest) -> str:
    auth = (request.META.get("HTTP_AUTHORIZATION") or "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return (request.META.get("HTTP_X_API_TOKEN") or request.META.get("HTTP_X_MATCH2PAY_TOKEN") or "").strip()


def verify_webhook_body(request: HttpRequest, api_secret: str) -> tuple[bool, str]:
    """
    If api_secret is set, require a hex HMAC-SHA256 of the raw body.
    Accepts optional ``sha256=<hex>`` prefix (case-insensitive).
    """
    if not (api_secret or "").strip():
        return True, "secret_not_configured"
    body = request.body or b""
    sig = _extract_signature(request)
    if not sig:
        return False, "missing_signature_header"
    expected = hmac.new(api_secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    candidate = sig.strip()
    if candidate.lower().startswith("sha256="):
        candidate = candidate.split("=", 1)[1].strip()
    candidate = candidate.lower()
    if len(candidate) != len(expected) or not hmac.compare_digest(candidate, expected.lower()):
        return False, "signature_mismatch"
    return True, "ok"


def verify_match2pay_done_signature(parsed: Any, signature: str, api_token: str, api_secret: str) -> tuple[bool, str]:
    """
    Match2Pay v2 callback signature for DONE callbacks:
    transactionAmount(8dp) + transactionCurrency + status + apiToken + apiSecret, SHA-384.
    """
    if not isinstance(parsed, dict):
        return False, "invalid_callback_payload"
    if not (api_secret or "").strip():
        return False, "secret_not_configured"
    sig = (signature or "").strip()
    if sig.lower().startswith("sha384="):
        sig = sig.split("=", 1)[1].strip()
    if not sig:
        return False, "missing_signature_header"
    status = str(parsed.get("status") or "").strip().upper()
    if status != "DONE":
        return False, "not_done_callback"
    amount_raw = parsed.get("transactionAmount")
    currency = str(parsed.get("transactionCurrency") or "").strip().upper()
    if amount_raw is None or not currency:
        return False, "missing_done_signature_fields"
    try:
        from decimal import Decimal, ROUND_DOWN

        amount = Decimal(str(amount_raw)).quantize(Decimal("0.00000000"), rounding=ROUND_DOWN)
    except Exception:
        return False, "invalid_transaction_amount"
    raw = f"{amount}{currency}{status}{api_token or ''}{api_secret or ''}"
    expected = hashlib.sha384(raw.encode("utf-8")).hexdigest()
    if len(sig) == len(expected) and hmac.compare_digest(sig.lower(), expected.lower()):
        return True, "match2pay_done_signature_ok"
    return False, "signature_mismatch"


def verify_api_token_header(request: HttpRequest, api_token: str) -> tuple[bool, str]:
    """If api_token is configured, require matching Bearer or X-Api-Token header."""
    token = (api_token or "").strip()
    if not token:
        return True, "token_not_configured"
    got = _extract_bearer_token(request)
    if not got:
        return False, "missing_api_token"
    if not hmac.compare_digest(got.strip(), token.strip()):
        return False, "api_token_mismatch"
    return True, "ok"


def verify_webhook_request(request: HttpRequest, api_secret: str, api_token: str) -> tuple[bool, str]:
    """
    Apply all configured checks. Both secret and token may be required independently.
    """
    ok_sig, sig_detail = verify_webhook_body(request, api_secret)
    if ok_sig:
        ok_tok, tok_detail = verify_api_token_header(request, api_token)
        if not ok_tok:
            return False, tok_detail
        return True, "ok"

    parsed: Any = None
    try:
        parsed = json.loads((request.body or b"{}").decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        parsed = None
    ok_m2p, m2p_detail = verify_match2pay_done_signature(
        parsed,
        _extract_signature(request),
        api_token,
        api_secret,
    )
    if ok_m2p:
        return True, m2p_detail
    if sig_detail != "secret_not_configured":
        return False, sig_detail
    ok_tok, tok_detail = verify_api_token_header(request, api_token)
    if not ok_tok:
        return False, tok_detail
    return True, "ok"


def _summarize_payload(data: Any, max_len: int = 800) -> str:
    try:
        s = json.dumps(data, default=str, separators=(",", ":"))
    except (TypeError, ValueError):
        s = str(data)
    return s[:max_len]


def handle_match2pay_webhook_request(request: HttpRequest) -> JsonResponse:
    from admin_panel.models import IntegrationConnectionLog, Match2PayIntegrationSettings
    from transactions.services.match2pay_webhook_processor import credit_match2pay_if_completed

    if request.method in ("GET", "HEAD"):
        return JsonResponse({"ok": True, "service": "match2pay_webhook", "method": request.method})

    settings = Match2PayIntegrationSettings.get_solo()
    if not settings.enabled:
        logger.warning("Match2Pay webhook rejected: integration disabled")
        return JsonResponse({"ok": False, "error": "integration_disabled"}, status=503)

    if not (settings.api_secret or "").strip() and not (settings.api_token or "").strip():
        logger.warning("Match2Pay webhook rejected: no api_secret or api_token configured")
        return JsonResponse({"ok": False, "error": "webhook_auth_not_configured"}, status=503)

    body = request.body or b""

    ok_verify, verify_detail = verify_webhook_request(
        request,
        settings.api_secret or "",
        settings.api_token or "",
    )
    parsed: Any = None
    try:
        if body:
            parsed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        parsed = {"_raw_truncated": body[:500].decode("utf-8", errors="replace")}

    summary = _summarize_payload(parsed if parsed is not None else {})
    log_msg = f"verify={verify_detail} enabled={settings.enabled} body={summary}"

    IntegrationConnectionLog.objects.create(
        integration_slug="match2pay_webhook",
        category="PAYMENTS",
        success=ok_verify,
        message=log_msg[:4000],
    )

    now = timezone.now()
    Match2PayIntegrationSettings.objects.filter(pk=settings.pk).update(
        last_webhook_test_ok=ok_verify,
        last_webhook_test_at=now,
    )

    if not ok_verify:
        status = 401 if verify_detail in ("missing_signature_header", "missing_api_token") else 403
        logger.warning("Match2Pay webhook rejected: %s", verify_detail)
        return JsonResponse({"ok": False, "error": verify_detail}, status=status)

    if not isinstance(parsed, dict):
        return JsonResponse({"ok": True, "received": True})

    ok_credit, credit_detail = credit_match2pay_if_completed(parsed=parsed, raw_payload=parsed)
    if not ok_credit:
        logger.error("Match2Pay webhook processing error: %s", credit_detail)
        return JsonResponse({"ok": False, "error": credit_detail}, status=500)

    return JsonResponse({"ok": True, "received": True, "detail": credit_detail})
