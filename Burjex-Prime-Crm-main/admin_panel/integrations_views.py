"""System Management → Integrations hub and provider configuration."""

from __future__ import annotations

import logging
import smtplib
import ssl
import urllib.error
import urllib.parse
import urllib.request
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db import DatabaseError, transaction
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from transactions.models import PaymentGateway

logger = logging.getLogger(__name__)

from .models import (
    AIIntegration,
    ComplianceIntegration,
    EmailProvider,
    Google2FAIntegrationSettings,
    IntegrationConnectionLog,
    Match2PayIntegrationSettings,
    ReCaptchaIntegrationSettings,
    SMSProvider,
    SMTPSettings,
    SocialLoginSettings,
    SupportIntegration,
)


def _log_connection(slug: str, category: str, ok: bool, msg: str) -> None:
    IntegrationConnectionLog.objects.create(
        integration_slug=slug[:80],
        category=category[:40],
        success=ok,
        message=(msg or "")[:4000],
    )


def _http_probe(url: str, timeout: int = 10) -> tuple[bool, str]:
    raw = (url or "").strip()
    if not raw:
        return False, "No URL configured."
    if not raw.lower().startswith(("http://", "https://")):
        raw = "https://" + raw
    req = urllib.request.Request(raw, method="GET", headers={"User-Agent": "ForexCRM-IntegrationCheck/1.0"})
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return True, f"Reachable (HTTP {resp.status})."
    except urllib.error.HTTPError as e:
        if e.code in (401, 403, 405):
            return True, f"Host responded HTTP {e.code} (auth may be required — connection OK)."
        return False, f"HTTP {e.code}: {e.reason}"[:500]
    except Exception as e:
        return False, str(e)[:500]


def _smtp_ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def _smtp_probe(
    host: str,
    port: int,
    *,
    use_tls: bool,
    use_ssl: bool,
    username: str = "",
    password: str = "",
    timeout: int = 15,
) -> tuple[bool, str]:
    """Real SMTP reachability check (not HTTP)."""
    host = (host or "").strip()
    if not host:
        return False, "No SMTP host configured."
    if not (1 <= port <= 65535):
        return False, "Invalid SMTP port."
    ctx = _smtp_ssl_context()
    client: smtplib.SMTP | smtplib.SMTP_SSL | None = None
    try:
        if use_ssl:
            client = smtplib.SMTP_SSL(host, port, timeout=timeout, context=ctx)
        else:
            client = smtplib.SMTP(host, port, timeout=timeout)
        client.ehlo()
        if not use_ssl and use_tls:
            client.starttls(context=ctx)
            client.ehlo()
        if username and password:
            client.login(username, password)
        client.quit()
        return True, "SMTP OK: connected, TLS/auth steps succeeded as configured."
    except TimeoutError:
        return (
            False,
            f"Timed out after {timeout}s connecting to {host}:{port}. Check host, port, firewall, and encryption (TLS vs SSL).",
        )
    except OSError as e:
        return False, f"Network error: {e}"[:500]
    except smtplib.SMTPAuthenticationError as e:
        raw = e.smtp_error
        if isinstance(raw, bytes):
            raw = raw.decode(errors="replace")
        return False, f"Authentication failed: {e.smtp_code} {raw or ''}"[:500]
    except smtplib.SMTPException as e:
        return False, f"SMTP error: {e}"[:500]
    except Exception as e:
        return False, str(e)[:500]
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass


def _ensure_email_providers() -> None:
    for value, _ in EmailProvider.Provider.choices:
        EmailProvider.objects.get_or_create(provider=value)


def _ensure_sms_providers() -> None:
    for value, _ in SMSProvider.Provider.choices:
        SMSProvider.objects.get_or_create(provider=value)


def _ensure_support_labels() -> None:
    labels = {
        SupportIntegration.IntegrationType.TAWK_TO: "Tawk.to",
        SupportIntegration.IntegrationType.WHATSAPP_DIRECT: "WhatsApp Direct",
        SupportIntegration.IntegrationType.ZOHO_SALESIQ: "Zoho SalesIQ",
    }
    for value, label in labels.items():
        row, _ = SupportIntegration.objects.get_or_create(integration_type=value)
        if not row.integration_name:
            row.integration_name = label
            row.category = "CUSTOMER_SUPPORT"
            row.save(update_fields=["integration_name", "category", "updated_at"])


