from datetime import timedelta
import logging
import uuid

from django.db import IntegrityError, transaction

import pyotp
from admin_panel.branding_assets import (
    login_page_context,
    resolve_branding_context,
    totp_admin_logo_url,
    totp_user_logo_url,
)

from django.conf import settings
from django.contrib import messages
from django.contrib.auth import login
from django.contrib.auth import logout
from django.contrib.auth.decorators import login_required
from django.contrib.auth.views import LoginView, LogoutView
from django.contrib.auth.hashers import check_password, make_password
from django.views.decorators.http import require_http_methods
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils.crypto import get_random_string
from django.utils import timezone

from enterprise.audit import get_client_ip
from admin_panel.models import (
    AdminAuthBrandingSettings,
    EmailVerificationSettings,
    SMTPSettings,
    SignupSettings,
    UserAuthBrandingSettings,
)
from admin_panel.email_service import send_dynamic_email
from admin_panel.templated_mail import send_event_email
from .models import User
from .forms import (
    ClientSignupForm,
    EmailOrUsernameAuthenticationForm,
    ForgotPasswordForm,
    SetNewPasswordForm,
)
from .password_reset import password_reset_url, user_from_uid_token

logger = logging.getLogger(__name__)


@login_required
def open_account_redirect(request):
    account_type = (request.GET.get("type") or "real").strip().lower()
    if account_type == "demo":
        return redirect("user-open-demo-account")
    return redirect("user-open-live-account")


class CustomLoginView(LoginView):
    """
    Auth entrypoint for all roles.
    Admin staff goes to the CRM admin panel; other roles go to the user portal.
    """

    template_name = "accounts/login.html"
    authentication_form = EmailOrUsernameAuthenticationForm

    def get_success_url(self):
        role = self.request.user.role
        if role in {User.Roles.ADMIN, User.Roles.BANKER, User.Roles.IB}:
            return "/admin/dashboard/"
        return "/user/dashboard/"

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        brand = UserAuthBrandingSettings.get_solo()
        ctx["brand"] = brand
        ctx["branding"] = brand
        ctx["site_settings"] = brand
        ctx["branding_v"] = int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1
        ctx["brand_logo_url"] = totp_user_logo_url(self.request)
        ctx.update(resolve_branding_context(self.request))
        ctx.update(login_page_context("user", self.request))
        return ctx


class CustomLogoutView(LogoutView):
    template_name = "accounts/logout.html"

    def get_next_page(self):
        # Always return to user login after logout.
        return "/user/login/"


