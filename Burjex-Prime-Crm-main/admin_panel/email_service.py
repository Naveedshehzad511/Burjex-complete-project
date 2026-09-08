from __future__ import annotations

import imaplib
import ssl
from email import message_from_bytes
from email.header import decode_header
from email.utils import parsedate_to_datetime

from django.core.mail import EmailMessage, get_connection
from django.core.validators import validate_email

from .models import EmailInboxMessage, EmailLog, SMTPSettings

try:
    import certifi as _certifi

    _IMAP_SSL_CONTEXT = ssl.create_default_context(cafile=_certifi.where())
except ImportError:
    _IMAP_SSL_CONTEXT = ssl.create_default_context()


def _decode_header_value(value: str) -> str:
    if not value:
        return ""
    parts = decode_header(value)
    chunks = []
    for text, enc in parts:
        if isinstance(text, bytes):
            chunks.append(text.decode(enc or "utf-8", errors="ignore"))
        else:
            chunks.append(text)
    return "".join(chunks).strip()


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


def _resolve_outbound_smtp() -> tuple[dict | None, str]:
    """Prefer EmailNotificationSettings (sidebar), then fall back to SMTPSettings.

    Returns (config_dict, error_message). config_dict keys:
    host, port, username, password, use_tls, use_ssl, from_email
    """
    try:
        from email_notifications.models import EmailNotificationSettings

        ns = EmailNotificationSettings.get_solo()
        if ns.smtp_host:
            password = ns.get_password() or ""
            if not ns.smtp_port:
                return None, "SMTP port is missing. Configure Email SMTP settings first."
            if not ns.smtp_username:
                return None, "SMTP username is missing. Configure Email SMTP settings first."
            if not password:
                return None, "SMTP password is missing. Configure Email SMTP settings first."
            use_tls, use_ssl = _tls_ssl_flags(ns.smtp_port, ns.use_tls, ns.use_ssl)
            return {
                "host": ns.smtp_host,
                "port": ns.smtp_port,
                "username": ns.smtp_username,
                "password": password,
                "use_tls": use_tls,
                "use_ssl": use_ssl,
                "from_email": ns.formatted_from_email,
            }, ""
    except Exception:
        pass

    smtp = SMTPSettings.get_solo()
    if not smtp.smtp_host:
        return None, "SMTP host is missing. Configure Email SMTP settings first."
    if not smtp.smtp_port:
        return None, "SMTP port is missing. Configure Email SMTP settings first."
    if not smtp.smtp_username:
        return None, "SMTP username is missing. Configure Email SMTP settings first."
    if not smtp.smtp_password:
        return None, "SMTP password is missing. Configure Email SMTP settings first."
    use_tls, use_ssl = _tls_ssl_flags(smtp.smtp_port, smtp.use_tls, smtp.use_ssl)
    if smtp.use_tls and smtp.use_ssl and smtp.smtp_port not in (465, 587):
        return None, "SMTP encryption conflict: enable either TLS or SSL, not both."

    from_email = smtp.sender_email or "no-reply@example.com"
    if smtp.sender_name and smtp.sender_email:
        from_email = f"{smtp.sender_name} <{smtp.sender_email}>"
    return {
        "host": smtp.smtp_host,
        "port": smtp.smtp_port,
        "username": smtp.smtp_username,
        "password": smtp.smtp_password,
        "use_tls": use_tls,
        "use_ssl": use_ssl,
        "from_email": from_email,
    }, ""


