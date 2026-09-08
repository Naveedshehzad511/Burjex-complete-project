"""Auth operations reusing accounts forms and the same business rules as HTML views."""

from __future__ import annotations

import logging
import uuid
from datetime import timedelta

import pyotp
from django.contrib.auth import login, logout
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from django.utils import timezone
from django.utils.crypto import get_random_string
from rest_framework.authtoken.models import Token

from accounts.forms import ClientSignupForm, EmailOrUsernameAuthenticationForm, ForgotPasswordForm
from accounts.models import User
from accounts.password_reset import password_reset_url, user_from_uid_token
from accounts.views import _send_verification_email
from admin_panel.email_service import send_dynamic_email
from admin_panel.models import EmailVerificationSettings, SignupSettings
from admin_panel.templated_mail import send_event_email
from enterprise.audit import get_client_ip

logger = logging.getLogger(__name__)

PENDING_TOTP_PREFIX = "api_pending_totp:"


def _issue_token(user: User) -> str:
    token, _ = Token.objects.get_or_create(user=user)
    return token.key


def _form_errors(form) -> dict:
    return {k: [str(e) for e in v] for k, v in form.errors.items()}


def _is_private_or_loopback_ip(ip: str) -> bool:
    ip = (ip or "").strip()
    if not ip:
        return False
    if ip in {"127.0.0.1", "::1", "localhost"}:
        return True
    if ip.startswith("10.") or ip.startswith("192.168.") or ip.startswith("10.0.2."):
        return True
    if ip.startswith("172."):
        try:
            second = int(ip.split(".")[1])
            return 16 <= second <= 31
        except Exception:
            return False
    return False


def _client_login_ip_allowed(request) -> bool:
    from django.conf import settings as dj_settings

    allow = getattr(dj_settings, "ENTERPRISE_CLIENT_LOGIN_IP_ALLOWLIST", None) or []
    if not allow:
        return True
    ip = get_client_ip(request)
    if ip in allow:
        return True
    if getattr(dj_settings, "DEBUG", False) and getattr(
        dj_settings, "ENTERPRISE_CLIENT_LOGIN_ALLOW_PRIVATE_NETWORKS", False
    ):
        return _is_private_or_loopback_ip(ip)
    return False


def client_login(request, username: str, password: str) -> tuple[bool, dict]:
    """Mirror UserLoginView.form_valid rules; return (ok, payload_or_errors)."""
    if not _client_login_ip_allowed(request):
        return False, {
            "message": "Your IP address is not authorized for client login.",
            "errors": {"non_field_errors": ["IP not allowed."]},
        }

    form = EmailOrUsernameAuthenticationForm(request=request, data={"username": username, "password": password})
    if not form.is_valid():
        return False, {"message": "Validation failed.", "errors": _form_errors(form)}

    user = form.get_user()
    ev = EmailVerificationSettings.get_solo()
    if ev.enabled and not user.email_verified:
        request.session["pending_verify_email"] = user.email
        return False, {
            "message": "Please verify your email before login.",
            "errors": {"non_field_errors": ["Please verify your email before login."]},
            "data": {"email_verification_required": True, "email": user.email},
        }
    if not user.is_user():
        return False, {
            "message": "User access only. Please login using staff login.",
            "errors": {"non_field_errors": ["User access only."]},
        }
    r = getattr(user, "restriction", None)
    if r and r.disable_client_area:
        return False, {
            "message": "Your account has been disabled. Please contact support.",
            "errors": {"non_field_errors": ["Account disabled."]},
        }
    if user.totp_enabled and user.totp_secret:
        request.session["pending_user_totp"] = user.pk
        pending = f"{PENDING_TOTP_PREFIX}{user.pk}:{get_random_string(32)}"
        request.session["api_pending_user_totp_token"] = pending
        return True, {
            "totp_required": True,
            "pending_token": pending,
            "message": "Two-factor authentication required.",
            "user_id": user.pk,
        }

    login(request, user)
    # New clients (within 48h, zero accounts): ensure demo exists after email verify.
    demo_account = None
    try:
        from api.services.signup_demo import ensure_signup_demo_for_new_client

        demo_account = ensure_signup_demo_for_new_client(user, force=False)
    except Exception:
        logger.exception("api client_login signup demo ensure failed user_id=%s", user.pk)

    token = _issue_token(user)
    payload = {
        "totp_required": False,
        "token": token,
        "force_password_change": bool(user.force_password_change),
        "user": user,
    }
    if demo_account:
        payload["demo_account"] = {
            k: demo_account[k]
            for k in (
                "login_id",
                "password",
                "platform",
                "account_kind",
                "account_type_name",
                "leverage",
                "balance",
                "currency",
                "auto_provisioned",
            )
            if k in demo_account
        }
    return True, payload


