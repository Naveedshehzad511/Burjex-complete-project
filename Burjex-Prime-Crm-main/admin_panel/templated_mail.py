"""Send transactional emails using admin-editable templates and global toggles."""

from __future__ import annotations

import html
import re
from types import SimpleNamespace
from typing import Any

from django.conf import settings
from django.template.loader import render_to_string
from django.utils import timezone

from .email_service import send_dynamic_email
from .models import (
    EmailGlobalLayout,
    EmailPurpose,
    EmailSettings,
    EmailSystemSettings,
    EmailTemplate,
    EmailTemplateMapping,
    EmailTemplateSettings,
    OrganizationProfileSettings,
    EmailLog,
)


EVENT_LABELS: list[tuple[str, str]] = [
    ("account_created", "Account Created"),
    ("email_verification", "Email Verification"),
    ("email_verified", "Email Verified"),
    ("forgot_password", "Forgot Password"),
    ("password_reset", "Password Reset"),
    ("deposit_submitted", "Deposit Submitted"),
    ("deposit_approved", "Deposit Approved"),
    ("deposit_rejected", "Deposit Rejected"),
    ("withdrawal_submitted", "Withdrawal Submitted"),
    ("withdrawal_approved", "Withdrawal Approved"),
    ("withdrawal_rejected", "Withdrawal Rejected"),
    ("kyc_submitted", "KYC Submitted"),
    ("kyc_approved", "KYC Approved"),
    ("kyc_rejected", "KYC Rejected"),
    ("identity_submitted", "Identity Documents Submitted"),
    ("identity_approved", "Identity Verification Approved"),
    ("identity_rejected", "Identity Verification Rejected"),
    ("address_submitted", "Address Documents Submitted"),
    ("address_approved", "Address Verification Approved"),
    ("address_rejected", "Address Verification Rejected"),
    ("account_verified", "Account Fully Verified"),
    ("real_account_created", "Real Account Created"),
    ("demo_account_created", "Demo Account Created"),
    ("login_alert", "Login Alert"),
    ("otp_verification", "OTP Verification"),
]


def _infer_template_type(event_key: str) -> str:
    key = (event_key or "").strip()
    mp = {
        "forgot_password": EmailTemplate.TemplateType.FORGOT_PASSWORD,
        "password_reset": EmailTemplate.TemplateType.FORGOT_PASSWORD,
        "signup_welcome": EmailTemplate.TemplateType.SIGNUP_WELCOME,
        "email_verification": EmailTemplate.TemplateType.EMAIL_VERIFICATION,
        "email_verified": EmailTemplate.TemplateType.EMAIL_VERIFICATION,
        "otp_verification": EmailTemplate.TemplateType.OTP_VERIFICATION,
        "kyc_approved": EmailTemplate.TemplateType.KYC_APPROVED,
        "kyc_rejected": EmailTemplate.TemplateType.KYC_REJECTED,
        "deposit_submitted": EmailTemplate.TemplateType.DEPOSIT_CONFIRMATION,
        "deposit_approved": EmailTemplate.TemplateType.DEPOSIT_CONFIRMATION,
        "withdrawal_submitted": EmailTemplate.TemplateType.WITHDRAWAL_CONFIRMATION,
        "withdrawal_approved": EmailTemplate.TemplateType.WITHDRAWAL_CONFIRMATION,
        "account_created": EmailTemplate.TemplateType.ACCOUNT_CREATED,
    }
    return mp.get(key, EmailTemplate.TemplateType.CUSTOM)


def sync_event_template_map(tpl: EmailTemplate) -> None:
    """Point event routing at this template (built-in keys only)."""
    if not tpl.event_key or tpl.event_key.startswith("custom_"):
        return
    es = EmailSettings.get_solo()
    m = dict(es.event_template_map or {})
    m[tpl.event_key] = tpl.id
    es.event_template_map = m
    es.save(update_fields=["event_template_map", "updated_at"])


def _site_base_url() -> str:
    layout = EmailGlobalLayout.get_solo()
    return (layout.site_base_url or getattr(settings, "SITE_BASE_URL", "") or "").rstrip("/")


def _sanitize_hex_color(val: str, default: str = "#0B3C5D") -> str:
    v = (val or "").strip()
    if re.fullmatch(r"#[0-9A-Fa-f]{6}", v) or re.fullmatch(r"#[0-9A-Fa-f]{3}", v):
        return v
    return default


