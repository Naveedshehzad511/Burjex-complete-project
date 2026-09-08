"""Custom admin panel views for email_notifications.

Integrates with the project's custom CRM admin panel (not Django admin).
All views use @login_required + @role_required and render templates
extending admin_panel/base.html.
"""

from __future__ import annotations

import logging

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import EmailNotificationSettings, NotificationLog, NotificationTemplate

logger = logging.getLogger(__name__)


def _normalize_encryption_type(port: int, encryption_type: str) -> str:
    """Keep TLS/SSL mutually exclusive and aligned with common ports."""
    enc = (encryption_type or "TLS").strip().upper()
    if enc not in {
        EmailNotificationSettings.EncryptionType.NONE,
        EmailNotificationSettings.EncryptionType.SSL,
        EmailNotificationSettings.EncryptionType.TLS,
    }:
        enc = EmailNotificationSettings.EncryptionType.TLS
    if port == 465:
        return EmailNotificationSettings.EncryptionType.SSL
    if port == 587 and enc == EmailNotificationSettings.EncryptionType.SSL:
        return EmailNotificationSettings.EncryptionType.TLS
    return enc


def _sync_smtp_singleton_from_notification_settings(ns: EmailNotificationSettings) -> None:
    """Mirror sidebar SMTP into the legacy SMTPSettings singleton used by most CRM mail."""
    from admin_panel.models import SMTPSettings

    smtp = SMTPSettings.get_solo()
    smtp.smtp_host = ns.smtp_host or smtp.smtp_host
    smtp.smtp_port = ns.smtp_port or smtp.smtp_port
    smtp.smtp_username = ns.smtp_username or smtp.smtp_username
    # Always push decrypted password so OTP / send_dynamic_email can authenticate.
    plain = ns.get_password()
    if plain:
        smtp.smtp_password = plain
    smtp.sender_email = ns.from_email or smtp.sender_email
    smtp.sender_name = ns.from_name or smtp.sender_name
    smtp.use_tls = ns.use_tls
    smtp.use_ssl = ns.use_ssl
    # Hard XOR: never both True
    if smtp.use_tls and smtp.use_ssl:
        smtp.use_ssl = False
    smtp.save()


# ---------------------------------------------------------------------------
# 1. Notification Settings (SMTP + Master Switch)
# ---------------------------------------------------------------------------

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def notification_settings(request):
    """SMTP configuration with encrypted password + master switch."""
    ns = EmailNotificationSettings.get_solo()

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()

        if action == "save_smtp":
            ns.smtp_host = (request.POST.get("smtp_host") or "").strip()
            ns.smtp_port = int(request.POST.get("smtp_port") or 587)
            ns.smtp_username = (request.POST.get("smtp_username") or "").strip()
            ns.encryption_type = _normalize_encryption_type(
                ns.smtp_port,
                request.POST.get("encryption_type") or "TLS",
            )
            ns.from_email = (request.POST.get("from_email") or "").strip()
            ns.from_name = (request.POST.get("from_name") or "").strip()

            # Only update password if a new one was provided
            new_password = (request.POST.get("smtp_password") or "").strip()
            if new_password:
                ns.set_password(new_password)

            ns.save()
            try:
                _sync_smtp_singleton_from_notification_settings(ns)
            except Exception:
                logger.exception("Failed to sync sidebar SMTP into SMTPSettings singleton")
            messages.success(request, "SMTP settings saved with encrypted credentials.")

        elif action == "toggle_master":
            ns.is_active = request.POST.get("is_active") == "on"
            ns.save(update_fields=["is_active", "updated_at"])
            status = "enabled" if ns.is_active else "disabled"
            messages.success(request, f"Email notifications {status}.")

        elif action == "send_test":
            test_email = (request.POST.get("test_email") or "").strip()
            if not test_email:
                messages.error(request, "Enter a destination email address.")
            else:
                try:
                    from .utils import send_notification
                    success = send_notification(
                        user_id=request.user.pk,
                        event_key="welcome_email",
                        context_data={
                            "to_email": test_email,
                            "user_name": request.user.display_name(),
                        },
                    )
                    if success:
                        messages.success(request, f"Test email sent to {test_email}.")
                    else:
                        # Template missing/inactive — still probe raw SMTP so creds can be verified.
                        from admin_panel.email_service import send_dynamic_email

                        ok, err = send_dynamic_email(
                            test_email,
                            "SMTP Test Email",
                            "Your SMTP configuration is working.",
                            user=request.user,
                            event_key="smtp_test",
                        )
                        if ok:
                            messages.success(
                                request,
                                f"Test email sent to {test_email} (SMTP probe; welcome template missing or inactive).",
                            )
                        else:
                            messages.warning(request, f"Test email failed: {err}")
                except Exception as exc:
                    messages.error(request, f"Test email failed: {exc}")

        return redirect("admin-notification-email-settings")

    # Stats for the dashboard
    total_sent = NotificationLog.objects.filter(status=NotificationLog.Status.SENT).count()
    total_failed = NotificationLog.objects.filter(status=NotificationLog.Status.FAILED).count()
    total_opened = NotificationLog.objects.filter(status=NotificationLog.Status.OPENED).count()
    total_queued = NotificationLog.objects.filter(status=NotificationLog.Status.QUEUED).count()

    return render(
        request,
        "admin_panel/email_notifications/notification_settings.html",
        {
            "ns": ns,
            "has_password": bool(ns.smtp_password_encrypted),
            "total_sent": total_sent,
            "total_failed": total_failed,
            "total_opened": total_opened,
            "total_queued": total_queued,
        },
    )