def staff_login(request, username: str, password: str) -> tuple[bool, dict]:
    """Mirror AdminLoginView.form_valid rules."""
    from django.conf import settings

    allow = getattr(settings, "ENTERPRISE_ADMIN_IP_ALLOWLIST", None) or []
    if allow:
        ip = get_client_ip(request)
        if ip not in allow:
            return False, {"message": "Admin login is not allowed from this IP address.", "errors": {"non_field_errors": ["IP not allowed."]}}

    form = EmailOrUsernameAuthenticationForm(request=request, data={"username": username, "password": password})
    if not form.is_valid():
        return False, {"message": "Validation failed.", "errors": _form_errors(form)}

    user = form.get_user()
    if not user.can_use_staff_login_portal():
        return False, {
            "message": "This login is for staff only (admin, banker, sales manager, or account manager).",
            "errors": {"non_field_errors": ["Staff access only."]},
        }
    if user.totp_enabled and user.totp_secret:
        request.session["pending_admin_totp"] = user.pk
        pending = f"{PENDING_TOTP_PREFIX}admin:{user.pk}:{get_random_string(32)}"
        request.session["api_pending_admin_totp_token"] = pending
        return True, {
            "totp_required": True,
            "pending_token": pending,
            "message": "Two-factor authentication required.",
            "user_id": user.pk,
        }

    login(request, user)
    token = _issue_token(user)
    return True, {
        "totp_required": False,
        "token": token,
        "home_path": user.staff_home_path(),
        "user": user,
    }


def verify_client_totp(request, code: str, pending_token: str = "") -> tuple[bool, dict]:
    uid = request.session.get("pending_user_totp")
    stored = request.session.get("api_pending_user_totp_token") or ""
    if pending_token and stored and pending_token != stored:
        return False, {"message": "Invalid pending token.", "errors": {"pending_token": ["Invalid pending token."]}}
    if not uid:
        return False, {"message": "No pending TOTP session.", "errors": {"non_field_errors": ["No pending TOTP session."]}}
    user = User.objects.filter(pk=uid).first()
    if not user or not user.totp_enabled or not user.totp_secret:
        request.session.pop("pending_user_totp", None)
        return False, {"message": "Invalid TOTP session.", "errors": {"non_field_errors": ["Invalid TOTP session."]}}
    if not pyotp.TOTP(user.totp_secret).verify((code or "").replace(" ", "").strip(), valid_window=1):
        return False, {"message": "Invalid authentication code.", "errors": {"code": ["Invalid authentication code."]}}
    request.session.pop("pending_user_totp", None)
    request.session.pop("api_pending_user_totp_token", None)
    login(request, user)
    demo_account = None
    try:
        from api.services.signup_demo import ensure_signup_demo_for_new_client

        demo_account = ensure_signup_demo_for_new_client(user, force=False)
    except Exception:
        logger.exception("api client_totp signup demo ensure failed user_id=%s", user.pk)
    payload = {
        "token": _issue_token(user),
        "force_password_change": bool(user.force_password_change),
        "user": user,
    }
    if demo_account:
        payload["demo_account"] = {
            k: demo_account[k]
            for k in (
                "login_id",
                "password",
                "platform",
                "account_kind",
                "account_type_name",
                "leverage",
                "balance",
                "currency",
                "auto_provisioned",
            )
            if k in demo_account
        }
    return True, payload


