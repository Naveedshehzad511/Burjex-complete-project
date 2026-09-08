"""Broadcast in-app notifications to admin / banker staff."""

from __future__ import annotations

from accounts.models import User

from .models import StaffNotification


def broadcast_staff_notification(
    title: str,
    body: str = "",
    *,
    action_url: str = "",
    dedupe_body_contains: str | None = None,
) -> int:
    """
    Create one unread StaffNotification per active admin/banker.
    If dedupe_body_contains is set, skip recipients who already have an unread
    notification whose body contains that substring.
    Returns number of notifications created.
    """
    title = (title or "")[:200]
    body = (body or "")[:5000]
    action_url = (action_url or "")[:512]
    recipients = User.objects.filter(
        role__in=[User.Roles.ADMIN, User.Roles.BANKER],
        is_active=True,
    )
    created = 0
    for recipient in recipients:
        if dedupe_body_contains:
            token = dedupe_body_contains[:500]
            if StaffNotification.objects.filter(
                recipient=recipient,
                read_at__isnull=True,
                body__icontains=token,
            ).exists():
                continue
        StaffNotification.objects.create(
            recipient=recipient,
            title=title,
            body=body,
            action_url=action_url,
        )
        created += 1
    return created
