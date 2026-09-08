from __future__ import annotations

from django.utils import timezone
from rest_framework.views import APIView

from accounts.models import ClientNotification
from api.permissions import IsAuthenticatedClient
from api.responses import not_found_response, success_response


def _serialize_notification(n: ClientNotification) -> dict:
    return {
        "id": n.id,
        "title": n.title,
        "message": n.message,
        "notification_type": n.notification_type,
        "is_read": n.is_read,
        "created_at": timezone.localtime(n.created_at).isoformat(),
    }


class ClientNotificationsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        limit = min(int(request.query_params.get("limit") or 80), 200)
        qs = ClientNotification.objects.filter(user=request.user).order_by("-created_at")[:limit]
        items = [_serialize_notification(n) for n in qs]
        unread = sum(1 for x in items if not x["is_read"])
        return success_response(
            {"items": items, "unread_count": unread},
            message="Notifications retrieved successfully.",
        )

    def post(self, request):
        updated = ClientNotification.objects.filter(user=request.user, is_read=False).update(is_read=True)
        return success_response(
            {"updated_count": updated},
            message="All notifications marked as read.",
        )


class ClientNotificationMarkReadAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def post(self, request, pk: int):
        updated = ClientNotification.objects.filter(pk=pk, user=request.user, is_read=False).update(is_read=True)
        if not updated:
            exists = ClientNotification.objects.filter(pk=pk, user=request.user).exists()
            if not exists:
                return not_found_response("Notification not found.")
        return success_response({"updated": bool(updated)}, message="Notification marked as read.")