def verify_admin_totp(request, code: str, pending_token: str = "") -> tuple[bool, dict]:
    uid = request.session.get("pending_admin_totp")
    stored = request.session.get("api_pending_admin_totp_token") or ""
    if pending_token and stored and pending_token != stored:
        return False, {"message": "Invalid pending token.", "errors": {"pending_token": ["Invalid pending token."]}}
    if not uid:
        return False, {"message": "No pending TOTP session.", "errors": {"non_field_errors": ["No pending TOTP session."]}}
    user = User.objects.filter(pk=uid).first()
    if not user or not user.totp_enabled or not user.totp_secret:
        request.session.pop("pending_admin_totp", None)
        return False, {"message": "Invalid TOTP session.", "errors": {"non_field_errors": ["Invalid TOTP session."]}}
    if not pyotp.TOTP(user.totp_secret).verify((code or "").replace(" ", "").strip(), valid_window=1):
        return False, {"message": "Invalid authentication code.", "errors": {"code": ["Invalid authentication code."]}}
    request.session.pop("pending_admin_totp", None)
    request.session.pop("api_pending_admin_totp_token", None)
    login(request, user)
    return True, {
        "token": _issue_token(user),
        "home_path": user.staff_home_path(),
        "user": user,
    }


def signup_field_config() -> dict:
    """Expose admin SignupSettings so mobile/web clients match required fields."""
    signup_settings = SignupSettings.get_solo()
    ev = EmailVerificationSettings.get_solo()
    return {
        "fields": {
            "full_name": signup_settings.full_name_mode,
            "first_name": signup_settings.first_name_mode,
            "last_name": signup_settings.last_name_mode,
            "email": signup_settings.email_mode,
            "phone": signup_settings.phone_mode,
            "country": signup_settings.country_mode,
            "address": signup_settings.address_mode,
            "password": signup_settings.password_mode,
        },
        "captcha_enabled": bool(signup_settings.captcha_enabled),
        "email_verification_enabled": bool(ev.enabled),
        "email_verification_required": bool(getattr(ev, "required", True)),
    }


