"""Client portal JSON APIs for in-app notifications."""

from __future__ import annotations

from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.http import require_GET, require_POST

from accounts.models import ClientNotification


@login_required
@require_GET
def notifications_list_api(request):
    qs = ClientNotification.objects.filter(user=request.user).order_by("-created_at")[:80]
    items = [
        {
            "id": n.id,
            "title": n.title,
            "message": n.message,
            "notification_type": n.notification_type,
            "is_read": n.is_read,
            "created_at": timezone.localtime(n.created_at).isoformat(),
        }
        for n in qs
    ]
    unread = sum(1 for x in items if not x["is_read"])
    return JsonResponse({"items": items, "unread_count": unread})


@login_required
@require_POST
def notification_mark_read_api(request, pk: int):
    updated = ClientNotification.objects.filter(pk=pk, user=request.user, is_read=False).update(is_read=True)
    return JsonResponse({"ok": True, "updated": bool(updated)})
