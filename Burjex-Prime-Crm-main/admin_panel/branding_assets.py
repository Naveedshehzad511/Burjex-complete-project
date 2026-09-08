"""Resolve branding URLs (cache-busted) for admin vs user portals."""

from __future__ import annotations

from .models import (
    AdminAuthBrandingSettings,
    BrandingSettings,
    LoginBrandingSettings,
    OrganizationProfileSettings,
    PortalBrandingSettings,
    SidebarUISettings,
    UserAuthBrandingSettings,
)


def _bust(url: str, version: int) -> str:
    if not url:
        return ""
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}v={version}"


def _file_url(field, version: int) -> str:
    if not field or not getattr(field, "name", None):
        return ""
    try:
        u = field.url
    except (ValueError, AttributeError):
        return ""
    if not u:
        return ""
    return _bust(u, version)


def _cache_version(*objs) -> int:
    t = 1
    for o in objs:
        if not o:
            continue
        try:
            if getattr(o, "updated_at", None):
                t = max(t, int(o.updated_at.timestamp()))
        except Exception:
            pass
    return t


def resolve_branding_context(request) -> dict:
    """
    Build template context keys for logos and favicons.
    Does not require DB migrations to exist (fails soft).
    """
    branding = None
    admin_auth = None
    user_auth = None
    ui = None
    portal = None
    login_lb = None
    try:
        branding = BrandingSettings.get_solo()
    except Exception:
        pass
    try:
        admin_auth = AdminAuthBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        user_auth = UserAuthBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        ui = SidebarUISettings.get_solo()
    except Exception:
        pass
    try:
        portal = PortalBrandingSettings.get_solo()
    except Exception:
        portal = None
    try:
        login_lb = LoginBrandingSettings.get_solo()
    except Exception:
        login_lb = None
    try:
        org = OrganizationProfileSettings.get_solo()
    except Exception:
        org = None

    v = _cache_version(portal, admin_auth, user_auth, login_lb, org)

    path = getattr(request, "path", "") or ""
    p = path.rstrip("/") or "/"
    admin_paths = path.startswith("/admin/")
    user_paths = path.startswith("/user/") or p in (
        "/login",
        "/signup",
        "/register",
        "/forgot-password",
    )

    auth_for_legacy = admin_auth if admin_paths else user_auth
    legacy_brand = _file_url(getattr(auth_for_legacy, "logo", None), v) if auth_for_legacy else ""
    legacy_site = _file_url(getattr(branding, "site_logo", None), v) if branding else ""
    legacy = legacy_brand or legacy_site

    def pu(name: str) -> str:
        if not portal:
            return ""
        return _file_url(getattr(portal, name, None), v)

    admin_logo = pu("admin_logo")
    admin_sidebar = pu("admin_sidebar_logo")
    admin_login = pu("admin_login_logo")
    admin_fav = pu("admin_favicon")

    lb_admin_login = _file_url(getattr(login_lb, "admin_login_logo", None), v) if login_lb else ""
    lb_user_login = _file_url(getattr(login_lb, "user_login_logo", None), v) if login_lb else ""

    user_logo = pu("user_logo")
    user_dash = pu("user_dashboard_logo")
    user_dash_dark = pu("user_dashboard_logo_dark")
    user_login = pu("user_login_logo")
    user_fav = pu("user_favicon")

    sidebar_ui_logo = _file_url(getattr(ui, "sidebar_logo", None), v) if ui else ""
    org_logo = _file_url(getattr(org, "logo", None), v) if org else ""

    crm_site_logo_url = org_logo or legacy

    crm_admin_sidebar_logo_url = org_logo or admin_sidebar or admin_logo or legacy
    crm_admin_header_logo_url = org_logo or admin_logo or admin_sidebar or legacy
    crm_admin_login_logo_url = org_logo or lb_admin_login or admin_login or admin_logo or legacy

    crm_user_login_logo_url = org_logo or lb_user_login or user_login or user_logo or legacy
    crm_client_portal_logo_url = org_logo or user_dash or user_logo or sidebar_ui_logo or legacy
    crm_client_portal_logo_dark_url = user_dash_dark or ""

    crm_active_favicon_url = ""
    if admin_paths:
        crm_active_favicon_url = org_logo or admin_fav or ""
    elif user_paths:
        crm_active_favicon_url = org_logo or user_fav or ""
    else:
        crm_active_favicon_url = org_logo or user_fav or admin_fav or ""

    if org and (org.company_name or "").strip():
        company_name = org.company_name.strip()
    elif admin_paths and admin_auth:
        company_name = admin_auth.company_name
    elif user_auth:
        company_name = user_auth.company_name
    else:
        company_name = "Burjex Prime"

    if admin_paths and admin_auth:
        primary_color = admin_auth.primary_color
        secondary_color = admin_auth.secondary_color
    elif user_auth:
        primary_color = user_auth.primary_color
        secondary_color = user_auth.secondary_color
    else:
        primary_color = "#0B3C5D"
        secondary_color = "#072A42"

    return {
        "crm_branding_cache_v": v,
        "crm_site_logo_url": crm_site_logo_url,
        "crm_admin_sidebar_logo_url": crm_admin_sidebar_logo_url,
        "crm_admin_header_logo_url": crm_admin_header_logo_url,
        "crm_admin_login_logo_url": crm_admin_login_logo_url,
        "crm_admin_favicon_url": admin_fav,
        "crm_user_login_logo_url": crm_user_login_logo_url,
        "crm_client_portal_logo_url": crm_client_portal_logo_url,
        "crm_client_portal_logo_dark_url": crm_client_portal_logo_dark_url,
        "crm_user_favicon_url": user_fav,
        "crm_active_favicon_url": crm_active_favicon_url,
        "crm_company_name": company_name,
        "crm_primary_color": primary_color,
        "crm_secondary_color": secondary_color,
    }