def client_signup(request, data: dict) -> tuple[bool, dict]:
    """Reuse ClientSignupForm + same create path as client_signup_view (without HTML redirects)."""
    signup_settings = SignupSettings.get_solo()
    ev = EmailVerificationSettings.get_solo()

    # Normalize mobile payloads to the same shape as the HTML portal form.
    payload = {k: v for k, v in dict(data or {}).items()}
    full_name = (payload.get("full_name") or "").strip()
    first_name = (payload.get("first_name") or "").strip()
    last_name = (payload.get("last_name") or "").strip()
    if full_name and not first_name and not last_name:
        parts = full_name.split(None, 1)
        payload["first_name"] = parts[0]
        payload["last_name"] = parts[1] if len(parts) > 1 else parts[0]
        payload["full_name"] = full_name
    # API/mobile clients have no HTML captcha widget; accept submit as the tick.
    if signup_settings.captcha_enabled and not (payload.get("captcha") or "").strip():
        payload["captcha"] = "on"

    signup_ref = (payload.get("signup_ref") or "").strip()
    signup_ib_legacy = (payload.get("signup_ib_legacy") or "").strip()
    if signup_ref and hasattr(request, "session"):
        request.session["signup_ib_ref"] = signup_ref
        from django.db.models import F
        from ib.models import IBProfile

        IBProfile.objects.filter(ib_code=signup_ref).update(link_clicks=F("link_clicks") + 1)
    if signup_ib_legacy and hasattr(request, "session"):
        request.session["signup_ib_user_id"] = signup_ib_legacy

    form = ClientSignupForm(
        payload,
        signup_settings=signup_settings,
        require_verification_email=ev.enabled,
    )
    if not form.is_valid():
        return False, {"message": "Validation failed.", "errors": _form_errors(form)}

    first_name = (form.cleaned_data.get("first_name") or "").strip()
    last_name = (form.cleaned_data.get("last_name") or "").strip()
    full_name = (form.cleaned_data.get("full_name") or "").strip()
    if full_name and not first_name and not last_name:
        parts = full_name.split(" ", 1)
        first_name = parts[0]
        last_name = parts[1] if len(parts) > 1 else ""
    email = (form.cleaned_data.get("email") or "").strip().lower()
    phone = (form.cleaned_data.get("phone") or "").strip()
    country = (form.cleaned_data.get("country") or "").strip()
    address = (form.cleaned_data.get("address") or "").strip()
    password = form.cleaned_data.get("password") or ""
    if not password:
        password = User.objects.make_random_password(length=10)

    base_username = email or f"user_{phone or 'client'}"
    candidate = base_username
    while User.objects.filter(username=candidate).exists():
        candidate = f"{base_username}_{get_random_string(4, '0123456789')}"

    try:
        with transaction.atomic():
            user = User.objects.create_user(
                username=candidate,
                email=email,
                first_name=first_name,
                last_name=last_name,
                phone=phone,
                country=country,
                address=address,
                role=User.Roles.CLIENT,
                password=password,
            )
            from ib.referral import assign_ib_from_signup_referral

            assign_ib_from_signup_referral(request, user)

        # After user row is committed: open a real BTrader DEMO (best-effort).
        signup_demo = None
        try:
            from api.services.signup_demo import ensure_signup_demo_for_new_client

            signup_demo = ensure_signup_demo_for_new_client(user, force=True)
        except Exception:
            logger.exception("api client_signup demo account auto-create failed user_id=%s", user.pk)

        try:
            from django.urls import reverse
            from enterprise.staff_notify import broadcast_staff_notification

            reg_token = f"[reg_user:{user.pk}]"
            broadcast_staff_notification(
                "New client registration",
                f"{reg_token} {user.display_name()} ({user.email}) registered.",
                action_url=reverse("admin-user-list"),
                dedupe_body_contains=reg_token,
            )
        except Exception:
            logger.exception("api client_signup staff notification failed user_id=%s", user.pk)

        if ev.enabled:
            user.refresh_from_db()
            user.is_active = False
            user.email_verified = False
            user.email_token = uuid.uuid4().hex
            user.email_token_created_at = timezone.now()
            user.save(
                update_fields=[
                    "is_active",
                    "email_verified",
                    "email_token",
                    "email_token_created_at",
                ]
            )
            try:
                send_event_email("account_created", to_email=user.email, user=user)
            except Exception:
                logger.exception("api client_signup account_created email failed")
            try:
                _send_verification_email(user, request)
            except Exception:
                logger.exception("api client_signup verification email failed")
            request.session["registration_pending_email"] = user.email
            request.session["pending_verify_email"] = user.email
            payload = {
                "email_verification_required": True,
                "email": user.email,
                "user_id": user.pk,
                "message": "Verification email sent. Please check your email.",
            }
            if signup_demo:
                payload["demo_account"] = {
                    k: signup_demo[k]
                    for k in (
                        "login_id",
                        "platform",
                        "account_kind",
                        "account_type_name",
                        "leverage",
                        "balance",
                        "currency",
                        "auto_provisioned",
                    )
                    if k in signup_demo
                }
            return True, payload

        user.email_verified = True
        user.email_verified_at = timezone.now()
        user.save(update_fields=["email_verified", "email_verified_at"])
        try:
            send_event_email("account_created", to_email=user.email, user=user)
        except Exception:
            logger.exception("api client_signup account_created email failed")
        login(request, user)
        payload = {
            "email_verification_required": False,
            "token": _issue_token(user),
            "user": user,
            "message": "Account created successfully.",
        }
        if signup_demo:
            # Include password only when we also issue a session token (immediate login).
            payload["demo_account"] = {
                k: signup_demo[k]
                for k in (
                    "login_id",
                    "password",
                    "platform",
                    "account_kind",
                    "account_type_name",
                    "leverage",
                    "balance",
                    "currency",
                    "auto_provisioned",
                )
                if k in signup_demo
            }
        return True, payload
    except IntegrityError:
        return False, {
            "message": "Unable to create this account. That email may already be registered.",
            "errors": {"email": ["Unable to create this account. That email may already be registered."]},
        }
    except Exception:
        logger.exception("api client_signup failed")
        return False, {
            "message": "Registration could not be completed. Please try again or contact support.",
            "errors": {"non_field_errors": ["Registration failed."]},
        }


