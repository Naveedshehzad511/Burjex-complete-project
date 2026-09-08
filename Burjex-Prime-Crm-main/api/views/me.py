from __future__ import annotations

import pyotp
from rest_framework.permissions import IsAuthenticated
from rest_framework.views import APIView

from accounts.models import UserRestriction
from accounts.restrictions import get_or_create_restriction
from api.permissions import IsAuthenticatedClient
from api.responses import success_response, validation_error_response
from api.serializers.auth import ProfileUpdateSerializer
from api.serializers.common import UserSerializer
from api.services.treasury_service import wallet_summary


class MeAPIView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return success_response(
            {
                "user": UserSerializer(request.user, context={"request": request}).data,
                "wallet": wallet_summary(request.user) if request.user.is_user() else None,
                "identity_locked": request.user.mt5_accounts.exists(),
            },
            message="Profile retrieved successfully.",
        )

    def patch(self, request):
        ser = ProfileUpdateSerializer(data=request.data, partial=True)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        user = request.user
        identity_locked = user.mt5_accounts.exists()
        changed = []
        for field in ("first_name", "last_name", "phone", "country", "address"):
            if field in ser.validated_data:
                if identity_locked:
                    continue
                setattr(user, field, ser.validated_data[field])
                changed.append(field)
        if changed:
            user.save(update_fields=changed)
        return success_response(
            {
                "user": UserSerializer(user, context={"request": request}).data,
                "identity_locked": identity_locked,
            },
            message="Profile updated successfully.",
        )


class MeRestrictionsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        r = get_or_create_restriction(request.user)
        data = {
            f.name: getattr(r, f.name)
            for f in UserRestriction._meta.fields
            if f.name not in ("id", "user")
        }
        return success_response(data, message="Restrictions retrieved successfully.")


class SecurityTotpSetupAPIView(APIView):
    """Enable/disable Google Authenticator using the same pyotp flow as the portal."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        user = request.user
        if not user.totp_secret:
            user.totp_secret = pyotp.random_base32()
            user.save(update_fields=["totp_secret"])
        totp = pyotp.TOTP(user.totp_secret)
        uri = totp.provisioning_uri(name=user.email or user.username, issuer_name="Burjex Prime")
        return success_response(
            {
                "totp_enabled": user.totp_enabled,
                "secret": user.totp_secret if not user.totp_enabled else None,
                "otpauth_uri": uri if not user.totp_enabled else None,
            },
            message="TOTP setup info retrieved.",
        )

    def post(self, request):
        user = request.user
        action = (request.data.get("action") or "enable").strip().lower()
        code = (request.data.get("code") or "").replace(" ", "").strip()
        if not user.totp_secret:
            user.totp_secret = pyotp.random_base32()
            user.save(update_fields=["totp_secret"])
        if not pyotp.TOTP(user.totp_secret).verify(code, valid_window=1):
            return validation_error_response({"code": ["Invalid authentication code."]})
        if action == "disable":
            user.totp_enabled = False
            user.totp_secret = ""
            user.save(update_fields=["totp_enabled", "totp_secret"])
            return success_response({"totp_enabled": False}, message="Two-factor authentication disabled.")
        user.totp_enabled = True
        user.save(update_fields=["totp_enabled"])
        return success_response({"totp_enabled": True}, message="Two-factor authentication enabled.")