class AdminLoginView(LoginView):
    template_name = "accounts/admin_login.html"
    authentication_form = EmailOrUsernameAuthenticationForm

    # Prevent LoginView's default behavior of redirecting to the `next` query param.
    redirect_field_name = None

    def dispatch(self, request, *args, **kwargs):
        allow = getattr(settings, "ENTERPRISE_ADMIN_IP_ALLOWLIST", None) or []
        if request.method == "POST" and allow:
            ip = get_client_ip(request)
            if ip not in allow:
                messages.error(request, "Admin login is not allowed from this IP address.")
                return redirect(request.path)
        return super().dispatch(request, *args, **kwargs)

    def get_success_url(self):
        u = self.request.user
        return u.staff_home_path() if u.is_authenticated else "/admin/dashboard/"

    def get_redirect_url(self, *args, **kwargs):
        return self.get_success_url()

    def form_valid(self, form):
        user = form.get_user()
        if not user.can_use_staff_login_portal():
            form.add_error(
                None,
                "This login is for staff only (admin, banker, sales manager, or account manager).",
            )
            return self.form_invalid(form)
        if user.totp_enabled and user.totp_secret:
            self.request.session["pending_admin_totp"] = user.pk
            return redirect("admin-totp-verify")
        return super().form_valid(form)

    def _otp_session_data(self):
        return self.request.session.get("admin_email_otp_login") or {}

    def _set_otp_session_data(self, data: dict):
        self.request.session["admin_email_otp_login"] = data
        self.request.session.modified = True

    def _clear_otp_session_data(self):
        self.request.session.pop("admin_email_otp_login", None)
        self.request.session.modified = True

    def _otp_context_state(self):
        data = self._otp_session_data()
        now_ts = int(timezone.now().timestamp())
        expires_ts = int(data.get("expires_ts") or 0)
        sent_ts = int(data.get("sent_ts") or 0)
        if expires_ts and now_ts >= expires_ts:
            self._clear_otp_session_data()
            return {"otp_mode": False, "otp_email": "", "otp_resend_after": 0, "otp_attempts_left": 5}
        resend_after = max(0, (sent_ts + 30) - now_ts) if sent_ts else 0
        attempts = int(data.get("attempts") or 0)
        return {
            "otp_mode": bool(data),
            "otp_email": data.get("email", ""),
            "otp_resend_after": resend_after,
            "otp_attempts_left": max(0, 5 - attempts),
        }

    def post(self, request, *args, **kwargs):
        action = (request.POST.get("action") or "").strip()
        if action == "otp_send":
            email = (request.POST.get("otp_email") or "").strip().lower()
            if not email:
                messages.error(request, "Admin email is required.")
                return self.get(request, *args, **kwargs)
            data = self._otp_session_data()
            now_ts = int(timezone.now().timestamp())
            sent_ts = int(data.get("sent_ts") or 0)
            if sent_ts and now_ts < sent_ts + 30:
                messages.error(request, f"Please wait {sent_ts + 30 - now_ts}s before resending OTP.")
                return self.get(request, *args, **kwargs)
            user = User.objects.filter(email__iexact=email).first()
            if not user or not user.can_use_staff_login_portal():
                messages.error(request, "No staff account found for this email.")
                return self.get(request, *args, **kwargs)
            otp_code = get_random_string(6, allowed_chars="0123456789")
            ok, err = send_dynamic_email(
                user.email,
                "Admin OTP Sign In",
                f"Your OTP is {otp_code}. It expires in 5 minutes.",
                user=user,
                event_key="admin_login_otp",
            )
            if not ok:
                messages.error(request, f"Unable to send OTP: {err}")
                return self.get(request, *args, **kwargs)
            self._set_otp_session_data(
                {
                    "user_id": user.id,
                    "email": user.email,
                    "code_hash": make_password(otp_code),
                    "expires_ts": now_ts + 300,
                    "sent_ts": now_ts,
                    "attempts": 0,
                }
            )
            messages.success(request, "OTP sent to your admin email.")
            return self.get(request, *args, **kwargs)
        if action == "otp_verify":
            code = (request.POST.get("otp_code") or "").strip()
            data = self._otp_session_data()
            now_ts = int(timezone.now().timestamp())
            if not data:
                messages.error(request, "No active OTP session. Please send OTP first.")
                return self.get(request, *args, **kwargs)
            if now_ts >= int(data.get("expires_ts") or 0):
                self._clear_otp_session_data()
                messages.error(request, "OTP expired. Please request a new OTP.")
                return self.get(request, *args, **kwargs)
            attempts = int(data.get("attempts") or 0)
            if attempts >= 5:
                self._clear_otp_session_data()
                messages.error(request, "Maximum OTP attempts reached. Please request a new OTP.")
                return self.get(request, *args, **kwargs)
            if not code or not check_password(code, data.get("code_hash", "")):
                attempts += 1
                data["attempts"] = attempts
                self._set_otp_session_data(data)
                if attempts >= 5:
                    self._clear_otp_session_data()
                    messages.error(request, "Maximum OTP attempts reached. Please request a new OTP.")
                else:
                    messages.error(request, f"Invalid OTP. Attempts left: {5 - attempts}.")
                return self.get(request, *args, **kwargs)
            user = User.objects.filter(id=data.get("user_id")).first()
            if not user or not user.can_use_staff_login_portal():
                self._clear_otp_session_data()
                messages.error(request, "Staff account not available.")
                return self.get(request, *args, **kwargs)
            self._clear_otp_session_data()
            login(request, user)
            return redirect(user.staff_home_path())
        return super().post(request, *args, **kwargs)

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        brand = AdminAuthBrandingSettings.get_solo()
        ctx["brand"] = brand
        ctx["branding"] = brand
        ctx["branding_v"] = int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1
        ctx["brand_logo_url"] = totp_admin_logo_url(self.request)
        ctx.update(resolve_branding_context(self.request))
        ctx.update(login_page_context("admin", self.request))
        ctx.update(self._otp_context_state())
        return ctx