# ---------------------------------------------------------------------------
# 2. Notification Templates (List + Edit)
# ---------------------------------------------------------------------------

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def notification_templates_list(request):
    """List all notification templates with status toggles."""
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        pk = request.POST.get("pk")

        if action == "toggle_status" and pk:
            tpl = NotificationTemplate.objects.filter(pk=pk).first()
            if tpl:
                tpl.is_active = not tpl.is_active
                tpl.save(update_fields=["is_active", "updated_at"])
                status = "activated" if tpl.is_active else "deactivated"
                messages.success(request, f"Template '{tpl.name}' {status}.")

        elif action == "delete" and pk:
            tpl = NotificationTemplate.objects.filter(pk=pk).first()
            if tpl:
                name = tpl.name
                tpl.delete()
                messages.success(request, f"Template '{name}' deleted.")

        return redirect("admin-notification-templates")

    templates = NotificationTemplate.objects.all()
    return render(
        request,
        "admin_panel/email_notifications/notification_templates_list.html",
        {"templates": templates},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def notification_template_edit(request, pk=None):
    """Create or edit a notification template."""
    tpl = None
    if pk:
        tpl = get_object_or_404(NotificationTemplate, pk=pk)

    if request.method == "POST":
        name = (request.POST.get("name") or "").strip()[:120]
        event_key = (request.POST.get("event_key") or "").strip()[:80]
        subject = (request.POST.get("subject") or "").strip()[:255]
        category = (request.POST.get("category") or "AUTH").strip()
        html_content = request.POST.get("html_content") or ""
        is_active = request.POST.get("is_active") == "on"

        if not name or not event_key:
            messages.error(request, "Name and event key are required.")
        elif NotificationTemplate.objects.filter(event_key=event_key).exclude(pk=tpl.pk if tpl else None).exists():
            messages.error(request, f"A template for event '{event_key}' already exists. Please edit the existing template instead.")
        else:
            if tpl:
                tpl.name = name
                tpl.event_key = event_key
                tpl.subject = subject
                tpl.category = category
                tpl.html_content = html_content
                tpl.is_active = is_active
                tpl.save()
                messages.success(request, f"Template '{name}' updated.")
            else:
                tpl = NotificationTemplate.objects.create(
                    name=name,
                    event_key=event_key,
                    subject=subject,
                    category=category,
                    html_content=html_content,
                    is_active=is_active,
                )
                messages.success(request, f"Template '{name}' created.")
            return redirect("admin-notification-templates")

    categories = NotificationTemplate.Category.choices
    return render(
        request,
        "admin_panel/email_notifications/notification_template_form.html",
        {"tpl": tpl, "categories": categories, "is_edit": pk is not None},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def notification_template_send_test(request, pk):
    """Send a test email using the selected template."""
    tpl = get_object_or_404(NotificationTemplate, pk=pk)

    try:
        from .utils import send_notification
        success = send_notification(
            user_id=request.user.pk,
            event_key=tpl.event_key,
            context_data={
                "to_email": request.user.email,
                "user_name": request.user.display_name(),
                "otp": "482910",
                "amount": "1,250.00 USD",
                "reason": "Sample test reason",
                "date": timezone.now().strftime("%Y-%m-%d %H:%M"),
                "account_number": "200012345",
            },
            template=tpl,
        )
        if success:
            messages.success(request, f"Test email sent to {request.user.email}.")
        else:
            messages.warning(request, "Test email skipped (template inactive or no SMTP configured).")
    except Exception as exc:
        messages.error(request, f"Test email failed: {exc}")

    return redirect("admin-notification-templates")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def notification_template_preview(request, pk):
    """Render a template with mock data for previewing in the CRM."""
    tpl = get_object_or_404(NotificationTemplate, pk=pk)

    from .utils import render_notification
    mock_context = {
        "user_name": request.user.display_name(),
        "user_email": request.user.email,
        "otp": "123456",
        "amount": "100.00 USD",
        "reason": "Sample mock reason for preview",
        "date": timezone.now().strftime("%Y-%m-%d %H:%M"),
        "account_number": "TRD123456",
        "ticket_number": "TKT-8899",
        "ticket_subject": "Example Support Request",
        "ticket_status": "CLOSED",
        "reply_message": "Hello, we have received your request and are looking into it. An agent will contact you shortly.",
        "ib_status": "APPROVED",
        "ib_reason": "Documentation looks good. Welcome to the IB program.",
        "verify_url": "https://example.com/verify/token123",
        "verification_link": "https://example.com/verify/token123",
        "upload_url": "https://example.com/upload/documents",
        "reset_link": "https://example.com/reset/token123",
        "login_time": timezone.now().strftime("%Y-%m-%d %H:%M"),
        "ip_address": "203.0.113.10",
        "from_account": "Wallet",
        "to_account": "TRD123456",
        "transfer_type": "WALLET_TO_TRADING",
        "trading_message": "Your trading account has a new notification.",
        "promotion_title": "Sample Promotion",
        "promotion_message": "This is a sample promotion message.",
        "promotion_link": "https://example.com/promotions",
        "campaign_name": "Sample Campaign",
        "campaign_message": "This is a sample campaign email.",
        "campaign_link": "https://example.com/campaign",
        "market_title": "Market Update",
        "market_summary": "This is a sample market update.",
        "webinar_title": "Trading Webinar",
        "webinar_date": "2026-05-20 18:00",
        "webinar_link": "https://example.com/webinar",
    }

    result = render_notification(tpl.event_key, mock_context, user=request.user, template=tpl)
    if result:
        subject, html_body = result
    else:
        subject = "Preview Failed"
        html_body = "<p>Could not render template. Ensure it is active or check fallback settings.</p>"

    return render(
        request,
        "admin_panel/email_notifications/notification_template_preview.html",
        {
            "tpl": tpl,
            "subject": subject,
            "html_body": html_body,
        },
    )


# ---------------------------------------------------------------------------
# 3. Notification Logs (Read-only + Analytics)
# ---------------------------------------------------------------------------

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def notification_logs(request):
    """View notification logs with filtering."""
    status_filter = request.GET.get("status", "")
    event_filter = request.GET.get("event_key", "")

    qs = NotificationLog.objects.select_related("user", "template").order_by("-created_at")

    if status_filter:
        qs = qs.filter(status=status_filter)
    if event_filter:
        qs = qs.filter(event_key=event_filter)

    logs = qs[:200]

    # Analytics summary
    total = NotificationLog.objects.count()
    sent = NotificationLog.objects.filter(status=NotificationLog.Status.SENT).count()
    opened = NotificationLog.objects.filter(status=NotificationLog.Status.OPENED).count()
    failed = NotificationLog.objects.filter(status=NotificationLog.Status.FAILED).count()
    queued = NotificationLog.objects.filter(status=NotificationLog.Status.QUEUED).count()

    open_rate = round((opened / sent * 100), 1) if sent > 0 else 0
    failure_rate = round((failed / total * 100), 1) if total > 0 else 0
    delivery_rate = round(((sent + opened) / total * 100), 1) if total > 0 else 0
    
    # Placeholders for advanced tracking that requires webhooks
    click_rate = "N/A"
    bounce_rate = "N/A"

    # Unique event keys for filter dropdown
    event_keys = (
        NotificationLog.objects
        .values_list("event_key", flat=True)
        .distinct()
        .order_by("event_key")
    )

    return render(
        request,
        "admin_panel/email_notifications/notification_logs.html",
        {
            "logs": logs,
            "total": total,
            "sent": sent,
            "opened": opened,
            "failed": failed,
            "queued": queued,
            "open_rate": open_rate,
            "failure_rate": failure_rate,
            "delivery_rate": delivery_rate,
            "click_rate": click_rate,
            "bounce_rate": bounce_rate,
            "status_filter": status_filter,
            "event_filter": event_filter,
            "event_keys": event_keys,
            "status_choices": NotificationLog.Status.choices,
        },
    )