def login_page_context(kind: str, request) -> dict:
    """
    Full-screen login branding: kind is 'admin' or 'user'.
    """
    login_lb = None
    portal = None
    admin_auth = None
    user_auth = None
    branding = None
    try:
        login_lb = LoginBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        portal = PortalBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        admin_auth = AdminAuthBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        user_auth = UserAuthBrandingSettings.get_solo()
    except Exception:
        pass
    try:
        branding = BrandingSettings.get_solo()
    except Exception:
        pass

    try:
        org = OrganizationProfileSettings.get_solo()
    except Exception:
        org = None

    v = _cache_version(portal, admin_auth, user_auth, login_lb, org)

    auth = admin_auth if kind == "admin" else user_auth
    legacy_brand = _file_url(getattr(auth, "logo", None), v) if auth else ""
    legacy_site = _file_url(getattr(branding, "site_logo", None), v) if branding else ""
    legacy = legacy_brand or legacy_site
    org_logo = _file_url(getattr(org, "logo", None), v) if org else ""

    def pu(name: str) -> str:
        if not portal:
            return ""
        return _file_url(getattr(portal, name, None), v)

    if kind == "admin":
        logo = (
            org_logo
            or (_file_url(login_lb.admin_login_logo, v) if login_lb else "")
            or pu("admin_login_logo")
            or pu("admin_logo")
            or legacy
        )
        bg = (
            (_file_url(login_lb.admin_login_background, v) if login_lb else "")
            or (_file_url(getattr(auth, "background_logo", None), v) if auth else "")
        )
        title = (login_lb.admin_login_title or "").strip() if login_lb else ""
        subtitle = (login_lb.admin_login_subtitle or "").strip() if login_lb else ""
        btn = (login_lb.admin_button_color or "#0B3C5D").strip() if login_lb else "#0B3C5D"
        overlay = (login_lb.admin_background_overlay or "rgba(15, 23, 42, 0.55)").strip() if login_lb else "rgba(15, 23, 42, 0.55)"
        if auth and getattr(auth, "button_color", None):
            btn = (auth.button_color or btn).strip()
        if not title:
            title = "Staff Sign In"
        if not subtitle:
            subtitle = "Secure access to your broker CRM console"
    else:
        logo = (
            org_logo
            or (_file_url(login_lb.user_login_logo, v) if login_lb else "")
            or pu("user_login_logo")
            or pu("user_logo")
            or legacy
        )
        bg = (
            (_file_url(login_lb.user_login_background, v) if login_lb else "")
            or (_file_url(getattr(auth, "background_logo", None), v) if auth else "")
        )
        title = (login_lb.user_login_title or "").strip() if login_lb else ""
        subtitle = (login_lb.user_login_subtitle or "").strip() if login_lb else ""
        btn = (login_lb.user_button_color or "#0B3C5D").strip() if login_lb else "#0B3C5D"
        overlay = (login_lb.user_background_overlay or "rgba(15, 23, 42, 0.45)").strip() if login_lb else "rgba(15, 23, 42, 0.45)"
        if auth and getattr(auth, "button_color", None):
            btn = (auth.button_color or btn).strip()
        if not title:
            title = "Welcome back"
        if not subtitle:
            subtitle = "Sign in to your client portal"

    return {
        "login_logo_url": logo,
        "login_background_url": bg,
        "login_title": title,
        "login_subtitle": subtitle,
        "login_button_color": btn,
        "login_overlay": overlay,
    }


def totp_admin_logo_url(request) -> str:
    ctx = resolve_branding_context(request)
    return (
        login_page_context("admin", request).get("login_logo_url")
        or ctx.get("crm_admin_login_logo_url")
        or ctx.get("crm_site_logo_url")
        or ""
    )


def totp_user_logo_url(request) -> str:
    ctx = resolve_branding_context(request)
    return (
        login_page_context("user", request).get("login_logo_url")
        or ctx.get("crm_user_login_logo_url")
        or ctx.get("crm_client_portal_logo_url")
        or ctx.get("crm_site_logo_url")
        or ""
    )
