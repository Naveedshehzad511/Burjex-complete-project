from __future__ import annotations

from rest_framework.authentication import TokenAuthentication
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from api.responses import success_response
from api.services import geo_access


class MobileGeoCheckAPIView(APIView):
    """POST the device's position (``latitude``, ``longitude``, ``accuracy`` in metres, ``simulated``): the server's
    decision for the iPhone / iPad app, and a signed ticket for the sign-in / registration that follows.

    Signed in (``Authorization: Token ...``), the outcome is also recorded for that session - this is how a signed-in
    iPhone / iPad session confirms its location again. Always 200: the decision is in the body."""

    permission_classes = [AllowAny]
    # Plain token authentication: this is the check a session without a recent one is sent to.
    authentication_classes = [TokenAuthentication]

    def post(self, request):
        p = geo_access.policy()
        user = request.user if getattr(request.user, "is_authenticated", False) else None
        d = geo_access.evaluate(request, request.data, user=user)
        if user is not None and request.auth is not None and geo_access.is_ios_app(request):
            geo_access.record(getattr(request.auth, "key", ""), user, d)
        return success_response(
            {
                "allowed": d.allowed,
                "reason": d.reason,
                "country": d.gps_country,
                "message": d.message(p),
                "ticket": geo_access.issue_ticket(d),
            },
            message="Location checked.",
        )