def _logo_max_dimensions(logo_size: str) -> tuple[str, str]:
    if logo_size == EmailTemplateSettings.LogoSize.SMALL:
        return "40px", "160px"
    if logo_size == EmailTemplateSettings.LogoSize.LARGE:
        return "72px", "320px"
    return "56px", "240px"


def resolve_email_branding() -> dict[str, str]:
    """
    Company identity for all transactional emails.
    Primary source: System Settings → Organization / Company profile (OrganizationProfileSettings).
    Email Global Layout overrides support URL, footer address, and logo when set.
    """
    org = OrganizationProfileSettings.get_solo()
    layout = EmailGlobalLayout.get_solo()
    tpls = EmailTemplateSettings.get_solo()
    base = _site_base_url()

    name = (tpls.company_name_override or "").strip() or (org.company_name or "").strip()
    if not name:
        name = str(
            getattr(settings, "CRM_COMPANY_NAME", None) or getattr(settings, "COMPANY_NAME", None) or ""
        ).strip()
    if not name:
        name = "Burjex Prime"

    logo_html = ""
    logo_url = ""
    img = None
    if tpls.email_logo:
        img = tpls.email_logo
    elif layout.company_logo:
        img = layout.company_logo
    elif org.logo:
        img = org.logo
    if img:
        path = img.url
        url = path if str(path).startswith("http") else (f"{base}{path}" if base else path)
        logo_url = str(url)
        esc_alt = html.escape(name)
        mh, mw = _logo_max_dimensions(tpls.logo_size)
        logo_html = (
            f'<img src="{html.escape(str(url), quote=True)}" alt="{esc_alt}" '
            f'style="max-height:{mh};max-width:{mw};display:inline-block;vertical-align:middle;" />'
        )

    sup = (layout.support_email or "").strip() or (org.support_email or "").strip()
    web = (layout.website_url or "").strip() or (org.website_url or "").strip()
    if not web:
        web = base
    addr = (layout.company_address or "").strip() or (org.registered_address or "").strip()

    return {
        "company_name": name,
        "company_logo_html": logo_html,
        "email_logo_url": logo_url,
        "support_email": sup,
        "website_url": web or "#",
        "company_address": addr,
        "header_color": _sanitize_hex_color(tpls.header_color),
        "text_color": _sanitize_hex_color(tpls.text_color, "#FFFFFF"),
        "button_color": _sanitize_hex_color(tpls.button_color, "#0B3C5D"),
        "logo_position": tpls.logo_position,
        "show_company_name_with_logo": tpls.show_company_name,
    }


def _company_name() -> str:
    return resolve_email_branding()["company_name"]


def enrich_email_variables(ctx: dict[str, Any]) -> dict[str, Any]:
    """Add aliases: client_name, reset_link, company_logo HTML, {{company_name}}, etc."""
    branding = resolve_email_branding()
    ctx = dict(ctx)
    name = ctx.get("name") or ""
    em = ctx.get("email") or ""
    ctx.setdefault("client_name", name)
    ctx.setdefault("client_email", em)
    ctx.setdefault("reject_reason", ctx.get("reject_reason") or ctx.get("reason") or "")
    ctx.setdefault("login_id", ctx.get("login_id") or em)
    ctx.setdefault("password", ctx.get("password") or "••••••••")
    ctx.setdefault("reset_link", ctx.get("reset_link") or ctx.get("verify_url") or "#")
    ctx.setdefault("verification_link", ctx.get("verification_link") or ctx.get("verify_url") or "#")
    ctx.setdefault(
        "current_date",
        ctx.get("current_date") or ctx.get("date") or timezone.now().strftime("%Y-%m-%d %H:%M"),
    )

    if not (ctx.get("company_name") or "").strip():
        ctx["company_name"] = branding["company_name"]
    else:
        ctx["company_name"] = str(ctx["company_name"]).strip()

    if not (ctx.get("company_logo") or "").strip():
        ctx["company_logo"] = branding["company_logo_html"]
    if not (ctx.get("email_logo_url") or "").strip():
        ctx["email_logo_url"] = branding["email_logo_url"]
    if not (ctx.get("text_color") or "").strip():
        ctx["text_color"] = branding["text_color"]
    if not (ctx.get("support_email") or "").strip():
        ctx["support_email"] = branding["support_email"]
    if not (ctx.get("website_url") or "").strip():
        ctx["website_url"] = branding["website_url"]
    if not (ctx.get("company_address") or "").strip():
        ctx["company_address"] = branding["company_address"]
    return ctx


