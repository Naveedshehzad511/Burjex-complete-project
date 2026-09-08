"""System Management → Email Templates: CRUD, layout, preview, test send."""

from __future__ import annotations

import os

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.exceptions import ValidationError
from django.http import HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils.text import slugify
from django.views.decorators.clickjacking import xframe_options_sameorigin
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .email_service import send_dynamic_email
from .models import EmailGlobalLayout, EmailPurpose, EmailTemplate, EmailTemplateMapping, EmailTemplateSettings
from .templated_mail import (
    enrich_email_variables,
    ensure_default_email_templates,
    render_template_text,
    render_transactional_email,
    sync_event_template_map,
    wrap_email_html,
)

_MAX_EMAIL_LOGO_BYTES = 2 * 1024 * 1024
_ALLOWED_EMAIL_LOGO_EXT = {".png", ".jpg", ".jpeg", ".svg"}

TEMPLATE_TYPE_TO_EVENT_KEY: dict[str, str] = {
    EmailTemplate.TemplateType.FORGOT_PASSWORD: "forgot_password",
    EmailTemplate.TemplateType.SIGNUP_WELCOME: "signup_welcome",
    EmailTemplate.TemplateType.EMAIL_VERIFICATION: "email_verification",
    EmailTemplate.TemplateType.OTP_VERIFICATION: "otp_verification",
    EmailTemplate.TemplateType.KYC_APPROVED: "kyc_approved",
    EmailTemplate.TemplateType.KYC_REJECTED: "kyc_rejected",
    EmailTemplate.TemplateType.DEPOSIT_CONFIRMATION: "deposit_submitted",
    EmailTemplate.TemplateType.WITHDRAWAL_CONFIRMATION: "withdrawal_submitted",
    EmailTemplate.TemplateType.ACCOUNT_CREATED: "account_created",
}


def _sample_context(request) -> dict:
    u = User.objects.exclude(email="").first()
    base = request.build_absolute_uri("/").rstrip("/")
    return enrich_email_variables(
        {
            "name": u.display_name() if u else "Jane Client",
            "email": u.email if u else "client@example.com",
            "user": {"name": (u.display_name() if u else "Jane Client"), "email": (u.email if u else "client@example.com")},
            "account": {"number": "20001234"},
            "amount": "1,250.00 USD",
            "reason": "Sample rejection reason",
            "date": "2026-04-01 14:00",
            "account_number": "20001234",
            "verify_url": f"{base}/user/verify/sample-token/",
            "upload_url": f"{base}/user/kyc/",
            "password": "482910",
            "reset_link": f"{base}/user/reset/sample-token/",
            "verification_link": f"{base}/user/verify/sample-token/",
            "login_id": (u.email if u else "client@example.com"),
        }
    )


def _event_key_for_type(template_type: str, custom_slug: str) -> str:
    if template_type == EmailTemplate.TemplateType.CUSTOM:
        base = slugify(custom_slug)[:80] or "template"
        return f"custom_{base}"
    return TEMPLATE_TYPE_TO_EVENT_KEY.get(template_type, "")