class UserLoginView(LoginView):
    template_name = "accounts/user_login.html"
    authentication_form = EmailOrUsernameAuthenticationForm

    # Prevent redirecting to `next` (which can accidentally be `/admin/dashboard/`).
    # `/user/login/` must always redirect to `/user/dashboard/`.
    redirect_field_name = None

    def dispatch(self, request, *args, **kwargs):
        allow = getattr(settings, "ENTERPRISE_CLIENT_LOGIN_IP_ALLOWLIST", None) or []
        if request.method == "POST" and allow:
            ip = get_client_ip(request)
            if ip not in allow:
                messages.error(request, "Your IP address is not authorized for client login.")
                return redirect(request.path)
        return super().dispatch(request, *args, **kwargs)

    def get_success_url(self):
        return "/user/dashboard/"

    def get_redirect_url(self, *args, **kwargs):
        return self.get_success_url()

    def form_valid(self, form):
        user = form.get_user()
        ev = EmailVerificationSettings.get_solo()
        if ev.enabled and not user.email_verified:
            form.add_error(None, "Please verify your email before login.")
            self.request.session["pending_verify_email"] = user.email
            return self.form_invalid(form)
        if not user.is_user():
            form.add_error(None, "User access only. Please login using User Login.")
            return self.form_invalid(form)
        r = getattr(user, "restriction", None)
        if r and r.disable_client_area:
            form.add_error(None, "Your account has been disabled. Please contact support.")
            return self.form_invalid(form)
        if user.totp_enabled and user.totp_secret:
            self.request.session["pending_user_totp"] = user.pk
            self.request.session["pending_user_totp_next"] = self.get_success_url()
            return redirect("user-totp-verify")
        resp = super().form_valid(form)
        if user.force_password_change:
            return redirect("user-change-password")
        return resp

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        brand = UserAuthBrandingSettings.get_solo()
        ctx["brand"] = brand
        ctx["branding"] = brand
        ctx["site_settings"] = brand
        ctx["branding_v"] = int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1
        ctx["brand_logo_url"] = totp_user_logo_url(self.request)
        ctx.update(resolve_branding_context(self.request))
        ctx.update(login_page_context("user", self.request))
        ctx["pending_verify_email"] = self.request.session.get("pending_verify_email", "")
        ctx["email_verification_enabled"] = EmailVerificationSettings.get_solo().enabled
        return ctx


def _send_verification_email(user, request):
    """Send signup verification via active Email Template only.

    Missing/inactive ``email_verification`` → no send. CRM test email is unchanged
    (uses ``send_dynamic_email`` directly).
    """
    from django.conf import settings as dj_settings

    token = (getattr(user, "email_token", None) or "").strip()
    if not token:
        raise ValueError("email_token is required to send verification email")
    base = (getattr(dj_settings, "SITE_BASE_URL", "") or "").rstrip("/")
    if base:
        verify_url = f"{base}/verify-email/{token}/"
    else:
        verify_url = request.build_absolute_uri(f"/verify-email/{token}/")
    ok, reason = send_event_email(
        "email_verification",
        to_email=user.email,
        user=user,
        extra_context={"verify_url": verify_url, "name": user.display_name()},
    )
    if not ok:
        logger.info(
            "verification email skipped user_id=%s reason=%s",
            getattr(user, "pk", None),
            reason,
        )


