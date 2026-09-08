"""Propagate company name and logo from branding settings across the project."""

from __future__ import annotations

import os

from django.core.files.base import ContentFile

from admin_panel.models import (
    AdminAuthBrandingSettings,
    BrandingSettings,
    OrganizationProfileSettings,
    PortalBrandingSettings,
    UserAuthBrandingSettings,
    WhiteLabelProfile,
)


def sync_company_name_globally(company_name: str) -> None:
    """Update company name everywhere branding is resolved."""
    name = (company_name or "").strip()
    if not name:
        return

    org = OrganizationProfileSettings.get_solo()
    org.company_name = name
    org.save(update_fields=["company_name", "updated_at"])

    for model_cls in (AdminAuthBrandingSettings, UserAuthBrandingSettings):
        auth = model_cls.get_solo()
        auth.company_name = name
        auth.save(update_fields=["company_name", "updated_at"])

    try:
        wl = WhiteLabelProfile.get_active_portal_profile()
        if wl and (wl.company_name_override or "").strip():
            wl.company_name_override = ""
            wl.save(update_fields=["company_name_override", "updated_at"])
    except Exception:
        pass


def _read_field_bytes(field) -> tuple[bytes, str] | None:
    if not field or not getattr(field, "name", None):
        return None
    try:
        field.open("rb")
        data = field.read()
        field.close()
    except Exception:
        return None
    if not data:
        return None
    return data, os.path.basename(field.name)


def _assign_file_copy(field, data: bytes, filename: str) -> None:
    if field and getattr(field, "name", None):
        try:
            field.delete(save=False)
        except Exception:
            pass
    field.save(filename, ContentFile(data), save=False)


def propagate_logo_globally(source_field) -> None:
    """Copy the canonical logo into portal, auth, and legacy branding stores."""
    payload = _read_field_bytes(source_field)
    if not payload:
        return
    data, filename = payload

    portal = PortalBrandingSettings.get_solo()
    for attr in (
        "admin_logo",
        "admin_sidebar_logo",
        "admin_login_logo",
        "user_logo",
        "user_login_logo",
        "user_dashboard_logo",
    ):
        _assign_file_copy(getattr(portal, attr), data, filename)
    portal.save()

    for model_cls in (AdminAuthBrandingSettings, UserAuthBrandingSettings):
        auth = model_cls.get_solo()
        _assign_file_copy(auth.logo, data, filename)
        auth.save(update_fields=["logo", "updated_at"])

    legacy = BrandingSettings.get_solo()
    _assign_file_copy(legacy.site_logo, data, filename)
    legacy.save(update_fields=["site_logo", "updated_at"])


def clear_global_logos() -> None:
    """Remove logo files from all branding stores."""
    portal = PortalBrandingSettings.get_solo()
    for attr in (
        "admin_logo",
        "admin_sidebar_logo",
        "admin_login_logo",
        "user_logo",
        "user_login_logo",
        "user_dashboard_logo",
        "user_dashboard_logo_dark",
    ):
        field = getattr(portal, attr)
        if field and field.name:
            field.delete(save=False)
            setattr(portal, attr, None)
    portal.save()

    for model_cls in (AdminAuthBrandingSettings, UserAuthBrandingSettings):
        auth = model_cls.get_solo()
        if auth.logo and auth.logo.name:
            auth.logo.delete(save=False)
            auth.logo = None
            auth.save(update_fields=["logo", "updated_at"])

    legacy = BrandingSettings.get_solo()
    if legacy.site_logo and legacy.site_logo.name:
        legacy.site_logo.delete(save=False)
        legacy.site_logo = None
        legacy.save(update_fields=["site_logo", "updated_at"])
