"""Admin UI for client portal white-label (theme, layout, branding assets)."""

from __future__ import annotations

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db import transaction as db_transaction
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .branding_uploads import MSG_UPLOAD_FAILED, branding_file_error
from .models import PortalBrandingSettings, WhiteLabelProfile
from .views import PORTAL_BRANDING_FILE_FIELDS

WL_USER_PORTAL_FILE_FIELDS = (
    "user_logo",
    "user_favicon",
    "user_login_logo",
    "user_dashboard_logo",
    "user_dashboard_logo_dark",
)


def _active_profile() -> WhiteLabelProfile:
    p = WhiteLabelProfile.get_active_portal_profile()
    if p:
        return p
    return WhiteLabelProfile.objects.order_by("id").first() or WhiteLabelProfile.objects.create(
        name="Default",
        is_active_for_portal=True,
    )


def _wl_subnav(active: str) -> list[dict]:
    return [
        {"key": "hub", "label": "Overview", "url": reverse("admin-white-label-hub")},
        {"key": "theme", "label": "Theme", "url": reverse("admin-white-label-theme")},
        {"key": "branding", "label": "Branding", "url": reverse("admin-white-label-branding")},
        {"key": "layout", "label": "Layout", "url": reverse("admin-white-label-layout")},
        {"key": "profiles", "label": "Brand profiles", "url": reverse("admin-white-label-profiles")},
    ]


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def white_label_hub(request):
    active = _active_profile()
    return render(
        request,
        "admin_panel/white_label/hub.html",
        {"title": "Client portal white label", "wl_nav_active": "hub", "wl_subnav": _wl_subnav("hub"), "profile": active},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def white_label_theme(request):
    profile = _active_profile()
    if request.method == "POST":
        profile.primary_color = (request.POST.get("primary_color") or "").strip()[:32]
        profile.secondary_color = (request.POST.get("secondary_color") or "").strip()[:32]
        profile.sidebar_bg_color = (request.POST.get("sidebar_bg_color") or "").strip()[:32]
        profile.header_bg_color = (request.POST.get("header_bg_color") or "").strip()[:32]
        profile.button_color = (request.POST.get("button_color") or "").strip()[:32]
        profile.content_text_color = (request.POST.get("content_text_color") or "").strip()[:32]
        profile.font_size_preset = (request.POST.get("font_size_preset") or "md").strip()[:8]
        if profile.font_size_preset not in {"sm", "md", "lg"}:
            profile.font_size_preset = "md"
        profile.font_weight_preset = (request.POST.get("font_weight_preset") or "medium").strip()[:16]
        if profile.font_weight_preset not in {"normal", "medium", "bold"}:
            profile.font_weight_preset = "medium"
        profile.save()
        messages.success(request, "Theme settings saved. Client portal updates immediately.")
        return redirect("admin-white-label-theme")

    return render(
        request,
        "admin_panel/white_label/theme.html",
        {
            "title": "Theme settings",
            "profile": profile,
            "wl_nav_active": "theme",
            "wl_subnav": _wl_subnav("theme"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def white_label_layout(request):
    profile = _active_profile()
    if request.method == "POST":
        profile.sidebar_position = (request.POST.get("sidebar_position") or "left").strip()[:8]
        if profile.sidebar_position not in {"left", "right"}:
            profile.sidebar_position = "left"
        for key, field in (
            ("sidebar_width_px", "sidebar_width_px"),
            ("header_height_px", "header_height_px"),
            ("menu_icon_size_px", "menu_icon_size_px"),
            ("border_radius_px", "border_radius_px"),
        ):
            raw = (request.POST.get(key) or "").strip()
            if raw.isdigit():
                setattr(profile, field, max(1, min(600, int(raw))))
            else:
                setattr(profile, field, None)
        profile.save()
        messages.success(request, "Layout settings saved.")
        return redirect("admin-white-label-layout")

    return render(
        request,
        "admin_panel/white_label/layout.html",
        {
            "title": "Layout settings",
            "profile": profile,
            "wl_nav_active": "layout",
            "wl_subnav": _wl_subnav("layout"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def white_label_branding(request):
    profile = _active_profile()
    portal = PortalBrandingSettings.get_solo()

    if request.method == "POST":
        profile.company_name_override = (request.POST.get("company_name_override") or "").strip()[:160]
        profile.footer_text = (request.POST.get("footer_text") or "").strip()[:8000]
        profile.save()

        actions: dict[str, tuple[str, object]] = {}
        errors: list[str] = []
        for name in WL_USER_PORTAL_FILE_FIELDS:
            uploaded = request.FILES.get(name)
            remove = request.POST.get(f"remove_{name}") == "on"
            if uploaded and getattr(uploaded, "name", None):
                err = branding_file_error(uploaded)
                if err:
                    errors.append(err)
                else:
                    actions[name] = ("upload", uploaded)
            elif remove:
                actions[name] = ("remove", None)

        if errors:
            messages.error(request, errors[0])
            return redirect("admin-white-label-branding")

        try:
            with db_transaction.atomic():
                for name, (op, fobj) in actions.items():
                    if name not in PORTAL_BRANDING_FILE_FIELDS:
                        continue
                    field = getattr(portal, name)
                    if op == "remove":
                        if field and field.name:
                            field.delete(save=False)
                        setattr(portal, name, None)
                    else:
                        if field and field.name:
                            field.delete(save=False)
                        setattr(portal, name, fobj)
                if actions:
                    portal.save()
        except Exception:
            messages.error(request, MSG_UPLOAD_FAILED)
            return redirect("admin-white-label-branding")

        messages.success(request, "Branding saved.")
        return redirect("admin-white-label-branding")

    v = int(portal.updated_at.timestamp()) if getattr(portal, "updated_at", None) else 1
    user_rows = []
    specs = (
        {"name": "user_logo", "label": "Client logo", "help": "General fallback for portal."},
        {"name": "user_dashboard_logo", "label": "Sidebar / header logo", "help": "Shown in client portal navigation."},
        {
            "name": "user_dashboard_logo_dark",
            "label": "Sidebar logo (dark variant)",
            "help": "Optional; use for dark sidebars or contrast.",
        },
        {"name": "user_login_logo", "label": "Login page logo", "help": "Sign-in and registration pages."},
        {"name": "user_favicon", "label": "Favicon", "help": "Browser tab on /user/ and public auth pages."},
    )
    for s in specs:
        fld = getattr(portal, s["name"])
        url = ""
        if fld and fld.name:
            try:
                raw = fld.url
                sep = "&" if "?" in raw else "?"
                url = f"{raw}{sep}v={v}"
            except ValueError:
                url = ""
        user_rows.append({**s, "url": url})

    return render(
        request,
        "admin_panel/white_label/branding.html",
        {
            "title": "Branding settings",
            "profile": profile,
            "portal": portal,
            "user_branding_rows": user_rows,
            "wl_nav_active": "branding",
            "wl_subnav": _wl_subnav("branding"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def white_label_profiles(request):
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "activate":
            pid = request.POST.get("profile_id") or ""
            if pid.isdigit():
                p = get_object_or_404(WhiteLabelProfile, pk=int(pid))
                p.is_active_for_portal = True
                p.save()
                messages.success(request, f"Active portal brand set to “{p.name}”.")
        elif action == "create":
            name = (request.POST.get("name") or "").strip() or "New brand"
            p = WhiteLabelProfile.objects.create(name=name, is_active_for_portal=False)
            messages.success(request, f"Created “{p.name}”. Activate it when ready.")
        return redirect("admin-white-label-profiles")

    profiles = list(WhiteLabelProfile.objects.all().order_by("name"))
    return render(
        request,
        "admin_panel/white_label/profiles.html",
        {
            "title": "Brand profiles",
            "profiles": profiles,
            "wl_nav_active": "profiles",
            "wl_subnav": _wl_subnav("profiles"),
        },
    )