@require_http_methods(["GET", "POST"])
def user_totp_verify_view(request):
    uid = request.session.get("pending_user_totp")
    if not uid:
        return redirect("user-login")
    user = User.objects.filter(pk=uid).first()
    if not user or not user.totp_enabled or not user.totp_secret:
        request.session.pop("pending_user_totp", None)
        return redirect("user-login")
    brand = UserAuthBrandingSettings.get_solo()
    if request.method == "POST":
        code = (request.POST.get("code") or "").replace(" ", "").strip()
        if pyotp.TOTP(user.totp_secret).verify(code, valid_window=1):
            request.session.pop("pending_user_totp", None)
            next_url = request.session.pop("pending_user_totp_next", None) or "/user/dashboard/"
            login(request, user)
            if user.force_password_change:
                return redirect("user-change-password")
            return redirect(next_url)
        messages.error(request, "Invalid authentication code.")
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "brand": brand,
            "branding": brand,
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
            "brand_logo_url": totp_user_logo_url(request),
        }
    )
    return render(request, "accounts/user_totp.html", ctx)


@require_http_methods(["GET", "POST"])
def admin_totp_verify_view(request):
    uid = request.session.get("pending_admin_totp")
    if not uid:
        return redirect("admin-login")
    user = User.objects.filter(pk=uid).first()
    if (
        not user
        or not user.can_use_staff_login_portal()
        or not user.totp_enabled
        or not user.totp_secret
    ):
        request.session.pop("pending_admin_totp", None)
        return redirect("admin-login")
    brand = AdminAuthBrandingSettings.get_solo()
    if request.method == "POST":
        code = (request.POST.get("code") or "").replace(" ", "").strip()
        if pyotp.TOTP(user.totp_secret).verify(code, valid_window=1):
            request.session.pop("pending_admin_totp", None)
            login(request, user)
            return redirect(user.staff_home_path())
        messages.error(request, "Invalid authentication code.")
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "brand": brand,
            "branding": brand,
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
            "brand_logo_url": totp_admin_logo_url(request),
        }
    )
    return render(request, "accounts/admin_totp.html", ctx)


def email_verification_sent_view(request):
    """Shown after signup when a verification email was sent."""
    brand = UserAuthBrandingSettings.get_solo()
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "brand": brand,
            "branding": brand,
            "brand_logo_url": totp_user_logo_url(request),
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
            "registration_email": (request.session.get("registration_pending_email") or "").strip(),
        }
    )
    return render(request, "accounts/email_verification_sent.html", ctx)


