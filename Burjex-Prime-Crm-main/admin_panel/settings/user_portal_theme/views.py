from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.models import UserPortalThemeSettings


ADMIN_DEFAULT_THEME = {
    "light_primary_color": "#0B3C5D",
    "dark_primary_color": "#0B3C5D",
    "page_bg_color": "#FFFFFF",
    "text_color": "#0F172A",
    "muted_text_color": "#64748B",
    "sidebar_bg_color": "#FFFFFF",
    "sidebar_text_color": "#102033",
    "sidebar_hover_color": "#F4F7FB",
    "sidebar_active_color": "#0B3C5D",
    "topbar_bg_color": "#FFFFFF",
    "topbar_border_color": "#E2E8F0",
    "topbar_title_color": "#0F172A",
    "button_color": "#0B3C5D",
    "button_text_color": "#FFFFFF",
    "button_hover_color": "#0F5278",
    "card_bg_color": "#FFFFFF",
    "card_border_color": "#E2E8F0",
    "card_shadow": "0 4px 14px rgba(15, 23, 42, 0.05)",
    "mobile_button_color": "#0B3C5D",
    "mobile_button_text_color": "#FFFFFF",
    "table_header_bg_color": "#F8FAFC",
    "table_row_hover_color": "rgba(15, 23, 42, 0.02)",
    "dark_page_bg_color": "#0B1220",
    "dark_text_color": "#E8EEF7",
    "dark_muted_text_color": "#A8B4C7",
    "dark_sidebar_bg_color": "#0B1220",
    "dark_sidebar_text_color": "#E8EEF7",
    "dark_sidebar_hover_color": "#111C2E",
    "dark_sidebar_active_color": "#0B3C5D",
    "dark_topbar_bg_color": "#0B1220",
    "dark_topbar_border_color": "#263246",
    "dark_topbar_title_color": "#E2E8F4",
    "dark_button_color": "#0B3C5D",
    "dark_button_text_color": "#FFFFFF",
    "dark_button_hover_color": "#0F5278",
    "dark_card_bg_color": "#111C2E",
    "dark_card_border_color": "#263246",
    "dark_table_header_bg_color": "#162840",
    "dark_table_row_hover_color": "rgba(255, 255, 255, 0.04)",
    "dark_mobile_button_color": "#0B3C5D",
    "dark_mobile_button_text_color": "#FFFFFF",
    "font_family": "Inter, system-ui, sans-serif",
    "sidebar_width_px": 272,
    "logo_size_px": 40,
    "border_radius_px": 10,
    "body_font_size_px": 14,
    "h1_font_size_px": 22,
    "h2_font_size_px": 18,
}


def _normalize_hex(value: str) -> str:
    v = (value or "").strip()
    if not v:
        return ""
    if not v.startswith("#"):
        v = f"#{v}"
    if len(v) not in (4, 7):
        return ""
    return v.upper()


def _clean_css(value: str, max_len: int = 160) -> str:
    v = (value or "").strip()
    if any(x in v for x in (";", "{", "}", "<", ">")):
        return ""
    return v[:max_len]


def _normalize_int(value: str, min_value: int, max_value: int) -> int | None:
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    return max(min_value, min(max_value, n))


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def user_portal_theme_settings(request):
    theme = UserPortalThemeSettings.get_solo()

    if request.method == "POST":
        color_fields = [
            "light_primary_color", "dark_primary_color", "dark_page_bg_color", "dark_text_color",
            "dark_muted_text_color", "dark_sidebar_bg_color", "dark_sidebar_text_color",
            "dark_sidebar_hover_color", "dark_sidebar_active_color", "dark_topbar_bg_color",
            "dark_topbar_border_color", "dark_topbar_title_color", "dark_button_color",
            "dark_button_text_color", "dark_button_hover_color", "dark_card_bg_color",
            "dark_card_border_color", "dark_table_header_bg_color", "dark_mobile_button_color",
            "dark_mobile_button_text_color", "sidebar_bg_color", "sidebar_text_color",
            "sidebar_hover_color", "sidebar_active_color", "topbar_bg_color", "topbar_border_color",
            "topbar_title_color", "button_color", "button_text_color", "button_hover_color",
            "card_bg_color", "card_border_color", "page_bg_color", "text_color", "muted_text_color",
            "mobile_button_color", "mobile_button_text_color", "table_header_bg_color",
        ]
        css_fields = ["table_row_hover_color", "dark_table_row_hover_color", "card_shadow", "font_family"]
        int_fields = {
            "sidebar_width_px": (220, 360),
            "logo_size_px": (24, 72),
            "border_radius_px": (0, 24),
            "body_font_size_px": (12, 18),
            "h1_font_size_px": (18, 34),
            "h2_font_size_px": (15, 28),
        }
        update_fields = ["updated_at"]
        if request.POST.get("theme_action") == "admin_defaults":
            for field, value in ADMIN_DEFAULT_THEME.items():
                setattr(theme, field, value)
                update_fields.append(field)
            theme.save(update_fields=update_fields)
            messages.success(request, "Admin default colours applied to the user portal theme.")
            return redirect("admin-user-portal-theme")
        for field in color_fields:
            setattr(theme, field, _normalize_hex(request.POST.get(field)))
            update_fields.append(field)
        for field in css_fields:
            setattr(theme, field, _clean_css(request.POST.get(field)))
            update_fields.append(field)
        for field, limits in int_fields.items():
            setattr(theme, field, _normalize_int(request.POST.get(field), *limits))
            update_fields.append(field)
        theme.save(update_fields=update_fields)
        messages.success(request, "User portal theme saved.")
        return redirect("admin-user-portal-theme")

    return render(
        request,
        "admin_panel/user_portal_theme_settings.html",
        {
            "theme": theme,
            "default_light": "#0B3C5D",
            "default_dark": "#0B3C5D",
        },
    )
