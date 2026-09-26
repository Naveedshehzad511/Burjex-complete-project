from __future__ import annotations

from django.utils import timezone
from rest_framework.views import APIView

from accounts.models import ClientNotification, PushDevice
from api.permissions import IsAuthenticatedClient
from api.responses import not_found_response, success_response, validation_error_response


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


class PushDeviceRegisterAPIView(APIView):
    """POST {token, platform} registers/refreshes this device; DELETE {token} unregisters (logout)."""

    permission_classes = [IsAuthenticatedClient]

    def post(self, request):
        token = str(request.data.get("token") or "").strip()
        platform = str(request.data.get("platform") or "").strip().lower()
        if not token or len(token) > 512 or platform not in PushDevice.Platform.values:
            return validation_error_response({"token": "token and platform (ios|android) are required."})
        # A token belongs to whoever registered last, so it follows the device on account switch.
        PushDevice.objects.update_or_create(
            token=token,
            defaults={"user": request.user, "platform": platform, "is_active": True, "last_error": "", "last_seen_at": timezone.now()},
        )
        return success_response({"registered": True}, message="Device registered.")

    def delete(self, request):
        token = str(request.data.get("token") or "").strip()
        PushDevice.objects.filter(token=token, user=request.user).delete()
        return success_response({"unregistered": True}, message="Device unregistered.")