def client_signup_view(request):
    signup_settings = SignupSettings.get_solo()
    brand = UserAuthBrandingSettings.get_solo()
    ev = EmailVerificationSettings.get_solo()
    # Referral: /register?ref={ib_code} or legacy ?ib={user_id}
    if request.method == "GET" and hasattr(request, "session"):
        if "ref" in request.GET:
            ref_code = (request.GET.get("ref") or "").strip()
            request.session["signup_ib_ref"] = ref_code
            if ref_code:
                from django.db.models import F
                from ib.models import IBProfile
                IBProfile.objects.filter(ib_code=ref_code).update(link_clicks=F("link_clicks") + 1)
        if "ib" in request.GET:
            request.session["signup_ib_user_id"] = (request.GET.get("ib") or "").strip()
        if "ref" not in request.GET and "ib" not in request.GET:
            request.session.pop("signup_ib_ref", None)
            request.session.pop("signup_ib_user_id", None)
    signup_ref = ""
    signup_ib_legacy = ""
    if hasattr(request, "session"):
        signup_ref = (request.session.get("signup_ib_ref") or "").strip()
        signup_ib_legacy = (request.session.get("signup_ib_user_id") or "").strip()
    if request.method == "POST":
        pr = (request.POST.get("signup_ref", "") or "").strip()
        pl = (request.POST.get("signup_ib_legacy", "") or "").strip()
        if pr:
            signup_ref = pr
        if pl:
            signup_ib_legacy = pl
        form = ClientSignupForm(
            request.POST,
            signup_settings=signup_settings,
            require_verification_email=ev.enabled,
        )
        ok = form.is_valid()
        logger.info("client_signup POST form.is_valid()=%s", ok)
        if not ok:
            logger.warning("client_signup form.errors=%s", form.errors)
    else:
        form = ClientSignupForm(
            signup_settings=signup_settings,
            require_verification_email=ev.enabled,
        )

    if request.method == "POST" and form.is_valid():
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
                logger.info("client_signup user created id=%s email=%s", user.pk, user.email)

                from ib.referral import assign_ib_from_signup_referral

                assign_ib_from_signup_referral(request, user)

            # After commit: real BTrader DEMO for new clients (best-effort).
            try:
                from api.services.signup_demo import ensure_signup_demo_for_new_client

                ensure_signup_demo_for_new_client(user, force=True)
            except Exception:
                logger.exception("client_signup demo account auto-create failed user_id=%s", user.pk)

            logger.info(
                "client_signup user committed id=%s email=%s is_active=%s email_verified=%s",
                user.pk,
                user.email,
                user.is_active,
                user.email_verified,
            )

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
                logger.exception("client_signup staff notification failed user_id=%s", user.pk)

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
                logger.info(
                    "client_signup verification pending user_id=%s is_active=%s token_set=%s",
                    user.pk,
                    user.is_active,
                    bool(user.email_token),
                )
                try:
                    send_event_email("account_created", to_email=user.email, user=user)
                except Exception:
                    logger.exception("client_signup account_created email failed user_id=%s", user.pk)
                try:
                    _send_verification_email(user, request)
                except Exception:
                    logger.exception("client_signup verification email failed user_id=%s", user.pk)
                request.session["registration_pending_email"] = user.email
                request.session["pending_verify_email"] = user.email
                messages.success(
                    request,
                    "Verification email sent. Please check your email.",
                )
                return redirect(reverse("email-verification-sent"))

            user.email_verified = True
            user.email_verified_at = timezone.now()
            user.save(update_fields=["email_verified", "email_verified_at"])
            logger.info(
                "client_signup auto-verify path user_id=%s (email verification disabled in settings)",
                user.pk,
            )
            try:
                send_event_email("account_created", to_email=user.email, user=user)
            except Exception:
                logger.exception("client_signup account_created email failed user_id=%s", user.pk)
            login(request, user)
            messages.success(request, "Account created successfully.")
            return redirect("/user/dashboard/")
        except IntegrityError as exc:
            logger.warning("client_signup IntegrityError: %s", exc)
            form.add_error("email", "Unable to create this account. That email may already be registered.")
        except Exception as exc:
            logger.exception("client_signup failed: %s", exc)
            messages.error(
                request,
                "Registration could not be completed. Please try again or contact support.",
            )
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "form": form,
            "signup_settings": signup_settings,
            "brand": brand,
            "branding": brand,
            "brand_logo_url": totp_user_logo_url(request),
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
            "signup_ref": signup_ref,
            "signup_ib_legacy": signup_ib_legacy,
        }
    )
    return render(
        request,
        "accounts/signup.html",
        ctx,
    )


