from __future__ import annotations

from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from django.contrib import messages
from django.http import HttpRequest, HttpResponse
from django.shortcuts import redirect
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from api.responses import error_response, success_response
from api.serializers.common import UserSerializer
from api.services import social_auth


def _safe_next(request: HttpRequest, next_url: str) -> str:
    raw = (next_url or "").strip()
    if not raw:
        return ""
    if raw.startswith("/") and not raw.startswith("//"):
        return raw
    try:
        parsed = urlsplit(raw)
    except Exception:
        return ""
    if parsed.scheme == "burjexprime":
        return raw
    if parsed.scheme not in {"http", "https"}:
        return ""
    host = (parsed.hostname or "").lower()
    allowed = {
        (request.get_host() or "").split(":")[0].lower(),
        "127.0.0.1",
        "localhost",
        "crm.duafx.com",
        "portal.duafx.com",
        "crm.burjexprime.net",
        "portal.burjexprime.net",
        "admin.burjexprime.net",
    }
    if host in allowed or host.endswith(".duafx.com") or host.endswith(".burjexprime.net"):
        return raw
    try:
        import ipaddress

        ip = ipaddress.ip_address(host)
        if ip.is_private or ip.is_loopback:
            return raw
    except ValueError:
        pass
    return ""


def _with_oauth_token(next_url: str, token: str) -> str:
    if not next_url:
        return ""
    parsed = urlsplit(next_url)
    params = dict(parse_qsl(parsed.query, keep_blank_values=True))
    params["oauth_token"] = token
    path = parsed.path or "/"
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(params), ""))


def _finish_web(request: HttpRequest, user, *, mode: str, next_url: str):
    safe_next = _safe_next(request, next_url)
    if mode == "token":
        result = social_auth.complete_api_login(request, user)
        if result.get("totp_required"):
            return _render_error(
                request,
                "Two-factor authentication is required. Sign in with email and password.",
                next_url=safe_next,
            )
        dest = _with_oauth_token(safe_next, result["token"]) if safe_next else ""
        if dest:
            return redirect(dest)
        return redirect("user-dashboard")
    dest = social_auth.complete_html_login(request, user)
    if dest == "totp":
        return redirect("user-totp-verify")
    return redirect(safe_next or dest)


def _render_error(request: HttpRequest, message: str, next_url: str = "") -> HttpResponse:
    safe = _safe_next(request, next_url or request.GET.get("next") or "")
    if safe:
        parsed = urlsplit(safe)
        params = dict(parse_qsl(parsed.query, keep_blank_values=True))
        params["social_error"] = (message or "Social login failed.")[:300]
        dest = urlunsplit((parsed.scheme, parsed.netloc, parsed.path or "/", urlencode(params), ""))
        return redirect(dest)
    messages.error(request, message)
    return redirect("user-login")


@require_http_methods(["GET"])
def google_start(request: HttpRequest):
    mode = (request.GET.get("mode") or "html").strip().lower()
    next_url = request.GET.get("next") or request.META.get("HTTP_REFERER") or ""
    try:
        state = social_auth.new_oauth_state(request, mode=mode, next_url=next_url)
        return redirect(social_auth.google_authorize_url(request, state))
    except ValueError as exc:
        return _render_error(request, str(exc), next_url=next_url)


@require_http_methods(["GET"])
def apple_start(request: HttpRequest):
    mode = (request.GET.get("mode") or "html").strip().lower()
    next_url = request.GET.get("next") or request.META.get("HTTP_REFERER") or ""
    try:
        state = social_auth.new_oauth_state(request, mode=mode, next_url=next_url)
        return redirect(social_auth.apple_authorize_url(request, state))
    except ValueError as exc:
        return _render_error(request, str(exc), next_url=next_url)


