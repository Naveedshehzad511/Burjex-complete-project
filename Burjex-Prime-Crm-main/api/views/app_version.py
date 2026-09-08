"""Public mobile app version manifest — drives the in-app update prompt.

The clients ship as sideloaded APKs served off the deploy box, so there is no
store to tell anyone a new build exists. This endpoint is that signal: the app
compares its own build number against `latest_build` on start-up and offers (or
forces) an update.

Configured entirely through the environment, deliberately: a release is a deploy
concern, not a database record. Bump `APP_LATEST_BUILD` in `deploy/.env.prod.ip`
and restart — no migration, no admin round-trip.
"""

from __future__ import annotations

import os

from django.conf import settings
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from api.responses import success_response


def _env_int(name: str, default: int) -> int:
    try:
        return int((os.environ.get(name) or "").strip())
    except (TypeError, ValueError):
        return default


def _env_str(name: str, default: str = "") -> str:
    return (os.environ.get(name) or "").strip() or default


class AppVersionAPIView(APIView):
    """
    Latest available mobile build.

    ``latest_build`` / ``minimum_build`` are Flutter **build numbers** — the
    integer after the ``+`` in pubspec's ``version: 1.0.0+1``, which becomes
    Android's ``versionCode``. Integers compare unambiguously; semver strings do
    not, so the version *name* is display-only.

    A client with ``build < minimum_build`` must update before continuing; one
    with ``build < latest_build`` is merely offered it.
    """

    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        latest_build = _env_int("APP_LATEST_BUILD", 1)
        minimum_build = _env_int("APP_MINIMUM_BUILD", 0)

        # A minimum above the latest would lock every client out of an app they
        # cannot yet obtain. Clamp rather than trust the env file.
        if minimum_build > latest_build:
            minimum_build = latest_build

        download_url = _env_str("APP_DOWNLOAD_URL")
        if not download_url:
            base = (getattr(settings, "SITE_BASE_URL", "") or "").strip().rstrip("/")
            download_url = f"{base}/app-release.apk" if base else ""

        return success_response(
            {
                "latest_version": _env_str("APP_LATEST_VERSION", "1.0.0"),
                "latest_build": latest_build,
                "minimum_build": minimum_build,
                "download_url": download_url,
                "release_notes": _env_str("APP_RELEASE_NOTES"),
            },
            message="App version retrieved successfully.",
        )