def forgot_password_view(request):
    brand = UserAuthBrandingSettings.get_solo()
    if request.method == "POST":
        form = ForgotPasswordForm(request.POST)
        if form.is_valid():
            email = form.cleaned_data["email"].strip().lower()
            user = User.objects.filter(email__iexact=email).first()
            if user:
                reset_link = password_reset_url(user, portal=False)
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
                        "forgot_password email skipped user_id=%s reason=%s",
                        user.pk,
                        reason,
                    )
            messages.success(request, "If this email exists, password reset instructions have been sent.")
            return redirect("/login")
    else:
        form = ForgotPasswordForm()
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "form": form,
            "brand": brand,
            "branding": brand,
            "brand_logo_url": totp_user_logo_url(request),
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
        }
    )
    return render(
        request,
        "accounts/forgot_password.html",
        ctx,
    )


@require_http_methods(["GET", "POST"])
def reset_password_view(request, uidb64, token):
    brand = UserAuthBrandingSettings.get_solo()
    user = user_from_uid_token(uidb64, token)
    form = SetNewPasswordForm(request.POST or None)
    if request.method == "POST" and user and form.is_valid():
        user.set_password(form.cleaned_data["new_password"])
        fields = ["password"]
        if hasattr(user, "force_password_change"):
            user.force_password_change = False
            fields.append("force_password_change")
        user.save(update_fields=fields)
        try:
            from rest_framework.authtoken.models import Token

            Token.objects.filter(user=user).delete()
        except Exception:
            pass
        messages.success(request, "Password updated. You can sign in now.")
        return redirect("/login/")
    ctx = resolve_branding_context(request)
    ctx.update(
        {
            "form": form,
            "valid_link": bool(user),
            "brand": brand,
            "branding": brand,
            "brand_logo_url": totp_user_logo_url(request),
            "branding_v": int(brand.updated_at.timestamp()) if getattr(brand, "updated_at", None) else 1,
        }
    )
    return render(request, "accounts/reset_password.html", ctx)


def verify_email_view(request, token):
    ev = EmailVerificationSettings.get_solo()
    user = User.objects.filter(email_token=token).first()
    if not user:
        messages.error(request, "Invalid verification token.")
        return redirect("/login/")
    if user.email_verified:
        messages.info(request, "Email already verified.")
        return redirect("/login/")
    created_at = user.email_token_created_at or timezone.now()
    expiry_hours = ev.token_expiry_hours if ev.token_expiry_hours and ev.token_expiry_hours > 0 else 24
    if timezone.now() > created_at + timedelta(hours=expiry_hours):
        messages.error(request, "Verification token expired. Please request a new one.")
        return redirect("/login/")
    user.email_verified = True
    user.email_verified_at = timezone.now()
    user.is_active = True
    user.email_token = ""
    user.save(update_fields=["email_verified", "email_verified_at", "is_active", "email_token"])
    send_event_email("email_verified", to_email=user.email, user=user)
    messages.success(request, "Email verified successfully. Please login.")
    return redirect("/login/")


def resend_verification_view(request):
    ev = EmailVerificationSettings.get_solo()
    if not (ev.enabled and ev.allow_resend):
        messages.error(request, "Resend verification is disabled.")
        return redirect("/login/")
    email = (request.POST.get("email") or request.session.get("pending_verify_email") or "").strip().lower()
    user = User.objects.filter(email__iexact=email).first()
    if not user:
        messages.error(request, "Email not found.")
        return redirect("/login/")
    if user.email_verified:
        messages.info(request, "Email is already verified.")
        return redirect("/login/")
    user.email_token = uuid.uuid4().hex
    user.email_token_created_at = timezone.now()
    user.save(update_fields=["email_token", "email_token_created_at"])
    _send_verification_email(user, request)
    request.session["pending_verify_email"] = user.email
    messages.success(request, "Verification email resent.")
    return redirect("/login/")


def client_logout(request):
    logout(request)
    request.session.flush()
    return redirect("/login/")


def admin_logout(request):
    logout(request)
    request.session.flush()
    return redirect("/admin/login/")


@require_http_methods(["GET", "POST"])
def logout_view(request):
    logout(request)
    request.session.flush()
    return redirect("/login/")