def wrap_email_html(inner_html: str, layout: EmailGlobalLayout, ctx: dict[str, Any]) -> str:
    """Responsive table-based wrapper; inner_html is already rendered."""
    if not layout.wrap_enabled:
        return inner_html
    ctx = dict(ctx)
    ctx.setdefault("email_body", inner_html)
    tpls = EmailTemplateSettings.get_solo()
    branding = resolve_email_branding()
    header_color = _sanitize_hex_color(tpls.header_color)
    text_color = _sanitize_hex_color(
        (ctx.get("text_color") or "").strip() or branding["text_color"],
        "#FFFFFF",
    )
    button_color = _sanitize_hex_color(
        (ctx.get("button_color") or "").strip() or branding["button_color"],
        "#0B3C5D",
    )
    align = tpls.logo_position if tpls.logo_position in ("left", "center", "right") else "center"
    show_name_with_logo = tpls.show_company_name

    logo_url = (ctx.get("email_logo_url") or "").strip() or branding["email_logo_url"]
    company_name = (ctx.get("company_name") or "").strip() or _company_name()
    name_safe = html.escape(company_name)

    header_raw = layout.header_html or ""
    header_extra = render_template_text(header_raw, ctx)
    expected_name = company_name
    header_has_name_var = bool(re.search(r"\{\{\s*company_name\s*\}\}", header_raw))
    header_covers_name = (
        header_has_name_var
        and bool(expected_name)
        and expected_name in (header_extra or "")
    )
    show_company_name_in_header = True
    if header_covers_name:
        show_company_name_in_header = False
    elif logo_url and not show_name_with_logo:
        show_company_name_in_header = False

    header_inner = ""
    if logo_url or show_company_name_in_header:
        settings_ns = SimpleNamespace(
            header_color=header_color,
            text_color=text_color,
            logo_align=align,
            logo=SimpleNamespace(url=logo_url) if logo_url else None,
        )
        header_inner = render_to_string(
            "admin/email_templates/global_layout.html",
            {
                "company_name": company_name,
                "settings": settings_ns,
                "show_company_name_in_header": show_company_name_in_header,
            },
        ).strip()

    extra_pad = "padding:0 20px 12px 20px;margin-top:4px;" if header_inner else "padding:15px 20px 12px 20px;"
    footer_extra = render_template_text(layout.footer_html or "", ctx)
    disc = render_template_text(layout.risk_disclaimer or "", ctx)
    addr = render_template_text(ctx.get("company_address") or "", ctx)
    sup = (ctx.get("support_email") or "").strip()
    web = (ctx.get("website_url") or "").strip()
    sup_safe = html.escape(sup) if sup else ""
    web_href = html.escape(web, quote=True) if web and web != "#" else "#"
    web_label = html.escape(web) if web and web != "#" else ""
    support_line = ""
    if sup_safe:
        support_line = f'<p style="margin:10px 0 6px;"><strong style="color:#475569;">Support</strong><br/><a href="mailto:{sup_safe}" style="color:#0B3C5D;text-decoration:none;font-weight:500;">{sup_safe}</a></p>'
    website_line = ""
    if web and web.strip() and web != "#":
        website_line = f'<p style="margin:6px 0 0;"><strong style="color:#475569;">Website</strong><br/><a href="{web_href}" style="color:#0B3C5D;text-decoration:none;font-weight:500;">{web_label or web_href}</a></p>'
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="color-scheme" content="light only" />
<title>{name_safe}</title>
<style>
  .email-btn, a.email-btn, a[data-email-btn="primary"] {{
    background:{button_color} !important;color:#fff !important;border:1px solid {button_color} !important;
    border-radius:8px !important;padding:10px 16px !important;text-decoration:none !important;display:inline-block !important;
    font-weight:600 !important;
  }}