@require_http_methods(["GET"])
def google_callback(request: HttpRequest):
    err = (request.GET.get("error") or "").strip()
    next_url = ""
    try:
        mode, next_url = social_auth.pop_oauth_state(request, request.GET.get("state") or "")
    except ValueError as exc:
        if err:
            return _render_error(request, "Google sign-in was cancelled.")
        return _render_error(request, str(exc))
    if err:
        return _render_error(request, "Google sign-in was cancelled.", next_url=next_url)
    try:
        profile = social_auth.exchange_google_code(request, request.GET.get("code") or "")
        user = social_auth.get_or_create_social_user(profile)
        return _finish_web(request, user, mode=mode, next_url=next_url)
    except ValueError as exc:
        return _render_error(request, str(exc), next_url=next_url)
    except Exception:
        return _render_error(request, "Google sign-in failed. Please try again.", next_url=next_url)


@csrf_exempt
@require_http_methods(["GET", "POST"])
def apple_callback(request: HttpRequest):
    data = request.POST if request.method == "POST" else request.GET
    err = (data.get("error") or "").strip()
    first_name = last_name = ""
    raw_user = data.get("user") or ""
    if raw_user:
        try:
            import json

            parsed = json.loads(raw_user)
            name = parsed.get("name") or {}
            first_name = str(name.get("firstName") or "")
            last_name = str(name.get("lastName") or "")
        except Exception:
            pass
    next_url = ""
    try:
        mode, next_url = social_auth.pop_oauth_state(request, data.get("state") or "")
    except ValueError as exc:
        if err:
            return _render_error(request, "Apple sign-in was cancelled.")
        return _render_error(request, str(exc))
    if err:
        return _render_error(request, "Apple sign-in was cancelled.", next_url=next_url)
    try:
        profile = social_auth.exchange_apple_code(
            request, data.get("code") or "", data.get("id_token") or ""
        )
        if first_name:
            profile["first_name"] = first_name
        if last_name:
            profile["last_name"] = last_name
        user = social_auth.get_or_create_social_user(profile)
        return _finish_web(request, user, mode=mode, next_url=next_url)
    except ValueError as exc:
        return _render_error(request, str(exc), next_url=next_url)
    except Exception:
        return _render_error(request, "Apple sign-in failed. Please try again.", next_url=next_url)


class SocialOptionsAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        return success_response(social_auth.public_options(), message="Social login options.")


class GoogleTokenAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        token = (request.data.get("id_token") or request.data.get("token") or "").strip()
        if not token:
            return error_response("Google id_token is required.", status=400)
        try:
            profile = social_auth.verify_google_id_token(token)
            user = social_auth.get_or_create_social_user(profile)
            result = social_auth.complete_api_login(request, user)
        except ValueError as exc:
            return error_response(str(exc), status=400)
        except Exception:
            return error_response("Google sign-in failed.", status=400)
        if result.get("totp_required"):
            return success_response(
                {
                    "totp_required": True,
                    "pending_token": result["pending_token"],
                    "user_id": result.get("user_id"),
                },
                message="Two-factor authentication required.",
            )
        return success_response(
            {
                "totp_required": False,
                "token": result["token"],
                "access": result["token"],
                "refresh": None,
                "user": UserSerializer(user, context={"request": request}).data,
            },
            message="Login successful.",
        )


class AppleTokenAPIView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        token = (request.data.get("id_token") or request.data.get("identity_token") or "").strip()
        if not token:
            return error_response("Apple identity token is required.", status=400)
        try:
            profile = social_auth.verify_apple_identity(
                token,
                first_name=str(request.data.get("first_name") or ""),
                last_name=str(request.data.get("last_name") or ""),
            )
            user = social_auth.get_or_create_social_user(profile)
            result = social_auth.complete_api_login(request, user)
        except ValueError as exc:
            return error_response(str(exc), status=400)
        except Exception:
            return error_response("Apple sign-in failed.", status=400)
        if result.get("totp_required"):
            return success_response(
                {
                    "totp_required": True,
                    "pending_token": result["pending_token"],
                    "user_id": result.get("user_id"),
                },
                message="Two-factor authentication required.",
            )
        return success_response(
            {
                "totp_required": False,
                "token": result["token"],
                "access": result["token"],
                "refresh": None,
                "user": UserSerializer(user, context={"request": request}).data,
            },
            message="Login successful.",
        )
