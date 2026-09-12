from .branding_assets import resolve_branding_context
from .models import (
    AdminAuthBrandingSettings,
    DashboardSettings,
    MatchTraderSettings,
    SidebarUISettings,
    SocialLoginSettings,
    SupportIntegration,
    SupportSettings,
    TradingPlatformIntegration,
    UserAuthBrandingSettings,
    LegalAgreementSettings,
    LegalDocument,
    OrganizationProfileSettings,
    LegalAgreementsSettings,
    TradingPlatformSettings,
)
from .services.portal_theme import safe_build_portal_theme

# Admin + Sales shell: full topbar (greeting, notify, profile) only on main dashboard URLs.
_CRM_SHELL_TOPBAR_DASHBOARD_URL_NAMES = frozenset(
    {
        "admin-dashboard",
        "admin-dashboard-ns",
        "admin-dashboard-home",
        "sales-dashboard",
        "sales-dashboard-ns",
        "manager-dashboard",
        "manager-dashboard-ns",
    }
)


def crm_shell_layout_context(request):
    path = getattr(request, "path", "") or ""
    if not (path.startswith("/admin") or path.startswith("/sales") or path.startswith("/manager")):
        return {}
    rm = getattr(request, "resolver_match", None)
    un = getattr(rm, "url_name", None) if rm else None
    show = bool(un and un in _CRM_SHELL_TOPBAR_DASHBOARD_URL_NAMES)
    return {"crm_show_shell_topbar": show}


def crm_sales_manager_minimal_admin_nav(request):
    """
    Sales managers may open read-only CRM org list URLs under /admin/crm/org/.
    Hide the full admin sidebar so they only see return + CRM links (no duplicate admin menus).
    """
    user = getattr(request, "user", None)
    if not user or not user.is_authenticated or not user.is_sales_manager():
        return {}
    p = (getattr(request, "path", "") or "").rstrip("/") or "/"
    if p in {"/admin/crm/org/departments", "/admin/crm/org/sales-managers"}:
        return {"crm_sales_manager_minimal_admin_nav": True}
    return {}


def dashboard_settings_context(request):
    try:
        settings_obj = DashboardSettings.get_solo()
    except Exception:
        settings_obj = None
    return {"crm_dashboard_settings": settings_obj}


def branding_and_sidebar_ui_context(request):
    try:
        ui = SidebarUISettings.get_solo()
    except Exception:
        ui = None
    out = resolve_branding_context(request)
    out["crm_sidebar_ui"] = ui
    path = getattr(request, "path", "") or ""
    public_user_auth_paths = {
        "/login",
        "/login/",
        "/signup",
        "/signup/",
        "/register",
        "/register/",
        "/forgot-password",
        "/forgot-password/",
    }
    if path.startswith("/user/") or path in public_user_auth_paths:
        theme = safe_build_portal_theme()
        out["crm_portal_theme"] = theme
        out["crm_sidebar_position"] = theme.get("sidebar_position", "left")
        wl = theme.get("wl")
        out["crm_portal_footer_text"] = (wl.footer_text or "").strip() if wl else ""
    return out


def branding(request):
    """Active `branding` for the request path: admin CRM vs client/public."""
    path = request.path or ""
    try:
        user_auth = UserAuthBrandingSettings.get_solo()
    except Exception:
        user_auth = None
    try:
        admin_auth = AdminAuthBrandingSettings.get_solo()
    except Exception:
        admin_auth = None

    if path.startswith("/admin/"):
        active = admin_auth
    else:
        active = user_auth

    return {
        "branding": active,
        "user_auth_branding": user_auth,
        "admin_auth_branding": admin_auth,
    }


