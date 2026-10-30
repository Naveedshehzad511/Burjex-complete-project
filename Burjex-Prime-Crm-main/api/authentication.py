"""Token authentication for the client API, with the iPhone / iPad app's location rule (api.services.geo_access)."""

from __future__ import annotations

from rest_framework.authentication import TokenAuthentication

from api.services import geo_access


class AppTokenAuthentication(TokenAuthentication):
    """DRF token authentication. Requests from the iPhone / iPad app (``X-Client-Platform: ios``) also need a recent
    location check of their session; every other client is authenticated exactly as before."""

    def authenticate(self, request):
        result = super().authenticate(request)
        if result is not None:
            user, token = result
            geo_access.enforce_session(request, user, token)
        return result