def send_dynamic_email(
    to_email: str,
    subject: str,
    body: str,
    user=None,
    event_key: str = "",
    *,
    html: bool | None = None,
) -> tuple[bool, str]:
    def _fail(msg: str) -> tuple[bool, str]:
        EmailLog.objects.create(
            user=user,
            email=to_email or "",
            subject=subject or "",
            body=body or "",
            status=EmailLog.Status.FAILED,
            error_message=msg,
            event_key=event_key or "",
        )
        return False, msg

    try:
        validate_email(to_email)
    except Exception:
        return _fail("Invalid recipient email address.")

    cfg, cfg_err = _resolve_outbound_smtp()
    if not cfg:
        return _fail(cfg_err or "SMTP host is missing. Configure Email SMTP settings first.")

    from_email = cfg["from_email"]

    connection = get_connection(
        backend="admin_panel.mail_backend.CertifiEmailBackend",
        host=cfg["host"],
        port=cfg["port"],
        username=cfg["username"] or None,
        password=cfg["password"] or None,
        use_tls=cfg["use_tls"],
        use_ssl=cfg["use_ssl"],
        fail_silently=False,
    )

    try:
        is_html = html
        if is_html is None:
            low = (body or "").lstrip().lower()
            is_html = low.startswith("<!doctype") or low.startswith("<html") or "<table" in low[:800] or "<div" in low[:400]

        msg = EmailMessage(
            subject=subject,
            body=body,
            from_email=from_email,
            to=[to_email],
            connection=connection,
        )
        if is_html:
            msg.content_subtype = "html"
        msg.send(fail_silently=False)
        EmailLog.objects.create(
            user=user,
            email=to_email,
            subject=subject,
            body=body,
            status=EmailLog.Status.SENT,
            event_key=event_key or "",
        )
        return True, ""
    except Exception as exc:
        err = str(exc)
        low = err.lower()
        if "auth" in low or "username" in low or "password" in low or "535" in low:
            err = "SMTP authentication failed. Check username/password."
        elif "timed out" in low or "timeout" in low:
            err = "SMTP connection timed out. Check host/port/firewall."
        elif "refused" in low or "unreachable" in low or "nodename" in low:
            err = "SMTP host/port unreachable. Check SMTP host and port."
        EmailLog.objects.create(
            user=user,
            email=to_email,
            subject=subject,
            body=body,
            status=EmailLog.Status.FAILED,
            error_message=err,
            event_key=event_key or "",
        )
        return False, err


def fetch_imap_inbox(limit: int = 30) -> tuple[int, str]:
    smtp = SMTPSettings.get_solo()
    if not smtp.imap_host or not smtp.imap_username:
        return 0, "IMAP not configured."
    try:
        mail = imaplib.IMAP4_SSL(smtp.imap_host, smtp.imap_port, ssl_context=_IMAP_SSL_CONTEXT)
        mail.login(smtp.imap_username, smtp.imap_password)
        mail.select("INBOX")
        status, data = mail.search(None, "ALL")
        if status != "OK":
            return 0, "Unable to read inbox."
        ids = data[0].split()[-limit:]
        created = 0
        for msg_id in reversed(ids):
            status, msg_data = mail.fetch(msg_id, "(RFC822)")
            if status != "OK" or not msg_data:
                continue
            raw = msg_data[0][1]
            msg = message_from_bytes(raw)
            sender = _decode_header_value(msg.get("From", ""))
            subject = _decode_header_value(msg.get("Subject", ""))
            date_raw = msg.get("Date", "")
            received_at = None
            try:
                received_at = parsedate_to_datetime(date_raw) if date_raw else None
            except Exception:
                received_at = None

            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    ctype = part.get_content_type()
                    disp = str(part.get("Content-Disposition") or "")
                    if ctype == "text/plain" and "attachment" not in disp.lower():
                        payload = part.get_payload(decode=True) or b""
                        body = payload.decode(part.get_content_charset() or "utf-8", errors="ignore")
                        break
            else:
                payload = msg.get_payload(decode=True) or b""
                body = payload.decode(msg.get_content_charset() or "utf-8", errors="ignore")

            _, was_created = EmailInboxMessage.objects.get_or_create(
                sender=sender[:254],
                subject=subject[:255],
                raw_date=date_raw[:255],
                defaults={"message": body[:20000], "received_at": received_at},
            )
            if was_created:
                created += 1
        mail.logout()
        return created, ""
    except Exception as exc:
        return 0, str(exc)
