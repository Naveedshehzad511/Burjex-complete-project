"""Core rendering and sending engine for email_notifications.

Delegates to the existing admin_panel email infrastructure for SMTP
delivery and template rendering while adding notification-specific
features: NotificationTemplate lookup, tracking-pixel injection,
and NotificationLog creation.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from django.conf import settings
from django.core.mail import EmailMessage, get_connection
from django.utils import timezone

from .models import EmailNotificationSettings, NotificationLog, NotificationTemplate

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------

def _render_variables(template_str: str, context: dict[str, Any]) -> str:
    """Replace {{variable}} placeholders with context values.

    Supports dotted paths (e.g. {{user.name}}) by walking dicts/attrs.
    Re-uses the same regex approach as admin_panel.templated_mail.
    """
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

    def _repl(match: re.Match) -> str:
        key = (match.group(1) or "").strip()
        val = _resolve(key)
        return "" if val is None else str(val)

    return re.sub(r"\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}", _repl, template_str or "")


def _get_branding_context() -> dict[str, str]:
    """Pull branding variables from the existing admin_panel system."""
    try:
        from admin_panel.templated_mail import resolve_email_branding
        return resolve_email_branding()
    except Exception:
        return {"company_name": "Burjex Prime"}


def _enrich_context(user, context_data: dict[str, Any]) -> dict[str, Any]:
    """Merge user info and branding into the template context."""
    branding = _get_branding_context()
    ctx: dict[str, Any] = {
        "company_name": branding.get("company_name", ""),
        "support_email": branding.get("support_email", ""),
        "website_url": branding.get("website_url", ""),
        "email_logo_url": branding.get("email_logo_url", ""),
        "company_address": branding.get("company_address", ""),
        "current_date": timezone.now().strftime("%Y-%m-%d %H:%M"),
        "date": timezone.now().strftime("%Y-%m-%d %H:%M"),
    }

    # Global objects mapping for easier {{obj.field}} access in templates
    # This also handles direct variables passed from signals (e.g. ticket_number)
    if "ticket" in context_data and not isinstance(context_data["ticket"], (str, int, float, bool)):
        t = context_data["ticket"]
        ctx.update({
            "ticket_number": getattr(t, "ticket_number", ""),
            "ticket_subject": getattr(t, "subject", ""),
            "ticket_status": getattr(t, "status", ""),
            "ticket_category": getattr(t, "category", ""),
        })
    if "reply" in context_data and not isinstance(context_data["reply"], (str, int, float, bool)):
        r = context_data["reply"]
        ctx.update({
            "reply_message": getattr(r, "message", ""),
            "reply_sender": getattr(r.sender, "first_name", "Support Agent") if getattr(r, "sender", None) else "Support Agent",
        })
    if "ib_request" in context_data and not isinstance(context_data["ib_request"], (str, int, float, bool)):
        ibr = context_data["ib_request"]
        ctx.update({
            "ib_status": getattr(ibr, "status", ""),
            "ib_reason": getattr(ibr, "notes", ""),
        })

    if user:
        display = user.display_name() if callable(getattr(user, "display_name", None)) else str(user)
        ctx.update({
            "user_name": display,
            "user_email": getattr(user, "email", ""),
            "name": display,
            "email": getattr(user, "email", ""),
            "user": {
                "name": display,
                "email": getattr(user, "email", ""),
            },
        })
    ctx.update(context_data)
    return ctx


def _inject_tracking_pixel(html: str, log_id: str) -> str:
    """Append a 1x1 tracking pixel image before </body>."""
    base_url = getattr(settings, "SITE_BASE_URL", "").rstrip("/")
    if not base_url:
        # Fallback for dev — tracking still works via relative URL
        pixel_url = f"/email/track/{log_id}/pixel.png"
    else:
        pixel_url = f"{base_url}/email/track/{log_id}/pixel.png"

    pixel_tag = (
        f'<img src="{pixel_url}" width="1" height="1" '
        f'alt="" style="display:none;border:0;" />'
    )
    if "</body>" in html.lower():
        idx = html.lower().rfind("</body>")
        return html[:idx] + pixel_tag + html[idx:]
    return html + pixel_tag


# ---------------------------------------------------------------------------
# Template resolution
# ---------------------------------------------------------------------------

def resolve_template(event_key: str) -> NotificationTemplate | None:
    """Find an active NotificationTemplate by event_key."""
    return NotificationTemplate.objects.filter(
        event_key=event_key,
        is_active=True,
    ).first()


def render_notification(
    event_key: str,
    context_data: dict[str, Any],
    user=None,
    template: NotificationTemplate | None = None,
) -> tuple[str, str] | None:
    """Render a notification template into (subject, html_body).

    Returns None if no active template is found.
    Falls back to admin_panel.EmailTemplate when NotificationTemplate is missing.
    """
    tpl = template or resolve_template(event_key)

    if tpl:
        ctx = _enrich_context(user, context_data)
        subject = _render_variables(tpl.subject, ctx)
        inner_html = _render_variables(tpl.html_content, ctx)

        # Wrap with the global email layout if available
        try:
            from admin_panel.models import EmailGlobalLayout
            from admin_panel.templated_mail import wrap_email_html
            layout = EmailGlobalLayout.get_solo()
            html_body = wrap_email_html(inner_html, layout, ctx)
        except Exception:
            html_body = inner_html

        return subject, html_body

    # Fallback to admin_panel EmailTemplate
    try:
        from admin_panel.models import EmailTemplate as APEmailTemplate
        from admin_panel.templated_mail import render_transactional_email, enrich_email_variables

        ap_tpl = APEmailTemplate.objects.filter(event_key=event_key).first()
        if not ap_tpl:
            return None
        if hasattr(ap_tpl, "status") and ap_tpl.status != "active":
            return None

        ctx = _enrich_context(user, context_data)
        enriched = enrich_email_variables(ctx)
        subject, html_body = render_transactional_email(ap_tpl, enriched)
        return subject, html_body
    except Exception:
        logger.warning("Fallback to admin_panel.EmailTemplate failed for event_key=%s", event_key)
        return None


# ---------------------------------------------------------------------------
# SMTP connection
# ---------------------------------------------------------------------------

def _tls_ssl_flags(port: int, use_tls: bool, use_ssl: bool) -> tuple[bool, bool]:
    """Enforce TLS XOR SSL; align 465→SSL and 587→TLS when a flag is set."""
    use_tls = bool(use_tls)
    use_ssl = bool(use_ssl)
    if port == 465:
        return False, True
    if port == 587 and (use_tls or use_ssl):
        return True, False
    if use_tls and use_ssl:
        return True, False
    return use_tls, use_ssl


def _get_smtp_connection():
    """Build an SMTP connection from EmailNotificationSettings, falling back to admin_panel.SMTPSettings."""
    ns = EmailNotificationSettings.get_solo()

    if ns.smtp_host and ns.smtp_username:
        use_tls, use_ssl = _tls_ssl_flags(ns.smtp_port, ns.use_tls, ns.use_ssl)
        return get_connection(
            backend="admin_panel.mail_backend.CertifiEmailBackend",
            host=ns.smtp_host,
            port=ns.smtp_port,
            username=ns.smtp_username or None,
            password=ns.get_password() or None,
            use_tls=use_tls,
            use_ssl=use_ssl,
            fail_silently=False,
        ), ns.formatted_from_email

    # Fallback to legacy SMTPSettings in admin_panel
    try:
        from admin_panel.models import SMTPSettings
        smtp = SMTPSettings.get_solo()
        if smtp.smtp_host:
            from_email = smtp.sender_email or "no-reply@example.com"
            if smtp.sender_name and smtp.sender_email:
                from_email = f"{smtp.sender_name} <{smtp.sender_email}>"
            use_tls, use_ssl = _tls_ssl_flags(smtp.smtp_port, smtp.use_tls, smtp.use_ssl)
            return get_connection(
                backend="admin_panel.mail_backend.CertifiEmailBackend",
                host=smtp.smtp_host,
                port=smtp.smtp_port,
                username=smtp.smtp_username or None,
                password=smtp.smtp_password or None,
                use_tls=use_tls,
                use_ssl=use_ssl,
                fail_silently=False,
            ), from_email
    except Exception:
        pass

    return None, "no-reply@example.com"


# ---------------------------------------------------------------------------
# Main send function
# ---------------------------------------------------------------------------

def _is_duplicate_send(recipient: str, event_key: str, subject: str) -> bool:
    """Check if an identical email was sent to this recipient in the last 10 seconds."""
    ten_seconds_ago = timezone.now() - timezone.timedelta(seconds=10)
    return NotificationLog.objects.filter(
        recipient=recipient,
        event_key=event_key,
        subject=subject,
        created_at__gte=ten_seconds_ago,
        status__in=[NotificationLog.Status.SENT, NotificationLog.Status.QUEUED]
    ).exists()


def _is_rate_limited(recipient: str) -> bool:
    """Basic spam protection: limit to 20 emails per hour per recipient."""
    one_hour_ago = timezone.now() - timezone.timedelta(hours=1)
    count = NotificationLog.objects.filter(
        recipient=recipient,
        created_at__gte=one_hour_ago
    ).count()
    return count >= 20


def send_notification(
    user_id: int | None,
    event_key: str,
    context_data: dict[str, Any],
    template: NotificationTemplate | None = None,
) -> bool:
    """Render, inject tracking pixel, send, and log the notification.

    Returns True if sent successfully, False otherwise.
    """
    from django.core.validators import validate_email
    from django.core.exceptions import ValidationError
    from accounts.models import User

    user = None
    if user_id:
        user = User.objects.filter(id=user_id).first()

    to_email = context_data.get("to_email") or (user.email if user else "")
    if not to_email:
        logger.warning("send_notification: no recipient for event_key=%s", event_key)
        return False

    try:
        validate_email(to_email)
    except ValidationError:
        logger.warning("send_notification: invalid email address '%s' for event_key=%s", to_email, event_key)
        return False

    # Check master switch
    ns = EmailNotificationSettings.get_solo()
    if not ns.is_active:
        logger.info("Email notifications disabled globally; skipping %s", event_key)
        return False

    # Resolve and render template
    result = render_notification(event_key, context_data, user=user, template=template)
    if result is None:
        logger.warning("No active template for event_key=%s; skipping send", event_key)
        return False

    subject, html_body = result

    # Security: Duplicate Prevention
    if _is_duplicate_send(to_email, event_key, subject):
        logger.info("send_notification: duplicate detected for %s to %s; skipping", event_key, to_email)
        return True  # Treat as success to avoid retries

    # Security: Rate Limiting
    if _is_rate_limited(to_email):
        logger.warning("send_notification: rate limit exceeded for %s; skipping", to_email)
        return False

    tpl = template or resolve_template(event_key)

    # Create log entry (QUEUED initially)
    log_entry = NotificationLog.objects.create(
        recipient=to_email,
        user=user,
        template=tpl,
        event_key=event_key,
        subject=subject,
        status=NotificationLog.Status.QUEUED,
    )

    # Inject tracking pixel
    html_body = _inject_tracking_pixel(html_body, str(log_entry.id))

    # Send
    connection, from_email = _get_smtp_connection()
    if not connection:
        log_entry.status = NotificationLog.Status.FAILED
        log_entry.error_details = "No SMTP configuration available."
        log_entry.save(update_fields=["status", "error_details"])
        return False

    try:
        msg = EmailMessage(
            subject=subject,
            body=html_body,
            from_email=from_email,
            to=[to_email],
            connection=connection,
        )
        msg.content_subtype = "html"
        msg.send(fail_silently=False)

        log_entry.status = NotificationLog.Status.SENT
        log_entry.sent_at = timezone.now()
        log_entry.save(update_fields=["status", "sent_at"])

        # Also log in admin_panel EmailLog for unified reporting
        try:
            from admin_panel.models import EmailLog
            EmailLog.objects.create(
                user=user,
                email=to_email,
                subject=subject,
                body=html_body[:10000],
                event_key=event_key,
                status=EmailLog.Status.SENT,
            )
        except Exception:
            pass

        return True

    except Exception as exc:
        err = str(exc)[:2000]
        log_entry.status = NotificationLog.Status.FAILED
        log_entry.error_details = err
        log_entry.save(update_fields=["status", "error_details"])
        logger.error("send_notification failed for %s to %s: %s", event_key, to_email, err)

        # Also log failure in admin_panel EmailLog
        try:
            from admin_panel.models import EmailLog
            EmailLog.objects.create(
                user=user,
                email=to_email,
                subject=subject,
                body="",
                event_key=event_key,
                status=EmailLog.Status.FAILED,
                error_message=err,
            )
        except Exception:
            pass

        raise  # Re-raise so Celery retry logic can catch it