def trading_platforms_public_context(request):
    """Expose enabled trading integrations to the client portal (no secrets)."""
    path = getattr(request, "path", "") or ""
    if not path.startswith("/user/"):
        return {}
    try:
        platforms = []
        for row in TradingPlatformIntegration.objects.filter(enabled=True).order_by("platform"):
            if row.platform == TradingPlatformIntegration.Platform.MATCH_TRADER:
                mt = MatchTraderSettings.get_solo()
                if not mt.is_active:
                    continue
            badge, badge_label = row.status_badge()
            platforms.append(
                {
                    "slug": row.url_slug(),
                    "label": row.get_platform_display(),
                    "enabled": row.enabled,
                    "server_name": row.server_name,
                    "api_server_url": row.api_server_url,
                    "status_message": row.status_message,
                    "quick_notes": row.quick_notes,
                    "badge": badge,
                    "badge_label": badge_label,
                    "last_test_ok": row.last_test_ok,
                }
            )
        return {"crm_trading_platforms": platforms}
    except Exception:
        return {"crm_trading_platforms": []}


def organization_public_context(_request):
    try:
        org = OrganizationProfileSettings.get_solo()
    except Exception:
        org = None
    return {
        "crm_org_profile": org,
        "crm_company_name": (org.company_name if org and org.company_name else "Burjex Prime"),
        "crm_support_email": (org.support_email if org else ""),
        "crm_company_phone": (org.primary_phone if org else ""),
        "crm_company_address": (org.registered_address if org else ""),
        "crm_company_license": (org.business_license if org else ""),
    }


def legal_agreements_public_context(_request):
    try:
        legal = LegalAgreementSettings.get_solo()
        custom_docs = list(
            LegalDocument.objects.filter(
                category=LegalDocument.Category.CUSTOM,
                is_active=True,
            ).order_by("order", "id")
        )
    except Exception:
        try:
            legal = LegalAgreementsSettings.get_solo()
            custom_docs = list(legal.custom_documents.filter(is_active=True).order_by("-created_at"))
        except Exception:
            legal = None
            custom_docs = []
    return {"crm_legal_settings": legal, "crm_legal_custom_docs": custom_docs}


def trading_platform_public_context(_request):
    try:
        row = TradingPlatformSettings.get_solo()
    except Exception:
        row = None
    return {"crm_trading_platform": row}


def portal_company_override_context(request):
    """After organization profile, apply white-label company name override for /user/."""
    path = getattr(request, "path", "") or ""
    if not path.startswith("/user/"):
        return {}
    try:
        theme = safe_build_portal_theme()
    except Exception:
        return {}
    try:
        org = OrganizationProfileSettings.get_solo()
    except Exception:
        org = None
    if org and (org.company_name or "").strip():
        return {}
    wl = theme.get("wl")
    if wl and (wl.company_name_override or "").strip():
        return {"crm_company_name": wl.company_name_override.strip()}
    return {}


def support_public_context(request):
    path = getattr(request, "path", "") or ""
    if not path.startswith("/user/"):
        return {}
    try:
        # Portal renders only one active support integration. The admin save flow
        # also enforces this, but this keeps old database data from leaking to users.
        active_row = SupportIntegration.objects.filter(enabled=True, status="ACTIVE").order_by("-updated_at", "integration_type").first()
        rows = [active_row] if active_row else []
        settings = SupportSettings.get_solo()
    except Exception:
        rows = []
        settings = None
    floating_icon = ""
    for row in rows:
        # Legacy custom icon support is kept for compatibility; the current
        # WhatsApp portal button uses the built-in icon in the template.
        val = getattr(row, "chat_bubble_icon", "")
        if row.integration_type == "WHATSAPP_DIRECT" and (val or "").strip():
            floating_icon = val.strip()
            break
    if not floating_icon and settings and (settings.floating_icon or "").strip():
        floating_icon = settings.floating_icon.strip()
    return {
        "crm_support_integrations": rows,
        "crm_support_settings": settings,
        "crm_support_floating_icon": floating_icon,
    }


def social_login_context(request):
    """Google / Apple buttons on client login and signup pages."""
    try:
        obj = SocialLoginSettings.get_solo()
    except Exception:
        return {"social_login": None}
    return {"social_login": obj}
