"""Client-initiated account deletion.

GET    - the policy, anything outstanding, and any request already in flight
POST   - open a deletion request (password re-entry required)
DELETE - cancel a request that is still inside its grace window

Deliberately reachable by any authenticated client with no preconditions on the
GET or the POST. Apple requires that deletion can always be *started* from
inside the app; gating that behind "settle your balance first" would mean a
client with a stuck cent could never begin, which is exactly the shape of
rejection the guideline exists to prevent. Outstanding items are surfaced and
handed to staff instead of used as a barrier.
"""

from __future__ import annotations

from django.utils import timezone
from rest_framework.views import APIView

from accounts.models import AccountDeletionRequest
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response, validation_error_response
from api.services.account_deletion import collect_obligations, request_payload


def _live_request(user):
    return (
        AccountDeletionRequest.objects.filter(
            user=user, status=AccountDeletionRequest.Status.PENDING
        )
        .order_by("-requested_at")
        .first()
    )


class AccountDeletionAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        return success_response(
            request_payload(_live_request(request.user), request.user),
            message="Account deletion details retrieved successfully.",
        )

    def post(self, request):
        user = request.user

        existing = _live_request(user)
        if existing is not None:
            # Not an error worth a 400 - the client is already where they asked
            # to be, and a retry after a dropped response should look like
            # success rather than a failure they have to interpret.
            return success_response(
                request_payload(existing, user),
                message="You already have a deletion request in progress.",
            )

        # Re-authenticate. Deletion is irreversible once the window closes, and
        # an unlocked handset must not be enough to end someone's account.
        password = (request.data.get("password") or "").strip()
        if not password:
            return validation_error_response(
                {"password": ["Enter your password to confirm."]}
            )
        if not user.check_password(password):
            return validation_error_response(
                {"password": ["That password is not correct."]}
            )

        reason = (request.data.get("reason") or "").strip().upper()
        valid = {c for c, _ in AccountDeletionRequest.Reason.choices}
        if reason not in valid:
            reason = AccountDeletionRequest.Reason.OTHER

        details = (request.data.get("details") or "").strip()[:2000]

        req = AccountDeletionRequest.objects.create(
            user=user,
            reason=reason,
            details=details,
            requested_at=timezone.now(),
            obligations_snapshot=collect_obligations(user),
        )

        _notify(user, req)

        return success_response(
            request_payload(req, user),
            message="Your account deletion request has been received.",
            status=201,
        )

    def delete(self, request):
        req = _live_request(request.user)
        if req is None:
            return error_response(
                "You do not have a deletion request to cancel.", status=404
            )
        if not req.is_cancellable:
            return error_response(
                "This request can no longer be cancelled.", status=409
            )
        req.status = AccountDeletionRequest.Status.CANCELLED
        req.processed_at = timezone.now()
        req.save(update_fields=["status", "processed_at"])
        return success_response(
            request_payload(None, request.user),
            message="Your account deletion request has been cancelled.",
        )


def _notify(user, req) -> None:
    """Confirm by email, so a request the account owner did not make is visible.

    Best-effort by design: if mail is down the request itself must still stand.
    Losing the notification is recoverable, losing the request is not.
    """
    try:
        from django.core.mail import send_mail
        from django.conf import settings

        send_mail(
            subject="Your account deletion request",
            message=(
                f"Hello {user.get_full_name() or user.username},\n\n"
                "We have received a request to delete your account.\n\n"
                f"Reference: #{req.id}\n"
                f"Requested: {req.requested_at:%d %B %Y}\n"
                f"Scheduled for: {req.grace_until:%d %B %Y}\n\n"
                f"You can cancel this at any time before "
                f"{req.grace_until:%d %B %Y} by signing in and opening "
                "Settings - Delete account.\n\n"
                "If you did not make this request, sign in and cancel it "
                "immediately, then change your password.\n"
            ),
            from_email=getattr(settings, "DEFAULT_FROM_EMAIL", None),
            recipient_list=[user.email] if user.email else [],
            fail_silently=True,
        )
    except Exception:
        pass