COMPLIANCE_SLUG_TO_PROVIDER = {
    "sumsub": ComplianceIntegration.Provider.SUMSUB,
    "onfido": ComplianceIntegration.Provider.ONFIDO,
    "shufti-pro": ComplianceIntegration.Provider.SHUFTI_PRO,
    "kyc-verification": ComplianceIntegration.Provider.KYC_VERIFICATION,
    "custom-api": ComplianceIntegration.Provider.CUSTOM_API,
    "idnow": ComplianceIntegration.Provider.IDNOW,
    "kyc-chain": ComplianceIntegration.Provider.KYC_CHAIN,
    "veriff": ComplianceIntegration.Provider.VERIFF,
}
COMPLIANCE_PROVIDER_TO_SLUG = {p.value: slug for slug, p in COMPLIANCE_SLUG_TO_PROVIDER.items()}


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def integrations_hub(request):
    return render(
        request,
        "admin_panel/integrations/hub.html",
        {
            "title": "Integrations",
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_ai(request):
    AIIntegration.ensure_defaults()
    rows = list(AIIntegration.objects.order_by("slug"))
    if request.method == "POST":
        sid = (request.POST.get("slug") or "").strip()
        row = AIIntegration.objects.filter(slug=sid).first()
        if not row:
            messages.error(request, "Unknown AI integration.")
            return redirect("admin-integrations-ai")
        row.enabled = request.POST.get("enabled") == "on"
        row.integration_name = (request.POST.get("integration_name") or row.get_slug_display() or "").strip()[:120]
        row.category = (request.POST.get("category") or "AI_ML").strip()[:40]
        row.status = "ACTIVE" if row.enabled else "INACTIVE"
        key = (request.POST.get("api_key") or "").strip()
        if key:
            row.api_key = key
        sec = (request.POST.get("api_secret") or "").strip()
        if sec:
            row.api_secret = sec
        row.base_url = (request.POST.get("base_url") or "").strip()[:500]
        row.model_name = (request.POST.get("model_name") or "").strip()[:120]
        row.save()
        messages.success(request, f"{row.integration_name or row.slug} saved.")
        return redirect("admin-integrations-ai")
    return render(request, "admin_panel/integrations/ai.html", {"rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_compliance(request):
    for value, _ in ComplianceIntegration.Provider.choices:
        ComplianceIntegration.objects.get_or_create(provider=value)
    rows = ComplianceIntegration.objects.order_by("provider")
    items = [
        {"row": r, "slug": COMPLIANCE_PROVIDER_TO_SLUG.get(r.provider, r.provider.lower().replace("_", "-"))}
        for r in rows
    ]
    return render(request, "admin_panel/integrations/compliance_list.html", {"items": items})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_compliance_edit(request, provider: str):
    key = (provider or "").strip().lower()
    prov = COMPLIANCE_SLUG_TO_PROVIDER.get(key)
    if not prov:
        messages.error(request, "Unknown compliance provider.")
        return redirect("admin-integrations-compliance")
    row = get_object_or_404(ComplianceIntegration, provider=prov)
    slug = COMPLIANCE_PROVIDER_TO_SLUG.get(row.provider, provider)
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "test":
            base = (request.POST.get("callback_url") or row.callback_url or "").strip() or "https://api.sumsub.com"
            ok, detail = _http_probe(base)
            row.last_test_ok = ok
            row.last_test_detail = detail[:500]
            row.last_test_at = timezone.now()
            row.save(update_fields=["last_test_ok", "last_test_detail", "last_test_at", "updated_at"])
            _log_connection(f"compliance_{slug}", "COMPLIANCE", ok, detail)
            messages.success(request, "Test finished: " + detail)
            return redirect("admin-integrations-compliance-edit", provider=slug)
        row.enabled = request.POST.get("enabled") == "on"
        row.integration_name = (request.POST.get("integration_name") or row.get_provider_display()).strip()[:120]
        row.api_key = (request.POST.get("api_key") or "").strip()
        sk = (request.POST.get("secret_key") or "").strip()
        if sk:
            row.secret_key = sk
        row.webhook_url = (request.POST.get("webhook_url") or "").strip()[:500]
        row.callback_url = (request.POST.get("callback_url") or "").strip()[:500]
        env = (request.POST.get("environment") or row.environment).strip().upper()
        if env in {c[0] for c in ComplianceIntegration.Environment.choices}:
            row.environment = env
        row.status_text = "ACTIVE" if row.enabled else "INACTIVE"
        row.save()
        messages.success(request, "Compliance integration saved.")
        return redirect("admin-integrations-compliance-edit", provider=slug)
    return render(
        request,
        "admin_panel/integrations/compliance_edit.html",
        {
            "row": row,
            "slug": slug,
            "env_choices": ComplianceIntegration.Environment.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def integrations_support(request):
    _ensure_support_labels()
    for value, _ in SupportIntegration.IntegrationType.choices:
        SupportIntegration.objects.get_or_create(integration_type=value)
    # Disabled/commented support modules:
    # - Custom API Support (CUSTOM_API)
    # - Email Support (EMAIL_SUPPORT)
    # - Live Chat (LIVE_CHAT)
    rows = SupportIntegration.objects.exclude(
        integration_type__in=["CUSTOM_API", "EMAIL_SUPPORT", "LIVE_CHAT"]
    ).order_by("integration_type")
    return render(
        request,
        "admin_panel/integrations/support.html",
        {"rows": rows, "full_page_url": reverse("admin-support-integrations")},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def integrations_email_sms(request):
    _ensure_email_providers()
    _ensure_sms_providers()
    email_keys = [
        ("smtp-universal", "SMTP Universal", EmailProvider.Provider.SMTP_UNIVERSAL),
        ("zeptomail", "ZeptoMail", EmailProvider.Provider.ZEPTOMAIL),
        ("amazon-ses", "Amazon SES", EmailProvider.Provider.AMAZON_SES),
        ("sendgrid", "SendGrid", EmailProvider.Provider.SENDGRID),
        ("reoon", "Reoon Email Verifier", EmailProvider.Provider.REOON),
        ("zoho-mail", "Zoho Mail", EmailProvider.Provider.ZOHO_MAIL),
    ]
    email_cards = []
    for slug, label, prov in email_keys:
        row = EmailProvider.objects.filter(provider=prov).first()
        email_cards.append({"slug": slug, "label": label, "row": row, "provider": prov})
    sms_keys = [
        ("twilio-verify", "Twilio Verify", SMSProvider.Provider.TWILIO_VERIFY),
        ("twilio-whatsapp", "Twilio WhatsApp", SMSProvider.Provider.TWILIO_WHATSAPP),
        ("custom-sms-api", "Custom SMS API", SMSProvider.Provider.CUSTOM_SMS_API),
    ]
    sms_cards = []
    for slug, label, prov in sms_keys:
        row = SMSProvider.objects.filter(provider=prov).first()
        sms_cards.append({"slug": slug, "label": label, "row": row, "provider": prov})
    return render(
        request,
        "admin_panel/integrations/email_sms_hub.html",
        {"email_cards": email_cards, "sms_cards": sms_cards},
    )


def _sync_smtp_singleton(row: EmailProvider) -> None:
    if row.provider != EmailProvider.Provider.SMTP_UNIVERSAL:
        return
    smtp = SMTPSettings.get_solo()
    smtp.smtp_host = row.smtp_host or smtp.smtp_host
    smtp.smtp_port = row.smtp_port or smtp.smtp_port
    smtp.smtp_username = row.username or smtp.smtp_username
    if row.password:
        smtp.smtp_password = row.password
    smtp.sender_email = row.sender_email or smtp.sender_email
    smtp.sender_name = row.sender_name or smtp.sender_name
    enc = (row.encryption or "TLS").upper()
    smtp.use_tls = enc == "TLS"
    smtp.use_ssl = enc == "SSL"
    smtp.save()


EMAIL_SLUG_TO_PROVIDER = {
    "smtp-universal": EmailProvider.Provider.SMTP_UNIVERSAL,
    "zeptomail": EmailProvider.Provider.ZEPTOMAIL,
    "amazon-ses": EmailProvider.Provider.AMAZON_SES,
    "sendgrid": EmailProvider.Provider.SENDGRID,
    "reoon": EmailProvider.Provider.REOON,
    "zoho-mail": EmailProvider.Provider.ZOHO_MAIL,
}

SMS_SLUG_TO_PROVIDER = {
    "twilio-verify": SMSProvider.Provider.TWILIO_VERIFY,
    "twilio-whatsapp": SMSProvider.Provider.TWILIO_WHATSAPP,
    "custom-sms-api": SMSProvider.Provider.CUSTOM_SMS_API,
}


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_email_provider(request, provider_key: str):
    _ensure_email_providers()
    prov = EMAIL_SLUG_TO_PROVIDER.get((provider_key or "").strip().lower())
    if not prov:
        messages.error(request, "Unknown email provider.")
        return redirect("admin-integrations-email-sms")
    row = get_object_or_404(EmailProvider, provider=prov)
    extra = dict(row.extra_config or {})

    def _finish_test(ok: bool, detail: str):
        row.last_test_ok = ok
        row.last_test_detail = detail[:500]
        row.last_test_at = timezone.now()
        row.save(update_fields=["last_test_ok", "last_test_detail", "last_test_at", "updated_at"])
        _log_connection(f"email_{provider_key}", "EMAIL_SMS", ok, detail)
        messages.success(request, detail)
        return redirect("admin-integrations-email-provider", provider_key=provider_key)

    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "test":
            if row.provider == EmailProvider.Provider.SMTP_UNIVERSAL:
                host = (request.POST.get("smtp_host") or row.smtp_host or "").strip()
                try:
                    port = int(request.POST.get("smtp_port") or row.smtp_port)
                except (TypeError, ValueError):
                    port = row.smtp_port
                enc = (request.POST.get("encryption") or row.encryption or "TLS").strip().upper()
                use_tls = enc == "TLS"
                use_ssl = enc == "SSL"
                user = (request.POST.get("username") or row.username or "").strip()
                pwd_post = (request.POST.get("password") or "").strip()
                pwd = pwd_post if pwd_post else (row.password or "")
                ok, detail = _smtp_probe(
                    host,
                    port,
                    use_tls=use_tls,
                    use_ssl=use_ssl,
                    username=user,
                    password=pwd,
                )
            elif row.provider == EmailProvider.Provider.ZEPTOMAIL:
                ok, detail = _http_probe("https://api.zeptomail.com")
            elif row.provider == EmailProvider.Provider.REOON:
                ok, detail = _http_probe("https://emailverifier.reoon.com")
            else:
                ok, detail = _http_probe(row.domain or "https://api.sendgrid.com")
            return _finish_test(ok, detail)

        if row.provider == EmailProvider.Provider.SMTP_UNIVERSAL:
            row.enabled = request.POST.get("enabled") == "on"
            row.enable_integration = row.enabled
            row.username = (request.POST.get("username") or "").strip()[:255]
            pwd = (request.POST.get("password") or "").strip()
            if pwd:
                row.password = pwd
            row.smtp_host = (request.POST.get("smtp_host") or "").strip()[:255]
            try:
                row.smtp_port = max(1, min(65535, int(request.POST.get("smtp_port") or row.smtp_port)))
            except (TypeError, ValueError):
                pass
            row.sender_name = (request.POST.get("sender_name") or "").strip()[:120]
            row.sender_email = (request.POST.get("sender_email") or "").strip()[:254]
            enc = (request.POST.get("encryption") or row.encryption or "TLS").strip().upper()
            if enc in {"TLS", "SSL", "NONE"}:
                row.encryption = enc
            row.save()
            _sync_smtp_singleton(row)
            messages.success(request, "Configuration saved.")
            return redirect("admin-integrations-email-provider", provider_key=provider_key)

        if row.provider == EmailProvider.Provider.ZEPTOMAIL:
            row.enabled = request.POST.get("enabled") == "on"
            row.enable_integration = row.enabled
            tok = (request.POST.get("api_token") or "").strip()
            if tok:
                row.api_key = tok[:2048]
            row.sender_name = (request.POST.get("sender_name") or "").strip()[:120]
            row.sender_email = (request.POST.get("sender_email") or "").strip()[:254]
            row.save()
            messages.success(request, "Configuration saved.")
            return redirect("admin-integrations-email-provider", provider_key=provider_key)

        if row.provider == EmailProvider.Provider.REOON:
            try:
                with transaction.atomic():
                    ep = EmailProvider.objects.get(pk=row.pk)
                    ep.enable_integration = request.POST.get("enable_integration") == "on"
                    ep.enabled = ep.enable_integration
                    new_key = (request.POST.get("api_key") or "").strip()
                    if new_key:
                        ep.api_key = new_key[:2048]
                    ep.save()
            except DatabaseError as exc:
                logger.exception("Reoon EmailProvider save failed: %s", exc)
                messages.error(request, "Could not save configuration. Please try again.")
                return redirect("admin-integrations-email-provider", provider_key=provider_key)
            except Exception as exc:
                logger.exception("Reoon integration save failed: %s", exc)
                messages.error(request, "Could not save configuration. Please try again.")
                return redirect("admin-integrations-email-provider", provider_key=provider_key)
            messages.success(request, "Configuration saved successfully.")
            return redirect("admin-integrations-email-provider", provider_key=provider_key)

        row.enabled = request.POST.get("enabled") == "on"
        row.enable_integration = row.enabled
        row.is_active = request.POST.get("is_active") == "on"
        row.integration_name = (request.POST.get("integration_name") or row.get_provider_display()).strip()[:120]
        row.username = (request.POST.get("username") or "").strip()[:255]
        pwd = (request.POST.get("password") or "").strip()
        if pwd:
            row.password = pwd
        row.smtp_host = (request.POST.get("smtp_host") or "").strip()[:255]
        try:
            row.smtp_port = max(1, min(65535, int(request.POST.get("smtp_port") or row.smtp_port)))
        except (TypeError, ValueError):
            pass
        row.sender_name = (request.POST.get("sender_name") or "").strip()[:120]
        row.sender_email = (request.POST.get("sender_email") or "").strip()[:254]
        enc = (request.POST.get("encryption") or row.encryption or "TLS").strip().upper()
        if enc in {"TLS", "SSL", "NONE"}:
            row.encryption = enc
        ak = (request.POST.get("api_key") or "").strip()
        if ak:
            row.api_key = ak
        sk = (request.POST.get("secret_key") or "").strip()
        if sk:
            row.secret_key = sk
        row.domain = (request.POST.get("domain") or "").strip()[:255]
        if row.provider == EmailProvider.Provider.ZOHO_MAIL:
            extra["client_id"] = (request.POST.get("client_id") or "").strip()
            cs = (request.POST.get("client_secret") or "").strip()
            if cs:
                extra["client_secret"] = cs
            extra["department_id"] = (request.POST.get("department_id") or "").strip()
            extra["operator_id"] = (request.POST.get("operator_id") or "").strip()
            wh = (request.POST.get("webhook_url") or "").strip()
            if wh:
                extra["webhook_url"] = wh
        row.extra_config = extra
        row.save()
        messages.success(request, "Configuration saved.")
        return redirect("admin-integrations-email-provider", provider_key=provider_key)

    webhook_auto = ""
    if row.provider == EmailProvider.Provider.ZOHO_MAIL:
        webhook_auto = request.build_absolute_uri(reverse("admin-email-sms"))
    ctx = {
        "row": row,
        "provider_key": provider_key,
        "extra": extra,
        "webhook_auto": webhook_auto,
    }
    tpl = "admin_panel/integrations/email_generic.html"
    if row.provider == EmailProvider.Provider.SMTP_UNIVERSAL:
        tpl = "admin_panel/integrations/email_smtp.html"
    elif row.provider == EmailProvider.Provider.ZEPTOMAIL:
        tpl = "admin_panel/integrations/email_zepto.html"
    elif row.provider == EmailProvider.Provider.REOON:
        tpl = "admin_panel/integrations/email_reoon.html"
    elif row.provider == EmailProvider.Provider.ZOHO_MAIL:
        tpl = "admin_panel/integrations/email_zoho.html"
    return render(request, tpl, ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_sms_provider(request, provider_key: str):
    _ensure_sms_providers()
    prov = SMS_SLUG_TO_PROVIDER.get((provider_key or "").strip().lower())
    if not prov:
        messages.error(request, "Unknown SMS provider.")
        return redirect("admin-integrations-email-sms")
    row = get_object_or_404(SMSProvider, provider=prov)

    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "test":
            if row.provider == SMSProvider.Provider.CUSTOM_SMS_API:
                raw = (row.api_url or "").strip()
                if not raw:
                    ok, detail = False, "No API URL on file. Set API URL under Email and SMS management if required."
                else:
                    ok, detail = _http_probe(raw)
            else:
                ok, detail = _http_probe("https://api.twilio.com")
            _log_connection(f"sms_{provider_key}", "EMAIL_SMS", ok, detail)
            messages.success(request, detail)
            return redirect("admin-integrations-sms-provider", provider_key=provider_key)

        row.enabled = request.POST.get("enabled") == "on"
        tok = (request.POST.get("api_token") or "").strip()
        if row.provider == SMSProvider.Provider.CUSTOM_SMS_API:
            if tok:
                row.api_key = tok
        else:
            if tok:
                row.auth_token = tok
        row.sender_id = (request.POST.get("sender_name") or "").strip()[:80]
        row.sender_email = (request.POST.get("sender_email") or "").strip()[:254]
        row.save()
        messages.success(request, "Configuration saved.")
        return redirect("admin-integrations-sms-provider", provider_key=provider_key)

    return render(
        request,
        "admin_panel/integrations/sms_simple.html",
        {"row": row, "provider_key": provider_key},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_recaptcha(request):
    obj = ReCaptchaIntegrationSettings.get_solo()
    if request.method == "POST":
        obj.site_key = (request.POST.get("site_key") or "").strip()[:255]
        sk = (request.POST.get("secret_key") or "").strip()
        if sk:
            obj.secret_key = sk
        obj.save()
        messages.success(request, "reCAPTCHA settings saved.")
        return redirect("admin-integrations-recaptcha")
    return render(request, "admin_panel/integrations/recaptcha.html", {"obj": obj})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_social_login(request):
    obj = SocialLoginSettings.get_solo()
    if request.method == "POST":
        obj.google_enabled = request.POST.get("google_enabled") == "on"
        obj.apple_enabled = request.POST.get("apple_enabled") == "on"
        obj.google_client_id = (request.POST.get("google_client_id") or "").strip()[:255]
        secret = (request.POST.get("google_client_secret") or "").strip()
        if secret:
            obj.google_client_secret = secret
        obj.apple_client_id = (request.POST.get("apple_client_id") or "").strip()[:255]
        obj.apple_team_id = (request.POST.get("apple_team_id") or "").strip()[:32]
        obj.apple_key_id = (request.POST.get("apple_key_id") or "").strip()[:32]
        apple_key = (request.POST.get("apple_private_key") or "").strip()
        if apple_key:
            obj.apple_private_key = apple_key
        obj.save()
        messages.success(request, "Social login settings saved.")
        return redirect("admin-integrations-social-login")
    from api.services.social_auth import callback_url as social_callback_url

    google_cb = social_callback_url(request, "google")
    apple_cb = social_callback_url(request, "apple")
    return render(
        request,
        "admin_panel/integrations/social_login.html",
        {"obj": obj, "google_callback_url": google_cb, "apple_callback_url": apple_cb},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_google_2fa(request):
    obj = Google2FAIntegrationSettings.get_solo()
    if request.method == "POST":
        obj.enabled = request.POST.get("enabled") == "on"
        obj.method_google_auth = request.POST.get("method_google_auth") == "on"
        obj.method_microsoft_auth = request.POST.get("method_microsoft_auth") == "on"
        obj.method_authy = request.POST.get("method_authy") == "on"
        obj.apply_client_login = request.POST.get("apply_client_login") == "on"
        obj.apply_admin_login = request.POST.get("apply_admin_login") == "on"
        obj.apply_withdrawal = request.POST.get("apply_withdrawal") == "on"
        obj.apply_password_change = request.POST.get("apply_password_change") == "on"
        obj.apply_wallet_access = request.POST.get("apply_wallet_access") == "on"
        obj.apply_profile_changes = request.POST.get("apply_profile_changes") == "on"
        obj.backup_codes_enabled = request.POST.get("backup_codes_enabled") == "on"
        obj.force_2fa_admin = request.POST.get("force_2fa_admin") == "on"
        obj.force_2fa_clients = request.POST.get("force_2fa_clients") == "on"
        try:
            obj.remember_device_days = max(0, int(request.POST.get("remember_device_days") or 30))
            obj.otp_expiry_seconds = max(15, int(request.POST.get("otp_expiry_seconds") or 30))
            obj.max_attempts = max(1, int(request.POST.get("max_attempts") or 5))
            obj.lockout_seconds = max(60, int(request.POST.get("lockout_seconds") or 900))
        except (TypeError, ValueError):
            pass
        obj.save()
        messages.success(request, "Google 2FA policy saved.")
        return redirect("admin-integrations-google-2fa")
    return render(request, "admin_panel/integrations/google_2fa.html", {"obj": obj})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def integrations_match2pay(request):
    obj = Match2PayIntegrationSettings.get_solo()
    public_webhook = request.build_absolute_uri(reverse("api-match2pay-webhook"))
    cfg = obj.currencies_config if isinstance(obj.currencies_config, dict) else {}
    if request.method == "POST":
        tok = (request.POST.get("api_token") or "").strip()
        if tok:
            obj.api_token = tok
        sec = (request.POST.get("api_secret") or "").strip()
        if sec:
            obj.api_secret = sec
        obj.merchant_id = (request.POST.get("merchant_id") or "").strip()[:120]
        api_url = (request.POST.get("api_url") or "").strip().rstrip("/")
        if api_url and "/api/" not in api_url.lower():
            api_url = f"{api_url}/api/v2/deposit/crypto_agent"
        obj.api_url = api_url[:500]
        obj.documentation_url = (request.POST.get("documentation_url") or "").strip()[:500]
        obj.enabled = request.POST.get("integration_enabled") == "on"
        obj.webhook_url = public_webhook
        cfg = dict(cfg)
        api_url_l = obj.api_url.lower().rstrip("/")
        cfg["deposit_request_type"] = "v2" if api_url_l.endswith("/api/v2/payment/deposit") else "crypto_agent"
        cfg["callback_url"] = public_webhook
        for field in ("success_url", "failure_url", "payment_gateway_name", "payment_method", "payment_currency"):
            value = (request.POST.get(field) or "").strip()
            if value:
                cfg[field] = value[:500]
            else:
                cfg.pop(field, None)
        obj.currencies_config = cfg
        if obj.enabled:
            if not obj.api_token or not obj.api_secret or not obj.api_url:
                obj.enabled = False
                messages.error(request, "Configuration saved but disabled because API token, API secret, and API URL are required.")
            else:
                messages.success(request, "Match2Pay configuration saved successfully.")
        else:
            messages.success(request, "Match2Pay configuration saved.")

        obj.save()
        PaymentGateway.objects.update_or_create(
            code="MATCH2PAY_AUTO",
            defaults={
                "name": "USDT",
                "scope": PaymentGateway.Scope.DEPOSIT,
                "gateway_type": PaymentGateway.GatewayType.THIRD_PARTY,
                "payment_method": PaymentGateway.PaymentMethod.WALLET,
                "visibility_status": (
                    PaymentGateway.VisibilityStatus.ACTIVE
                    if obj.enabled
                    else PaymentGateway.VisibilityStatus.INACTIVE
                ),
                "currency": "USDT",
                "min_amount": 0,
                "processing_time": "instant",
                "display_order": 0,
                "category": "Crypto",
            },
        )
        return redirect("admin-integrations-match2pay")
    return render(
        request,
        "admin_panel/integrations/match2pay.html",
        {"obj": obj, "cfg": cfg, "webhook_stub": public_webhook, "public_webhook_url": public_webhook},
    )


@csrf_exempt
@require_http_methods(["GET", "POST", "HEAD"])
def match2pay_webhook_stub(request):
    from admin_panel.services.match2pay_webhook import handle_match2pay_webhook_request

    return handle_match2pay_webhook_request(request)


AI_URL_SLUG_TO_DB = {
    "brokeret-ai": AIIntegration.Slug.BROKERET_AI,
    "builtin-ai": AIIntegration.Slug.BUILTIN_AI,
    "chatgpt": AIIntegration.Slug.CHATGPT,
    "gemini": AIIntegration.Slug.GEMINI,
    "grok": AIIntegration.Slug.GROK,
}


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def integrations_ai_test(request, slug: str):
    key = (slug or "").strip().lower()
    choice = AI_URL_SLUG_TO_DB.get(key)
    db_slug = choice.value if choice is not None else (slug or "").strip().upper()
    row = AIIntegration.objects.filter(slug=db_slug).first()
    if not row:
        return JsonResponse({"ok": False, "message": "Not found."}, status=404)
    url = (request.POST.get("base_url") or row.base_url or "").strip() or "https://api.openai.com"
    ok, detail = _http_probe(url)
    row.last_test_ok = ok
    row.last_test_detail = detail[:500]
    row.last_test_at = timezone.now()
    row.save(update_fields=["last_test_ok", "last_test_detail", "last_test_at", "updated_at"])
    _log_connection(f"ai_{slug}", "AI_ML", ok, detail)
    return JsonResponse({"ok": ok, "message": detail})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def integrations_logs(request):
    logs = IntegrationConnectionLog.objects.all()[:100]
    return render(request, "admin_panel/integrations/logs.html", {"logs": logs})