</style>
</head>
<body style="margin:0;padding:0;background:#eef2f6;-webkit-text-size-adjust:100%;font-family:'Segoe UI',system-ui,-apple-system,Roboto,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#eef2f6;padding:32px 16px;">
<tr><td align="center">
<table role="presentation" width="600" cellspacing="0" cellpadding="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 8px 30px rgba(15,23,42,.06);border:1px solid #e2e8f0;">
<tr><td style="padding:0;background:{header_color};border-bottom:1px solid rgba(0,0,0,.12);">
{header_inner}
<div style="color:rgba(255,255,255,.92);font-size:14px;line-height:1.5;text-align:{align};{extra_pad}">{header_extra}</div>
</td></tr>
<tr><td style="padding:32px 32px 36px;color:#1e293b;font-size:16px;line-height:1.65;">
{inner_html}
</td></tr>
<tr><td style="padding:24px 32px 28px;background:#f8fafc;border-top:1px solid #e2e8f0;font-size:13px;line-height:1.55;color:#64748b;">
<p style="margin:0 0 14px;color:#475569;">{disc}</p>
<p style="margin:0 0 10px;white-space:pre-line;">{addr}</p>
{support_line}
{website_line}
<div style="margin-top:18px;padding-top:16px;border-top:1px solid #e2e8f0;color:#94a3b8;font-size:12px;">{footer_extra}</div>
</td></tr>
</table>
<p style="margin:20px 0 0;font-size:11px;color:#94a3b8;text-align:center;max-width:600px;">This is an automated message. Please do not reply if this inbox is not monitored.</p>
</td></tr></table>
</body></html>"""


def render_template_text(template_str: str, context: dict[str, Any]) -> str:
    def _resolve(path: str) -> Any:
        current: Any = context
        for part in path.split("."):
            if isinstance(current, dict):
                current = current.get(part)
            else:
                current = getattr(current, part, None)
            if current is None:
                return None
        return current

    def repl(match: re.Match) -> str:
        key = (match.group(1) or "").strip()
        val = _resolve(key)
        return "" if val is None else str(val)

    return re.sub(r"\{\{\s*([a-zA-Z0-9_\.]+)\s*\}\}", repl, template_str or "")


def render_transactional_email(tpl: EmailTemplate, ctx: dict[str, Any]) -> tuple[str, str]:
    ctx = enrich_email_variables(dict(ctx))
    subject = render_template_text(tpl.subject, ctx)
    inner = render_template_text(tpl.body, ctx)
    body = wrap_email_html(inner, EmailGlobalLayout.get_solo(), ctx)
    return subject, body


def _resolve_event_template(event_key: str) -> EmailTemplate | None:
    """Resolve admin Email Template for an app/API event key.

    Preference order:
    1) EmailSettings.event_template_map JSON id (admin routing)
    2) EmailPurpose → EmailTemplateMapping
    3) Active EmailTemplate with matching event_key
    4) Any EmailTemplate with matching event_key
    """
    settings_obj = EmailSettings.get_solo()
    mapped_id = int((settings_obj.event_template_map or {}).get(event_key) or 0)
    if mapped_id:
        mapped_tpl = EmailTemplate.objects.filter(id=mapped_id).first()
        if mapped_tpl:
            return mapped_tpl

    purpose = EmailPurpose.objects.filter(purpose_key=event_key).first()
    if purpose:
        mapped = (
            EmailTemplateMapping.objects.filter(purpose=purpose)
            .select_related("template")
            .first()
        )
        if mapped and mapped.template:
            return mapped.template

    active = EmailTemplate.objects.filter(
        event_key=event_key, status=EmailTemplate.Status.ACTIVE
    ).first()
    if active:
        return active
    return EmailTemplate.objects.filter(event_key=event_key).first()


def send_event_email(
    event_key: str,
    *,
    to_email: str,
    user=None,
    extra_context: dict[str, Any] | None = None,
) -> tuple[bool, str]:
    """
    Send using CRM admin Email Templates (same SMTP as test email).

    Active templates always send for app/API events. ``master_enabled`` must not
    silently no-op with ``ok=True`` — that made CRM test email work while signup,
    password reset, KYC, deposits, etc. never left the server.
    """
    tpl = _resolve_event_template(event_key)
    if not tpl:
        # False so callers with send_dynamic_email fallback actually send.
        return False, "skipped_template_disabled"

    # Keep routing JSON in sync when we resolve by event_key / purpose.
    try:
        sync_event_template_map(tpl)
    except Exception:
        pass

    if tpl.status != EmailTemplate.Status.ACTIVE:
        EmailLog.objects.create(
            user=user if getattr(user, "pk", None) else None,
            email=to_email,
            subject=tpl.subject or f"Skipped ({event_key})",
            body="",
            event_key=event_key,
            status=EmailLog.Status.FAILED,
            error_message="Email skipped - template inactive",
        )
        return False, "skipped_template_inactive"

    sys_s = EmailSystemSettings.get_solo()
    if not sys_s.master_enabled:
        # Template is ACTIVE — deliver anyway. Master off previously returned
        # (True, "skipped_master_disabled") and callers treated that as success.
        pass

    extra = dict(extra_context or {})
    ctx: dict[str, Any] = {
        "name": extra.pop("name", user.display_name() if user else ""),
        "email": extra.pop("email", to_email),
        "amount": extra.pop("amount", ""),
        "reason": extra.pop("reason", ""),
        "company_name": extra.pop("company_name", _company_name()),
        "date": extra.pop("date", timezone.now().strftime("%Y-%m-%d %H:%M")),
        "account_number": extra.pop("account_number", ""),
        "verify_url": extra.pop("verify_url", ""),
        "upload_url": extra.pop("upload_url", ""),
        "user": {
            "name": user.display_name() if user else (extra.get("name") or ""),
            "email": to_email,
        },
        "account": {
            "number": extra.get("account_number", ""),
        },
    }
    ctx.update(extra)
    subject, body = render_transactional_email(tpl, ctx)
    link = (ctx.get("reset_link") or ctx.get("verify_url") or "").strip()
    if (
        event_key in {"forgot_password", "password_reset"}
        and link
        and link != "#"
        and link not in body
    ):
        safe = html.escape(link, quote=True)
        visible = html.escape(link)
        inject = (
            f'<p style="margin:24px 0 12px;text-align:center;">'
            f'<a href="{safe}" class="email-btn" data-email-btn="primary">Reset Password</a></p>'
            f'<p style="font-size:13px;color:#64748b;word-break:break-all;">'
            f"If the button does not work, open this link:<br/>{visible}</p>"
        )
        idx = body.lower().rfind("</body>")
        body = body[:idx] + inject + body[idx:] if idx != -1 else body + inject
    return send_dynamic_email(to_email, subject, body, user=user, event_key=event_key, html=True)


def ensure_default_email_templates() -> None:
    """Idempotent seed for new environments."""
    defaults: list[tuple[str, str, str, str, str, str]] = [
        (
            EmailTemplate.EventKey.KYC_APPROVED,
            "KYC Approved",
            "kyc-approved",
            "KYC Approved",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour KYC has been approved successfully.\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.KYC_REJECTED,
            "KYC Rejected",
            "kyc-rejected",
            "KYC Rejected",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour KYC was rejected.\n\nReason:\n{{reason}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.WITHDRAWAL_APPROVED,
            "Withdrawal Approved",
            "withdrawal-completed",
            "Withdrawal Approved",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour withdrawal has been approved.\nAmount: {{amount}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.WITHDRAWAL_REJECTED,
            "Withdrawal Rejected",
            "withdrawal-rejected",
            "Withdrawal Rejected",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour withdrawal was rejected.\n\nReason:\n{{reason}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.DEPOSIT_APPROVED,
            "Deposit Approved",
            "deposit-completed",
            "Deposit Approved",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour deposit has been approved.\nAmount: {{amount}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.DEPOSIT_REJECTED,
            "Deposit Rejected",
            "deposit-rejected",
            "Deposit Rejected",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nYour deposit was rejected.\n\nReason:\n{{reason}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.IB_REQUEST_APPROVED,
            "IB Request Approved",
            "ib-request-approved",
            "IB Request Approved",
            EmailTemplate.Category.PARTNER,
            "Dear {{name}},\n\nYour IB request has been approved.\nReferral link: {{reason}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.IB_REQUEST_REJECTED,
            "IB Request Rejected",
            "ib-request-rejected",
            "IB Request Rejected",
            EmailTemplate.Category.PARTNER,
            "Dear {{name}},\n\nYour IB request was rejected.\n\nReason:\n{{reason}}\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.SIGNUP_WELCOME,
            "Signup Welcome",
            "account-created",
            "Welcome",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nWelcome to {{company_name}}.\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.PASSWORD_RESET,
            "Password Reset",
            "password-reset",
            "Password reset",
            EmailTemplate.Category.USER,
            "Dear {{name}},\n\nUse the link or code provided to reset your password.\n\nRegards,\n{{company_name}}",
        ),
        (
            EmailTemplate.EventKey.ACCOUNT_APPROVED,
            "Account Approved",
            "account-approved",
            "Account approved",
            EmailTemplate.Category.ADMIN,
            "Dear {{name}},\n\nYour trading account request has been approved.\nAccount: {{account_number}}\n\nRegards,\n{{company_name}}",
        ),
    ]
    for key, name, slug, subj, category, body in defaults:
        EmailTemplate.objects.get_or_create(
            event_key=key,
            defaults={
                "name": name,
                "slug": slug,
                "subject": subj,
                "category": category,
                "html_content": body,
                "is_active": True,
                "template_type": _infer_template_type(key),
            },
        )
    extra_defaults = [
        ("account_created", "Account Created", "account-created-core", "Account created", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour client account has been created.\n\nRegards,\n{{company_name}}"),
        ("email_verification", "Email Verification", "email-verification", "Verify your email", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nPlease verify your email using this link:\n{{verify_url}}\n\nRegards,\n{{company_name}}"),
        ("email_verified", "Email Verified", "email-verified", "Email verified", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour email has been verified successfully.\n\nRegards,\n{{company_name}}"),
        ("forgot_password", "Forgot Password", "forgot-password", "Password reset request", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nWe received a password reset request for your account.\n\n<p><a href=\"{{reset_link}}\" class=\"email-btn\" data-email-btn=\"primary\">Reset Password</a></p>\n<p>If the button does not work, open this link:<br/>{{reset_link}}</p>\n\nRegards,\n{{company_name}}"),
        ("deposit_submitted", "Deposit Submitted", "deposit-submitted", "Deposit request submitted", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour deposit request was submitted.\nAmount: {{amount}}\n\nRegards,\n{{company_name}}"),
        ("withdrawal_submitted", "Withdrawal Submitted", "withdrawal-submitted", "Withdrawal request submitted", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour withdrawal request was submitted.\nAmount: {{amount}}\n\nRegards,\n{{company_name}}"),
        ("kyc_submitted", "KYC Submitted", "kyc-submitted", "KYC submitted", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour KYC documents were submitted and are under review.\n\nRegards,\n{{company_name}}"),
        ("identity_submitted", "Identity Documents Submitted", "identity-submitted", "Identity Documents Submitted", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nWe received your identity documents and they are under review.\n\nUpload / status page:\n{{verify_url}}\n\nRegards,\n{{company_name}}"),
        ("identity_approved", "Identity Verification Approved", "identity-approved", "Identity Verification Approved", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour identity verification has been approved.\n\nRegards,\n{{company_name}}"),
        ("identity_rejected", "Identity Verification Rejected", "identity-rejected", "Identity Verification Rejected", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour identity verification was rejected.\n\nReason:\n{{reason}}\n\nYou can upload again here:\n{{upload_url}}\n\nRegards,\n{{company_name}}"),
        ("address_submitted", "Address Documents Submitted", "address-submitted", "Address Documents Submitted", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nWe received your address documents and they are under review.\n\nUpload / status page:\n{{verify_url}}\n\nRegards,\n{{company_name}}"),
        ("address_approved", "Address Verification Approved", "address-approved", "Address Verification Approved", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour address verification has been approved.\n\nRegards,\n{{company_name}}"),
        ("address_rejected", "Address Verification Rejected", "address-rejected", "Address Verification Rejected", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour address verification was rejected.\n\nReason:\n{{reason}}\n\nYou can upload again here:\n{{upload_url}}\n\nRegards,\n{{company_name}}"),
        ("account_verified", "Account Fully Verified", "account-verified", "Account Fully Verified", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour account is fully verified (identity).\n\nClient area:\n{{verify_url}}\n\nRegards,\n{{company_name}}"),
        ("real_account_created", "Real Account Created", "real-account-created", "Real trading account created", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour real account has been created.\nAccount: {{account.number}}\n\nRegards,\n{{company_name}}"),
        ("demo_account_created", "Demo Account Created", "demo-account-created", "Demo account created", EmailTemplate.Category.USER, "Dear {{user.name}},\n\nYour demo account has been created.\nAccount: {{account.number}}\n\nRegards,\n{{company_name}}"),
        ("login_alert", "Login Alert", "login-alert", "Login alert", EmailTemplate.Category.ADMIN, "Hello {{user.name}},\n\nA new login was detected for {{user.email}} at {{date}}.\n\nRegards,\n{{company_name}}"),
        (
            "otp_verification",
            "OTP Verification",
            "otp-verification",
            "Your verification code",
            EmailTemplate.Category.USER,
            "<p>Dear {{user.name}},</p><p>Your verification code: <strong>{{password}}</strong></p><p>Regards,<br/>{{company_name}}</p>",
        ),
    ]
    for key, name, slug, subj, category, body in extra_defaults:
        EmailTemplate.objects.get_or_create(
            event_key=key,
            defaults={
                "name": name,
                "slug": slug,
                "subject": subj,
                "category": category,
                "html_content": body,
                "is_active": True,
                "template_type": _infer_template_type(key),
            },
        )
