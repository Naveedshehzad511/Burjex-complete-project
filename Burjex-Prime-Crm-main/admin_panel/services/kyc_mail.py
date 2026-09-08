"""KYC-related templated email sends with deduplication via EmailLog."""

from __future__ import annotations

from datetime import timedelta

from django.utils import timezone

from admin_panel.models import EmailLog
from admin_panel.templated_mail import send_event_email


def send_kyc_event_email(
    event_key: str,
    *,
    user,
    to_email: str | None = None,
    extra_context: dict | None = None,
    dedupe_seconds: int = 0,
    dedupe_once_per_user: bool = False,
) -> tuple[bool, str]:
    to_email = (to_email or getattr(user, "email", None) or "").strip()
    if not to_email:
        return True, "skipped_no_email"

    base_qs = EmailLog.objects.filter(
        user_id=getattr(user, "pk", None),
        event_key=event_key,
        status=EmailLog.Status.SENT,
    )
    if dedupe_once_per_user and base_qs.exists():
        return True, "skipped_duplicate"

    if dedupe_seconds > 0:
        since = timezone.now() - timedelta(seconds=dedupe_seconds)
        if base_qs.filter(created_at__gte=since).exists():
            return True, "skipped_duplicate"

    ctx = {"name": user.display_name(), **(extra_context or {})}
    return send_event_email(event_key, to_email=to_email, user=user, extra_context=ctx)
