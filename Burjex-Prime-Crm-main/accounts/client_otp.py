"""In-app 6-digit OTP for email verify and password reset (no email links)."""

from __future__ import annotations

import hashlib
import logging
from datetime import timedelta

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone
from django.utils.crypto import get_random_string

from admin_panel.email_service import send_dynamic_email
from admin_panel.templated_mail import send_event_email

logger = logging.getLogger(__name__)

OTP_TTL = timedelta(minutes=10)
OTP_TTL_SECONDS = int(OTP_TTL.total_seconds())
RESEND_SECONDS = 30
MAX_ATTEMPTS = 5
EMAIL_PREFIX = "eotp$"
PWD_PREFIX = "potp$"


def new_otp() -> str:
    return get_random_string(6, allowed_chars="0123456789")


def _digest(user_id: int, purpose: str, code: str) -> str:
    raw = f"{settings.SECRET_KEY}:client-otp:{purpose}:{user_id}:{code.strip()}".encode()
    return hashlib.sha256(raw).hexdigest()


def _attempts_key(purpose: str, user_id: int) -> str:
    return f"client_otp_att:{purpose}:{user_id}"


def _sent_key(purpose: str, user_id: int) -> str:
    return f"client_otp_sent:{purpose}:{user_id}"


def send_otp_email(user, code: str) -> tuple[bool, str]:
    extra = {
        "otp": code,
        "password": code,
        "name": user.display_name() if hasattr(user, "display_name") else "",
    }
    ok, reason = send_event_email(
        "otp_verification",
        to_email=user.email,
        user=user,
        extra_context=extra,
    )
    if ok:
        return True, reason
    ok2, err = send_dynamic_email(
        user.email,
        "Your verification code",
        f"Your verification code is {code}. It expires in 10 minutes. Do not share it.",
        user=user,
        event_key="otp_verification",
    )
    if not ok2:
        logger.info("otp email failed user_id=%s reason=%s fallback=%s", user.pk, reason, err)
        return False, err or reason
    return True, "fallback_dynamic"


def issue_otp(user, *, purpose: str = "email") -> tuple[bool, str]:
    """Store a hashed OTP on the user and email the code. Never logs the code."""
    now = timezone.now()
    sent_at = cache.get(_sent_key(purpose, user.pk))
    if sent_at:
        return False, f"Please wait {RESEND_SECONDS}s before requesting a new code."
    code = new_otp()
    prefix = EMAIL_PREFIX if purpose == "email" else PWD_PREFIX
    user.email_token = prefix + _digest(user.pk, purpose, code)
    user.email_token_created_at = now
    user.save(update_fields=["email_token", "email_token_created_at"])
    cache.set(_attempts_key(purpose, user.pk), 0, OTP_TTL_SECONDS)
    ok, reason = send_otp_email(user, code)
    if not ok:
        return False, "Could not send the verification code. Try again."
    cache.set(_sent_key(purpose, user.pk), 1, RESEND_SECONDS)
    return True, "Verification code sent to your email."


def verify_otp(user, code: str, *, purpose: str = "email", consume: bool = True) -> tuple[bool, str]:
    code = (code or "").strip()
    if not code.isdigit() or len(code) != 6:
        return False, "Enter the 6-digit code from your email."
    created = user.email_token_created_at
    if not created or timezone.now() > created + OTP_TTL:
        return False, "This code has expired. Request a new one."
    prefix = EMAIL_PREFIX if purpose == "email" else PWD_PREFIX
    stored = (user.email_token or "").strip()
    if not stored.startswith(prefix):
        return False, "No active code. Request a new one."
    attempts = int(cache.get(_attempts_key(purpose, user.pk)) or 0)
    if attempts >= MAX_ATTEMPTS:
        return False, "Too many attempts. Request a new code."
    expected = prefix + _digest(user.pk, purpose, code)
    if stored != expected:
        cache.set(_attempts_key(purpose, user.pk), attempts + 1, OTP_TTL_SECONDS)
        left = MAX_ATTEMPTS - attempts - 1
        if left <= 0:
            return False, "Too many attempts. Request a new code."
        return False, f"Invalid code. {left} attempts left."
    if consume:
        consume_otp(user, purpose=purpose)
    return True, "ok"


def consume_otp(user, *, purpose: str = "email") -> None:
    user.email_token = ""
    user.save(update_fields=["email_token"])
    cache.delete(_attempts_key(purpose, user.pk))
    cache.delete(_sent_key(purpose, user.pk))


def sync_btrader_login(user, *, password: str | None = None, is_active: bool | None = None) -> bool:
    """Portal email login uses the BTrader user row, not CRM. Returns False on failure."""
    try:
        from btrader_integration.services import _client_from_settings, is_btrader_configured

        if not is_btrader_configured() or not (user.email or "").strip():
            return False
        body: dict = {"email": user.email.strip().lower()}
        if password:
            body["newPassword"] = password
        if is_active is not None:
            body["isActive"] = bool(is_active)
        if "newPassword" not in body and "isActive" not in body:
            return True
        _client_from_settings().set_user_credentials(body)
        return True
    except Exception:
        logger.exception("btrader credential sync failed user_id=%s", getattr(user, "pk", None))
        return False


def activate_verified_client(user, *, password: str | None = None) -> None:
    user.email_verified = True
    user.email_verified_at = timezone.now()
    user.is_active = True
    user.email_token = ""
    user.save(update_fields=["email_verified", "email_verified_at", "is_active", "email_token"])
    sync_btrader_login(user, password=password, is_active=True)
