"""Admin email management: SMTP integration, automation templates, master toggle."""

from __future__ import annotations

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .email_service import fetch_imap_inbox, send_dynamic_email
from .models import EmailInboxMessage, EmailLog, EmailSettings, EmailSystemSettings, EmailTemplate, SMTPSettings
from .templated_mail import EVENT_LABELS, ensure_default_email_templates, render_template_text, render_transactional_email


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_management_hub(request):
    ensure_default_email_templates()
    smtp = SMTPSettings.get_solo()
    sys_s = EmailSystemSettings.get_solo()
    email_settings = EmailSettings.get_solo()

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "save_smtp":
            smtp.smtp_host = (request.POST.get("smtp_host") or "").strip()
            smtp.smtp_port = int(request.POST.get("smtp_port") or 587)
            smtp.smtp_username = (request.POST.get("smtp_username") or "").strip()
            smtp.smtp_password = (request.POST.get("smtp_password") or "").strip()
            smtp.sender_email = (request.POST.get("sender_email") or "").strip()
            smtp.sender_name = (request.POST.get("sender_name") or "").strip()
            smtp.use_tls = request.POST.get("use_tls") == "on"
            smtp.use_ssl = request.POST.get("use_ssl") == "on"
            smtp.imap_host = (request.POST.get("imap_host") or "").strip()
            smtp.imap_port = int(request.POST.get("imap_port") or 993)
            smtp.imap_username = (request.POST.get("imap_username") or "").strip()
            smtp.imap_password = (request.POST.get("imap_password") or "").strip()
            smtp.save()
            messages.success(request, "SMTP / IMAP settings saved.")
        elif action == "test_email":
            to_addr = (request.POST.get("test_email") or "").strip()
            if not to_addr:
                messages.error(request, "Enter a destination email.")
            else:
                ok, err = send_dynamic_email(to_addr, "SMTP test", "Your SMTP configuration is working.", event_key="smtp_test")
                messages.success(request, "Test email sent." if ok else f"Failed: {err}")
        elif action == "save_master":
            sys_s.master_enabled = request.POST.get("master_enabled") == "on"
            sys_s.save(update_fields=["master_enabled", "updated_at"])
            messages.success(request, "Global email automation updated.")
        elif action == "save_event_mapping":
            mapping: dict[str, int] = {}
            for event_key, _label in EVENT_LABELS:
                raw = (request.POST.get(f"map_{event_key}") or "").strip()
                if not raw:
                    continue
                try:
                    mapping[event_key] = int(raw)
                except ValueError:
                    continue
            email_settings.event_template_map = mapping
            email_settings.save(update_fields=["event_template_map", "updated_at"])
            messages.success(request, "Email event mapping saved.")
        return redirect("admin-email-management")

    templates = EmailTemplate.objects.order_by("event_key")
    recent_logs = EmailLog.objects.select_related("user").order_by("-created_at")[:40]
    event_map = email_settings.event_template_map or {}
    event_rows = [{"key": key, "label": label, "selected_id": int(event_map.get(key) or 0)} for key, label in EVENT_LABELS]
    return render(
        request,
        "admin_panel/email_management_hub.html",
        {
            "smtp": smtp,
            "sys_s": sys_s,
            "templates": templates,
            "recent_logs": recent_logs,
            "event_rows": event_rows,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_template_edit(request, event_key: str):
    ensure_default_email_templates()
    tpl = EmailTemplate.objects.filter(event_key=event_key).first()
    if not tpl:
        messages.error(request, "Unknown template.")
        return redirect("admin-email-management")

    preview_user = User.objects.exclude(email="").first()

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "save":
            tpl.name = (request.POST.get("name") or tpl.name).strip()[:120]
            tpl.subject = (request.POST.get("subject") or "").strip()[:255]
            tpl.body = request.POST.get("body") or ""
            tpl.send_enabled = request.POST.get("send_enabled") == "on"
            tpl.save(update_fields=["name", "subject", "body", "send_enabled", "updated_at"])
            messages.success(request, "Template saved.")
            return redirect("admin-email-template-edit", event_key=event_key)
        if action == "send_test" and preview_user:
            ctx = {
                "name": preview_user.display_name(),
                "email": preview_user.email,
                "amount": "100 USD",
                "reason": "Sample reason",
                "date": "2026-01-01 12:00",
                "account_number": "123456",
                "user": {"name": preview_user.display_name(), "email": preview_user.email},
                "account": {"number": "123456"},
            }
            subj, body = render_transactional_email(tpl, ctx)
            ok, err = send_dynamic_email(
                preview_user.email, subj, body, user=preview_user, event_key=f"test_{event_key}", html=True
            )
            messages.success(request, "Test sent." if ok else f"Send failed: {err}")
            return redirect("admin-email-template-edit", event_key=event_key)

    return render(
        request,
        "admin_panel/email_template_edit.html",
        {"tpl": tpl, "preview_user": preview_user},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_inbox_page(request):
    if request.method == "POST":
        action = request.POST.get("action") or ""
        if action == "fetch":
            count, err = fetch_imap_inbox(limit=50)
            messages.success(request, f"Fetched {count} emails." if not err else f"Inbox fetch failed: {err}")
            return redirect("admin-email-inbox")
        if action == "reply":
            row = EmailInboxMessage.objects.filter(id=request.POST.get("id")).first()
            reply_body = (request.POST.get("reply_body") or "").strip()
            if not row or not reply_body:
                messages.error(request, "Invalid reply request.")
                return redirect("admin-email-inbox")
            ok, err = send_dynamic_email(row.sender, f"Re: {row.subject}", reply_body)
            if ok:
                row.replied = True
                row.save(update_fields=["replied"])
                messages.success(request, "Reply sent.")
            else:
                messages.error(request, f"Reply failed: {err}")
            return redirect("admin-email-inbox")
        if action == "test":
            test_email = (request.POST.get("test_email") or "").strip()
            if not test_email:
                messages.error(request, "Test email is required.")
                return redirect("admin-email-inbox")
            ok, err = send_dynamic_email(test_email, "SMTP Test Email", "Your SMTP is working.")
            messages.success(request, "Test email sent." if ok else f"Test email failed: {err}")
            return redirect("admin-email-inbox")
    inbox = EmailInboxMessage.objects.all()[:200]
    return render(request, "admin_panel/email_inbox.html", {"rows": inbox})