def _sync_template_purpose_mapping(tpl: EmailTemplate) -> None:
    if not tpl.purpose_id:
        EmailTemplateMapping.objects.filter(template=tpl).delete()
        return
    EmailTemplateMapping.objects.update_or_create(
        purpose_id=tpl.purpose_id,
        defaults={"template": tpl},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def email_templates_system_list(request):
    ensure_default_email_templates()
    qs = EmailTemplate.objects.select_related("purpose").all().order_by("template_type", "name")
    return render(
        request,
        "admin_panel/system_management/email_templates_list.html",
        {
            "templates": qs,
            "stats": {
                "total": qs.count(),
                "active": qs.filter(status=EmailTemplate.Status.ACTIVE).count(),
            },
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_template_system_create(request):
    ensure_default_email_templates()
    purposes = EmailPurpose.objects.order_by("purpose_name")
    if request.method == "POST":
        name = (request.POST.get("name") or "").strip()[:120]
        template_type = (request.POST.get("template_type") or EmailTemplate.TemplateType.CUSTOM).strip()
        custom_slug = (request.POST.get("custom_slug") or "").strip()
        subject = (request.POST.get("subject") or "").strip()[:255]
        body = request.POST.get("body") or ""
        status = (request.POST.get("status") or "").strip().lower()
        if status not in {EmailTemplate.Status.ACTIVE, EmailTemplate.Status.INACTIVE}:
            status = EmailTemplate.Status.ACTIVE if request.POST.get("is_active") == "on" else EmailTemplate.Status.INACTIVE
        is_active = status == EmailTemplate.Status.ACTIVE
        purpose_id_raw = (request.POST.get("purpose_id") or "").strip()
        purpose = EmailPurpose.objects.filter(pk=int(purpose_id_raw)).first() if purpose_id_raw.isdigit() else None
        if not name:
            messages.error(request, "Template name is required.")
            return redirect("admin-system-email-templates-create")
        if template_type == EmailTemplate.TemplateType.CUSTOM and not slugify(custom_slug):
            messages.error(request, "Custom template requires a slug (letters, numbers, hyphens).")
            return redirect("admin-system-email-templates-create")
        ek = _event_key_for_type(template_type, custom_slug if template_type == EmailTemplate.TemplateType.CUSTOM else name)
        if template_type != EmailTemplate.TemplateType.CUSTOM:
            if EmailTemplate.objects.filter(event_key=ek).exists():
                messages.error(request, "A template for this type already exists. Edit it instead.")
                return redirect("admin-system-email-templates")
        if EmailTemplate.objects.filter(event_key=ek).exists():
            messages.error(request, "This custom key already exists. Choose another slug.")
            return redirect("admin-system-email-templates-create")
        tpl = EmailTemplate.objects.create(
            name=name,
            template_type=template_type,
            event_key=ek,
            subject=subject or "No subject",
            html_content=body,
            status=status,
            is_active=is_active,
            category=EmailTemplate.Category.USER,
            purpose=purpose,
        )
        _sync_template_purpose_mapping(tpl)
        sync_event_template_map(tpl)
        messages.success(request, "Template created.")
        return redirect("admin-system-email-templates-edit", pk=tpl.pk)
    return render(
        request,
        "admin_panel/system_management/email_template_form.html",
        {
            "tpl": None,
            "type_choices": EmailTemplate.TemplateType.choices,
            "sample_vars": _sample_context(request),
            "purposes": purposes,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_template_system_edit(request, pk: int):
    ensure_default_email_templates()
    purposes = EmailPurpose.objects.order_by("purpose_name")
    tpl = get_object_or_404(EmailTemplate, pk=pk)
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "preview_ajax":
            ctx = _sample_context(request)
            subj = render_template_text((request.POST.get("subject") or tpl.subject), ctx)
            inner = render_template_text(request.POST.get("body") or tpl.body, ctx)
            html_out = wrap_email_html(inner, EmailGlobalLayout.get_solo(), ctx)
            return JsonResponse({"subject": subj, "html": html_out})
        if action == "send_test":
            to_addr = (request.POST.get("test_email") or "").strip()
            if not to_addr:
                messages.error(request, "Enter an email address for the test.")
            else:
                ctx = _sample_context(request)
                subj, body = render_transactional_email(tpl, ctx)
                ok, err = send_dynamic_email(to_addr, subj, body, user=request.user, event_key=f"preview_{tpl.event_key}", html=True)
                messages.success(request, "Test email sent." if ok else f"Send failed: {err}")
            return redirect("admin-system-email-templates-edit", pk=tpl.pk)
        tpl.name = (request.POST.get("name") or tpl.name).strip()[:120]
        tpl.subject = (request.POST.get("subject") or "").strip()[:255]
        tpl.html_content = request.POST.get("body") or ""
        status = (request.POST.get("status") or "").strip().lower()
        if status not in {EmailTemplate.Status.ACTIVE, EmailTemplate.Status.INACTIVE}:
            status = EmailTemplate.Status.ACTIVE if request.POST.get("is_active") == "on" else EmailTemplate.Status.INACTIVE
        tpl.status = status
        tpl.is_active = status == EmailTemplate.Status.ACTIVE
        purpose_id_raw = (request.POST.get("purpose_id") or "").strip()
        tpl.purpose = EmailPurpose.objects.filter(pk=int(purpose_id_raw)).first() if purpose_id_raw.isdigit() else None
        if tpl.template_type == EmailTemplate.TemplateType.CUSTOM:
            new_slug = slugify(request.POST.get("custom_slug") or "")[:80]
            if new_slug:
                tpl.event_key = f"custom_{new_slug}"
        tpl.save()
        _sync_template_purpose_mapping(tpl)
        sync_event_template_map(tpl)
        messages.success(request, "Template saved.")
        return redirect("admin-system-email-templates-edit", pk=tpl.pk)
    return render(
        request,
        "admin_panel/system_management/email_template_form.html",
        {
            "tpl": tpl,
            "type_choices": EmailTemplate.TemplateType.choices,
            "sample_vars": _sample_context(request),
            "custom_slug": tpl.event_key.replace("custom_", "", 1) if tpl.event_key.startswith("custom_") else "",
            "purposes": purposes,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def email_template_system_toggle_status(request, pk: int):
    tpl = get_object_or_404(EmailTemplate, pk=pk)
    make_active = (request.POST.get("status") or "").strip().lower() == EmailTemplate.Status.ACTIVE
    tpl.status = EmailTemplate.Status.ACTIVE if make_active else EmailTemplate.Status.INACTIVE
    tpl.is_active = tpl.status == EmailTemplate.Status.ACTIVE
    tpl.save(update_fields=["status", "is_active", "updated_at"])
    messages.success(request, f"Template '{tpl.name}' set to {tpl.get_status_display()}.")
    return redirect("admin-system-email-templates")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_purposes_system_manage(request):
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip().lower()
        if action == "create":
            name = (request.POST.get("purpose_name") or "").strip()[:120]
            if not name:
                messages.error(request, "Purpose name is required.")
                return redirect("admin-system-email-purposes")
            key = slugify(name)[:80]
            if not key:
                messages.error(request, "Purpose name must contain letters or numbers.")
                return redirect("admin-system-email-purposes")
            if EmailPurpose.objects.filter(purpose_key=key).exists():
                messages.error(request, "Purpose already exists.")
                return redirect("admin-system-email-purposes")
            EmailPurpose.objects.create(purpose_name=name, purpose_key=key)
            messages.success(request, "Purpose created.")
            return redirect("admin-system-email-purposes")
        if action == "delete":
            pid = (request.POST.get("purpose_id") or "").strip()
            if pid.isdigit():
                EmailPurpose.objects.filter(pk=int(pid)).delete()
                messages.success(request, "Purpose deleted.")
            return redirect("admin-system-email-purposes")
    purposes = EmailPurpose.objects.all().order_by("purpose_name")
    return render(
        request,
        "admin_panel/system_management/email_purposes_list.html",
        {"purposes": purposes},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def email_template_system_delete(request, pk: int):
    tpl = get_object_or_404(EmailTemplate, pk=pk)
    name = tpl.name
    ek = tpl.event_key
    tpl.delete()
    if ek and not ek.startswith("custom_"):
        from .models import EmailSettings

        es = EmailSettings.get_solo()
        m = dict(es.event_template_map or {})
        if m.get(ek) == pk:
            del m[ek]
            es.event_template_map = m
            es.save(update_fields=["event_template_map", "updated_at"])
    messages.success(request, f"Deleted “{name}”.")
    return redirect("admin-system-email-templates")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
@xframe_options_sameorigin
def email_template_system_preview(request, pk: int):
    tpl = get_object_or_404(EmailTemplate, pk=pk)
    ctx = _sample_context(request)
    _, html_out = render_transactional_email(tpl, ctx)
    return HttpResponse(html_out)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def email_template_preview_draft(request):
    """Preview unsaved subject/body (rich editor on create)."""
    ctx = _sample_context(request)
    subject = render_template_text(request.POST.get("subject") or "Preview", ctx)
    inner = render_template_text(request.POST.get("body") or "<p>(empty body)</p>", ctx)
    html_out = wrap_email_html(inner, EmailGlobalLayout.get_solo(), ctx)
    return JsonResponse({"subject": subject, "html": html_out})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_global_layout_edit(request):
    layout = EmailGlobalLayout.get_solo()
    tpl_settings = EmailTemplateSettings.get_solo()
    if request.method == "POST":
        logo_file = request.FILES.get("email_logo")
        if logo_file:
            if logo_file.size > _MAX_EMAIL_LOGO_BYTES:
                messages.error(request, "Email logo must be 2MB or smaller.")
                return redirect("admin-system-email-layout")
            ext = os.path.splitext(logo_file.name)[1].lower()
            if ext not in _ALLOWED_EMAIL_LOGO_EXT:
                messages.error(request, "Email logo must be PNG, JPG, or SVG.")
                return redirect("admin-system-email-layout")

        layout.wrap_enabled = request.POST.get("wrap_enabled") == "on"
        layout.site_base_url = (request.POST.get("site_base_url") or "").strip()[:255]
        layout.header_html = request.POST.get("header_html") or ""
        layout.footer_html = request.POST.get("footer_html") or ""
        layout.risk_disclaimer = request.POST.get("risk_disclaimer") or ""
        layout.company_address = request.POST.get("company_address") or ""
        layout.support_email = (request.POST.get("support_email") or "").strip()[:254]
        layout.website_url = (request.POST.get("website_url") or "").strip()[:500]

        valid_pos = {c[0] for c in EmailTemplateSettings.LogoPosition.choices}
        pos = (request.POST.get("logo_position") or EmailTemplateSettings.LogoPosition.CENTER).strip()
        if pos not in valid_pos:
            pos = EmailTemplateSettings.LogoPosition.CENTER
        tpl_settings.logo_position = pos

        valid_size = {c[0] for c in EmailTemplateSettings.LogoSize.choices}
        size = (request.POST.get("logo_size") or EmailTemplateSettings.LogoSize.MEDIUM).strip()
        if size not in valid_size:
            size = EmailTemplateSettings.LogoSize.MEDIUM
        tpl_settings.logo_size = size

        hc = (request.POST.get("header_color") or "#0B1C3F").strip()[:32]
        if len(hc) == 4 and hc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in hc[1:]):
            tpl_settings.header_color = hc
        elif len(hc) == 7 and hc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in hc[1:]):
            tpl_settings.header_color = hc
        else:
            tpl_settings.header_color = "#0B1C3F"

        tc = (request.POST.get("text_color") or "#FFFFFF").strip()[:32]
        if len(tc) == 4 and tc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in tc[1:]):
            tpl_settings.text_color = tc
        elif len(tc) == 7 and tc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in tc[1:]):
            tpl_settings.text_color = tc
        else:
            tpl_settings.text_color = "#FFFFFF"

        bc = (request.POST.get("button_color") or "#0B3C5D").strip()[:32]
        if len(bc) == 4 and bc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in bc[1:]):
            tpl_settings.button_color = bc
        elif len(bc) == 7 and bc.startswith("#") and all(c in "0123456789abcdefABCDEF" for c in bc[1:]):
            tpl_settings.button_color = bc
        else:
            tpl_settings.button_color = "#0B3C5D"

        tpl_settings.company_name_override = (request.POST.get("company_name_override") or "").strip()[:180]
        tpl_settings.show_company_name = request.POST.get("show_company_name") == "on"

        if request.POST.get("clear_email_logo") == "on":
            if tpl_settings.email_logo:
                tpl_settings.email_logo.delete(save=False)
            tpl_settings.email_logo = None
        elif logo_file:
            if tpl_settings.email_logo:
                tpl_settings.email_logo.delete(save=False)
            tpl_settings.email_logo = logo_file

        try:
            tpl_settings.full_clean()
        except ValidationError:
            messages.error(request, "Logo must be PNG/JPG/SVG under 2MB.")
            return redirect("admin-system-email-layout")

        layout.save()
        tpl_settings.save()
        messages.success(request, "Global email layout saved.")
        return redirect("admin-system-email-layout")
    return render(
        request,
        "admin_panel/system_management/email_global_layout.html",
        {
            "layout": layout,
            "tpl_settings": tpl_settings,
            "logo_position_choices": EmailTemplateSettings.LogoPosition.choices,
            "logo_size_choices": EmailTemplateSettings.LogoSize.choices,
        },
    )
