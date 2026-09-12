from __future__ import annotations

from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.views import APIView

from api.responses import error_response, success_response, validation_error_response
from api.serializers.auth import (
    AdminLoginSerializer,
    ChangePasswordSerializer,
    ClientLoginSerializer,
    ClientSignupSerializer,
    ForgotPasswordSerializer,
    ResetPasswordSerializer,
    ResendVerificationSerializer,
    TotpVerifySerializer,
)
from api.serializers.common import UserSerializer
from api.services import auth_service


def _user_payload(request, user):
    return UserSerializer(user, context={"request": request}).data


class ClientLoginAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = ClientLoginSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, result = auth_service.client_login(
            request, ser.validated_data["username"], ser.validated_data["password"]
        )
        if not ok:
            return error_response(
                result.get("message", "Login failed."),
                errors=result.get("errors"),
                data=result.get("data"),
                status=400,
            )
        if result.get("totp_required"):
            return success_response(
                {
                    "totp_required": True,
                    "pending_token": result["pending_token"],
                    "user_id": result.get("user_id"),
                },
                message=result.get("message", "Two-factor authentication required."),
            )
        user = result["user"]
        token = result["token"]
        data = {
            "totp_required": False,
            "token": token,
            # Flutter clients may read `access` (DRF Token auth; no separate JWT refresh).
            "access": token,
            "refresh": None,
            "force_password_change": result.get("force_password_change", False),
            "user": _user_payload(request, user),
        }
        if result.get("demo_account"):
            data["demo_account"] = result["demo_account"]
        return success_response(
            data,
            message="Login successful.",
        )


class StaffLoginAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = AdminLoginSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, result = auth_service.staff_login(
            request, ser.validated_data["username"], ser.validated_data["password"]
        )
        if not ok:
            return error_response(
                result.get("message", "Login failed."),
                errors=result.get("errors"),
                status=400,
            )
        if result.get("totp_required"):
            return success_response(
                {
                    "totp_required": True,
                    "pending_token": result["pending_token"],
                    "user_id": result.get("user_id"),
                },
                message=result.get("message", "Two-factor authentication required."),
            )
        user = result["user"]
        return success_response(
            {
                "totp_required": False,
                "token": result["token"],
                "home_path": result.get("home_path"),
                "user": _user_payload(request, user),
            },
            message="Login successful.",
        )


class ClientTotpVerifyAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = TotpVerifySerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, result = auth_service.verify_client_totp(
            request,
            ser.validated_data["code"],
            ser.validated_data.get("pending_token") or "",
        )
        if not ok:
            return error_response(
                result.get("message", "TOTP verification failed."),
                errors=result.get("errors"),
                status=400,
            )
        token = result["token"]
        data = {
            "token": token,
            "access": token,
            "refresh": None,
            "force_password_change": result.get("force_password_change", False),
            "user": _user_payload(request, result["user"]),
        }
        if result.get("demo_account"):
            data["demo_account"] = result["demo_account"]
        return success_response(
            data,
            message="Login successful.",
        )


class StaffTotpVerifyAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = TotpVerifySerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, result = auth_service.verify_admin_totp(
            request,
            ser.validated_data["code"],
            ser.validated_data.get("pending_token") or "",
        )
        if not ok:
            return error_response(
                result.get("message", "TOTP verification failed."),
                errors=result.get("errors"),
                status=400,
            )
        return success_response(
            {
                "token": result["token"],
                "home_path": result.get("home_path"),
                "user": _user_payload(request, result["user"]),
            },
            message="Login successful.",
        )


class ClientSignupAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        """Return admin signup field modes so Flutter matches the web portal form."""
        return success_response(
            auth_service.signup_field_config(),
            message="Signup configuration retrieved successfully.",
        )

    def post(self, request):
        # Pass raw request data (not only serializer validated subset) so optional
        # portal fields and captcha reach ClientSignupForm unchanged.
        ser = ClientSignupSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        merged = {**dict(request.data), **ser.validated_data}
        ok, result = auth_service.client_signup(request, merged)
        if not ok:
            return error_response(
                result.get("message", "Registration failed."),
                errors=result.get("errors"),
                status=400,
            )
        data = {k: v for k, v in result.items() if k != "user"}
        if result.get("user"):
            data["user"] = _user_payload(request, result["user"])
        return success_response(data, message=result.get("message", "Account created successfully."), status=201)


class ForgotPasswordAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = ForgotPasswordSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        result = auth_service.forgot_password(ser.validated_data["email"], portal=True)
        if not result.get("ok"):
            return validation_error_response(result.get("errors") or {})
        return success_response({}, message=result["message"])


class ResetPasswordAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = ResetPasswordSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        result = auth_service.confirm_password_reset(
            ser.validated_data["uid"],
            ser.validated_data["token"],
            ser.validated_data["new_password"],
        )
        if not result.get("ok"):
            return validation_error_response(result.get("errors") or {})
        return success_response({}, message=result["message"])


class VerifyEmailAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def _run(self, token: str):
        ok, message = auth_service.verify_email_token(token)
        if not ok:
            return error_response(message, status=400)
        return success_response({}, message=message)

    def get(self, request, token: str = ""):
        tok = token or (request.query_params.get("token") or "")
        return self._run(tok)

    def post(self, request, token: str = ""):
        tok = token or (request.data.get("token") or "")
        return self._run(tok)


class ResendVerificationAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        ser = ResendVerificationSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, message = auth_service.resend_verification(request, ser.validated_data["email"])
        if not ok:
            return error_response(message, status=400)
        return success_response({}, message=message)


class LogoutAPIView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        auth_service.api_logout(request, request.user)
        return success_response({}, message="Logged out successfully.")


class ChangePasswordAPIView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        ser = ChangePasswordSerializer(data=request.data)
        if not ser.is_valid():
            return validation_error_response(ser.errors)
        ok, result = auth_service.change_password(
            request.user,
            ser.validated_data["current_password"],
            ser.validated_data["new_password"],
        )
        if not ok:
            return validation_error_response(result.get("errors") or {})
        return success_response(
            {"token": result["token"]},
            message=result.get("message", "Password changed successfully."),
        )
