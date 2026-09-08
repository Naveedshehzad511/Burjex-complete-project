from django.conf import settings
from django.core.cache import cache
from django.http import HttpResponseForbidden
from django.utils.deprecation import MiddlewareMixin

from .utils import get_client_ip, login_paths_match


class ExtraSecurityHeadersMiddleware(MiddlewareMixin):
    """
    Adds defense-in-depth headers not always set by the reverse proxy.

    Strict CSP/HSTS are environment-driven so templates and TLS termination stay compatible.
    """

    def process_response(self, request, response):
        # X-Frame-Options is already set by XFrameOptionsMiddleware from settings.X_FRAME_OPTIONS.
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        # Legacy XSS filter (ignored by modern browsers; some scanners still expect it.)
        response.headers.setdefault("X-XSS-Protection", "1; mode=block")
        csp = (getattr(settings, "SECURITY_CSP", None) or "").strip()
        if csp and "Content-Security-Policy" not in response:
            response["Content-Security-Policy"] = csp
        return response


class FailedLoginLockoutMiddleware(MiddlewareMixin):
    """Blocks POST to login endpoints when IP is temporarily locked (cache-backed)."""

    def process_request(self, request):
        if request.method != "POST" or not login_paths_match(request.path):
            return None
        ip = get_client_ip(request) or "unknown"
        if cache.get(f"enterprise_login_lock_{ip}"):
            return HttpResponseForbidden(
                "Too many failed login attempts. Please try again later."
            )
        return None


class AdminIPAllowlistMiddleware(MiddlewareMixin):
    """Restricts authenticated admin panel traffic to configured IPs (load-balancer friendly via X-Forwarded-For)."""

    def process_request(self, request):
        allow = getattr(settings, "ENTERPRISE_ADMIN_IP_ALLOWLIST", None) or []
        if not allow:
            return None
        path = request.path or ""
        is_crm_admin = path.startswith("/admin/") or path.startswith("/sales/") or path.startswith("/manager/")
        is_dj_admin = path.startswith("/django-admin/")
        if not (is_crm_admin or is_dj_admin):
            return None
        if path.startswith("/admin/login") or path.startswith("/admin/logout"):
            return None
        if path.startswith("/django-admin/login") or path.startswith("/django-admin/logout"):
            return None
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            return None
        staff_like = (
            getattr(user, "is_admin", lambda: False)()
            or getattr(user, "is_superuser", False)
            or getattr(user, "is_sales_manager", lambda: False)()
            or getattr(user, "is_account_manager", lambda: False)()
        )
        if not staff_like:
            return None
        ip = get_client_ip(request) or ""
        if ip not in allow:
            return HttpResponseForbidden("Admin access is not allowed from this IP address.")
        return None
