from __future__ import annotations

from typing import Any

from django.http import HttpRequest

from .models import AuditLog, AuditLogChannel


def get_client_ip(request: HttpRequest | None) -> str | None:
    if not request:
        return None
    xff = request.META.get("HTTP_X_FORWARDED_FOR")
    if xff:
        return xff.split(",")[0].strip()[:45] or None
    ip = request.META.get("REMOTE_ADDR")
    return (ip or "")[:45] or None


def log_audit(
    *,
    action: str,
    entity_type: str,
    entity_id: str = "",
    actor=None,
    channel: str = AuditLogChannel.SYSTEM,
    request: HttpRequest | None = None,
    ip: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> AuditLog:
    actor_email = ""
    if actor is not None:
        actor_email = (getattr(actor, "email", None) or "")[:254]
    resolved_ip = ip if ip is not None else get_client_ip(request)
    return AuditLog.objects.create(
        actor=actor if actor and getattr(actor, "pk", None) else None,
        actor_email=actor_email,
        action=action[:80],
        entity_type=entity_type[:60],
        entity_id=(entity_id or "")[:64],
        channel=channel,
        ip=resolved_ip,
        metadata=metadata or {},
    )
