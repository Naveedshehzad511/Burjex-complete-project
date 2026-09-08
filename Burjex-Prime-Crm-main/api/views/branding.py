"""Public mobile/web branding (app name + logos) from CRM System Management."""

from __future__ import annotations

from urllib.parse import urlparse, urlunparse

from django.conf import settings
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from admin_panel.branding_assets import resolve_branding_context
from admin_panel.models import OrganizationProfileSettings
from api.responses import success_response


def _public_base() -> str:
    return (getattr(settings, "SITE_BASE_URL", None) or "").strip().rstrip("/")


def _abs(request, url: str) -> str:
    """Build a phone-reachable absolute media URL (prefer SITE_BASE_URL)."""
    if not url:
        return ""

    base = _public_base()
    parsed = urlparse(url)

    if not parsed.scheme:
        path = url if url.startswith("/") else f"/{url}"
        if base:
            return f"{base}{path}"
        return request.build_absolute_uri(path)

    host = (parsed.hostname or "").lower()
    if base and host in {"127.0.0.1", "localhost", "crm_web", "crm-web"}:
        b = urlparse(base)
        return urlunparse(
            (
                b.scheme or "http",
                b.netloc,
                parsed.path,
                parsed.params,
                parsed.query,
                parsed.fragment,
            )
        )

    return url


def _field_url(field) -> str:
    if not field or not getattr(field, "name", None):
        return ""
    try:
        return field.url or ""
    except (ValueError, AttributeError):
        return ""


class BrandingAPIView(APIView):
    """
    Public branding for the mobile client splash / sign-in / sidebar.

    Source of truth: System Management → Branding
    (company name + app icon / login logo / sidebar logo).
    """

    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        org = None
        try:
            org = OrganizationProfileSettings.get_solo()
        except Exception:
            org = None

        ctx = {}
        try:
            ctx = resolve_branding_context(request) or {}
        except Exception:
            ctx = {}

        app_name = ""
        if org is not None:
            app_name = (
                (getattr(org, "application_name", None) or "").strip()
                or (getattr(org, "company_name", None) or "").strip()
            )
        if not app_name:
            app_name = (ctx.get("crm_company_name") or "").strip() or "Burjex Prime"

        company_logo = _abs(request, _field_url(getattr(org, "logo", None)) if org else "") or _abs(
            request,
            ctx.get("crm_site_logo_url") or "",
        )
        login_logo = _abs(request, _field_url(getattr(org, "login_logo", None)) if org else "") or _abs(
            request,
            ctx.get("crm_user_login_logo_url") or "",
        ) or company_logo
        sidebar_logo = _abs(request, _field_url(getattr(org, "sidebar_logo", None)) if org else "") or _abs(
            request,
            ctx.get("crm_client_portal_logo_url") or "",
        ) or company_logo
        app_icon = _abs(request, _field_url(getattr(org, "app_icon", None)) if org else "") or company_logo

        # Backward-compatible single logo_url (login/splash preference).
        logo_url = login_logo or company_logo or app_icon

        return success_response(
            {
                "app_name": app_name,
                "logo_url": logo_url,
                "app_icon_url": app_icon,
                "login_logo_url": login_logo,
                "sidebar_logo_url": sidebar_logo,
                "primary_color": ctx.get("crm_primary_color") or "#002D58",
            },
            message="Branding retrieved successfully.",
        )