def forgot_password(email: str, *, portal: bool = True) -> dict:
    form = ForgotPasswordForm(data={"email": email})
    if not form.is_valid():
        return {"ok": False, "errors": _form_errors(form)}
    email = form.cleaned_data["email"].strip().lower()
    user = User.objects.filter(email__iexact=email).first()
    if user:
        reset_link = password_reset_url(user, portal=portal)
        ok, reason = send_event_email(
            "forgot_password",
            to_email=user.email,
            user=user,
            extra_context={
                "reset_link": reset_link,
                "verify_url": reset_link,
                "reset_url": reset_link,
                "name": user.display_name(),
            },
        )
        if not ok:
            logger.info(
                "api forgot_password email skipped user_id=%s reason=%s",
                user.pk,
                reason,
            )
    return {
        "ok": True,
        "message": "If this email exists, password reset instructions have been sent.",
    }


def confirm_password_reset(uidb64: str, token: str, new_password: str) -> dict:
    user = user_from_uid_token(uidb64, token)
    if not user:
        return {
            "ok": False,
            "errors": {"token": ["This reset link is invalid or has expired."]},
        }
    try:
        validate_password(new_password, user=user)
    except DjangoValidationError as exc:
        return {"ok": False, "errors": {"new_password": list(exc.messages)}}
    user.set_password(new_password)
    fields = ["password"]
    if hasattr(user, "force_password_change"):
        user.force_password_change = False
        fields.append("force_password_change")
    user.save(update_fields=fields)
    Token.objects.filter(user=user).delete()
    return {"ok": True, "message": "Password updated. You can sign in now."}


def verify_email_token(token: str) -> tuple[bool, str]:
    ev = EmailVerificationSettings.get_solo()
    user = User.objects.filter(email_token=token).first()
    if not user:
        return False, "Invalid verification token."
    if user.email_verified:
        return True, "Email already verified."
    created_at = user.email_token_created_at or timezone.now()
    expiry_hours = ev.token_expiry_hours if ev.token_expiry_hours and ev.token_expiry_hours > 0 else 24
    if timezone.now() > created_at + timedelta(hours=expiry_hours):
        return False, "Verification token expired. Please request a new one."
    user.email_verified = True
    user.email_verified_at = timezone.now()
    user.is_active = True
    user.email_token = ""
    user.save(update_fields=["email_verified", "email_verified_at", "is_active", "email_token"])
    send_event_email("email_verified", to_email=user.email, user=user)
    return True, "Email verified successfully. Please login."


def resend_verification(request, email: str) -> tuple[bool, str]:
    ev = EmailVerificationSettings.get_solo()
    if not (ev.enabled and ev.allow_resend):
        return False, "Resend verification is disabled."
    email = (email or "").strip().lower()
    user = User.objects.filter(email__iexact=email).first()
    if not user:
        return False, "Email not found."
    if user.email_verified:
        return True, "Email is already verified."
    user.email_token = uuid.uuid4().hex
    user.email_token_created_at = timezone.now()
    user.save(update_fields=["email_token", "email_token_created_at"])
    _send_verification_email(user, request)
    request.session["pending_verify_email"] = user.email
    return True, "Verification email resent."


def change_password(user: User, current_password: str, new_password: str) -> tuple[bool, dict]:
    if not user.check_password(current_password):
        return False, {"errors": {"current_password": ["Current password is incorrect."]}}
    try:
        validate_password(new_password, user=user)
    except DjangoValidationError as exc:
        return False, {"errors": {"new_password": list(exc.messages)}}
    user.set_password(new_password)
    updates = ["password"]
    if user.force_password_change:
        user.force_password_change = False
        updates.append("force_password_change")
    user.save(update_fields=updates)
    Token.objects.filter(user=user).delete()
    token = _issue_token(user)
    return True, {"token": token, "message": "Password changed successfully."}


def api_logout(request, user: User | None = None) -> None:
    if user and user.is_authenticated:
        Token.objects.filter(user=user).delete()
    logout(request)
    if hasattr(request, "session"):
        request.session.flush()
