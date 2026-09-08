"""Resolved client portal theme (white-label profile + fallbacks)."""

from __future__ import annotations

from typing import Any

from admin_panel.models import (
    SidebarUISettings,
    UserAuthBrandingSettings,
    UserPortalThemeSettings,
    WhiteLabelProfile,
)

ADMIN_PANEL_DEFAULT_PRIMARY = "#0B3C5D"
ADMIN_PANEL_DEFAULT_SECONDARY = "#072A42"

FONT_PRESETS: dict[str, dict[str, int]] = {
    "sm": {"body": 13, "h1": 20, "h2": 17, "nav": 14, "subnav": 12, "logo_text": 17, "btn": 13},
    "md": {"body": 14, "h1": 22, "h2": 18, "nav": 15, "subnav": 13, "logo_text": 18, "btn": 14},
    "lg": {"body": 15, "h1": 24, "h2": 20, "nav": 16, "subnav": 14, "logo_text": 19, "btn": 15},
}

WEIGHT_PRESETS: dict[str, int] = {
    "normal": 400,
    "medium": 500,
    "bold": 600,
}


def _pick(first: str, second: str, default: str) -> str:
    a = (first or "").strip()
    if a:
        return a
    b = (second or "").strip()
    if b:
        return b
    return default


def _theme_value(user_theme: UserPortalThemeSettings | None, name: str, fallback: Any) -> Any:
    if not user_theme:
        return fallback
    value = getattr(user_theme, name, None)
    if isinstance(value, str):
        value = value.strip()
    return value if value not in ("", None) else fallback


def build_resolved_portal_theme() -> dict[str, Any]:
    """
    Merge active WhiteLabelProfile over UserAuthBrandingSettings + SidebarUISettings.
    Used by the client portal (/user/) context processor.
    """
    try:
        wl = WhiteLabelProfile.get_active_portal_profile()
    except Exception:
        wl = None
    try:
        ui = SidebarUISettings.get_solo()
    except Exception:
        ui = None
    try:
        ua = UserAuthBrandingSettings.get_solo()
    except Exception:
        ua = None
    try:
        user_theme = UserPortalThemeSettings.get_solo()
    except Exception:
        user_theme = None

    preset_key = (wl.font_size_preset if wl else "md") or "md"
    if preset_key not in FONT_PRESETS:
        preset_key = "md"
    typo = FONT_PRESETS[preset_key]

    wkey = (wl.font_weight_preset if wl else "medium") or "medium"
    if wkey not in WEIGHT_PRESETS:
        wkey = "medium"
    nav_weight = WEIGHT_PRESETS[wkey]

    # Sidebar menu: keep readable baseline (15px+) unless explicitly larger.
    sidebar_px = typo["nav"]
    if ui and getattr(ui, "font_size", None):
        if not wl:
            sidebar_px = int(ui.font_size)
        else:
            # Active profile: preset scales menu; still respect explicit sidebar width from ui
            sidebar_px = typo["nav"]

    primary = _pick(wl.primary_color if wl else "", ua.primary_color if ua else "", ADMIN_PANEL_DEFAULT_PRIMARY)
    secondary = _pick(wl.secondary_color if wl else "", ua.secondary_color if ua else "", ADMIN_PANEL_DEFAULT_SECONDARY)
    button = _pick(wl.button_color if wl else "", ua.button_color if ua else "", primary)

    theme_configured = bool(user_theme and user_theme.is_configured)
    light_primary = _theme_value(user_theme, "light_primary_color", primary)
    dark_primary = _theme_value(user_theme, "dark_primary_color", ADMIN_PANEL_DEFAULT_PRIMARY)
    sidebar_bg = _theme_value(user_theme, "sidebar_bg_color", _pick(wl.sidebar_bg_color if wl else "", "", "#ffffff"))
    sidebar_text = _theme_value(user_theme, "sidebar_text_color", "#102033")
    sidebar_hover = _theme_value(user_theme, "sidebar_hover_color", "#f4f7fb")
    sidebar_active = _theme_value(user_theme, "sidebar_active_color", light_primary)
    header_bg = _theme_value(user_theme, "topbar_bg_color", _pick(wl.header_bg_color if wl else "", "", "#ffffff"))
    content_text = _theme_value(user_theme, "text_color", _pick(wl.content_text_color if wl else "", "", "#0f172a"))
    button = _theme_value(user_theme, "button_color", button)
    topbar_border = _theme_value(user_theme, "topbar_border_color", "#e2e8f0")
    topbar_title = _theme_value(user_theme, "topbar_title_color", content_text)
    button_text = _theme_value(user_theme, "button_text_color", "#ffffff")
    button_hover = _theme_value(user_theme, "button_hover_color", button)
    card_bg = _theme_value(user_theme, "card_bg_color", "#ffffff")
    card_border = _theme_value(user_theme, "card_border_color", "#e2e8f0")
    card_shadow = _theme_value(user_theme, "card_shadow", "0 4px 14px rgba(15, 23, 42, 0.05)")
    page_bg = _theme_value(user_theme, "page_bg_color", "#ffffff")
    muted_text = _theme_value(user_theme, "muted_text_color", "#64748b")
    mobile_button = _theme_value(user_theme, "mobile_button_color", button)
    mobile_button_text = _theme_value(user_theme, "mobile_button_text_color", "#ffffff")
    table_header = _theme_value(user_theme, "table_header_bg_color", "#f8fafc")
    table_hover = _theme_value(user_theme, "table_row_hover_color", "rgba(15, 23, 42, 0.02)")

    dark_sidebar_bg = _theme_value(user_theme, "dark_sidebar_bg_color", "#0b1220")
    dark_sidebar_text = _theme_value(user_theme, "dark_sidebar_text_color", "#e8eef7")
    dark_sidebar_hover = _theme_value(user_theme, "dark_sidebar_hover_color", "#111c2e")
    dark_sidebar_active = _theme_value(user_theme, "dark_sidebar_active_color", dark_primary)
    dark_button = _theme_value(user_theme, "dark_button_color", dark_primary)
    dark_button_text = _theme_value(user_theme, "dark_button_text_color", "#ffffff")
    dark_button_hover = _theme_value(user_theme, "dark_button_hover_color", dark_button)
    dark_page_bg = _theme_value(user_theme, "dark_page_bg_color", "#0b1220")
    dark_card_bg = _theme_value(user_theme, "dark_card_bg_color", "#111c2e")
    dark_card_border = _theme_value(user_theme, "dark_card_border_color", "#263246")
    dark_text = _theme_value(user_theme, "dark_text_color", "#e8eef7")
    dark_muted = _theme_value(user_theme, "dark_muted_text_color", "#a8b4c7")
    dark_topbar_bg = _theme_value(user_theme, "dark_topbar_bg_color", "#0b1220")
    dark_topbar_border = _theme_value(user_theme, "dark_topbar_border_color", "#263246")
    dark_topbar_title = _theme_value(user_theme, "dark_topbar_title_color", dark_text)
    dark_table_header = _theme_value(user_theme, "dark_table_header_bg_color", "#162840")
    dark_table_hover = _theme_value(user_theme, "dark_table_row_hover_color", "rgba(255, 255, 255, 0.04)")
    dark_mobile_button = _theme_value(user_theme, "dark_mobile_button_color", dark_button)
    dark_mobile_button_text = _theme_value(user_theme, "dark_mobile_button_text_color", "#ffffff")

    sidebar_px = max(15, int(sidebar_px))
    logo_text_px = max(18, int(typo["logo_text"]))

    sidebar_width = int(_theme_value(user_theme, "sidebar_width_px", int(wl.sidebar_width_px) if wl and wl.sidebar_width_px else (int(ui.sidebar_width) if ui and ui.sidebar_width else 272)))
    logo_size = int(_theme_value(user_theme, "logo_size_px", int(ui.logo_size_px) if ui and ui.logo_size_px else 40))
    header_h = int(wl.header_height_px) if wl and wl.header_height_px else 56
    icon_sz = int(wl.menu_icon_size_px) if wl and wl.menu_icon_size_px else 22
    radius = int(_theme_value(user_theme, "border_radius_px", int(wl.border_radius_px) if wl and wl.border_radius_px else 10))
    sidebar_pos = (wl.sidebar_position if wl else WhiteLabelProfile.SidebarPosition.LEFT) or "left"
    if sidebar_pos not in {"left", "right"}:
        sidebar_pos = "left"

    font_family = _theme_value(user_theme, "font_family", (ui.font_family if ui else "") or "Inter, system-ui, sans-serif")
    auth_font = (ua.font_style if ua else "") or font_family
    auth_font = _theme_value(user_theme, "font_family", auth_font)

    body_font_px = int(_theme_value(user_theme, "body_font_size_px", typo["body"]))
    h1_font_px = int(_theme_value(user_theme, "h1_font_size_px", typo["h1"]))
    h2_font_px = int(_theme_value(user_theme, "h2_font_size_px", typo["h2"]))

    return {
        "wl": wl,
        "primary_color": primary,
        "secondary_color": secondary,
        "button_color": button,
        "sidebar_bg": sidebar_bg,
        "sidebar_text": sidebar_text,
        "sidebar_hover": sidebar_hover,
        "sidebar_active": sidebar_active,
        "header_bg": header_bg,
        "content_text": content_text,
        "topbar_border_color": topbar_border,
        "topbar_title_color": topbar_title,
        "button_text_color": button_text,
        "button_hover_color": button_hover,
        "card_bg_color": card_bg,
        "card_border_color": card_border,
        "card_shadow": card_shadow,
        "page_bg_color": page_bg,
        "muted_text_color": muted_text,
        "mobile_button_color": mobile_button,
        "mobile_button_text_color": mobile_button_text,
        "table_header_bg_color": table_header,
        "table_row_hover_color": table_hover,
        "dark_page_bg_color": dark_page_bg,
        "dark_text_color": dark_text,
        "dark_muted_text_color": dark_muted,
        "dark_sidebar_bg_color": dark_sidebar_bg,
        "dark_sidebar_text_color": dark_sidebar_text,
        "dark_sidebar_hover_color": dark_sidebar_hover,
        "dark_sidebar_active_color": dark_sidebar_active,
        "dark_topbar_bg_color": dark_topbar_bg,
        "dark_topbar_border_color": dark_topbar_border,
        "dark_topbar_title_color": dark_topbar_title,
        "dark_button_color": dark_button,
        "dark_button_text_color": dark_button_text,
        "dark_button_hover_color": dark_button_hover,
        "dark_card_bg_color": dark_card_bg,
        "dark_card_border_color": dark_card_border,
        "dark_table_header_bg_color": dark_table_header,
        "dark_table_row_hover_color": dark_table_hover,
        "dark_mobile_button_color": dark_mobile_button,
        "dark_mobile_button_text_color": dark_mobile_button_text,
        "sidebar_width_px": sidebar_width,
        "sidebar_position": sidebar_pos,
        "header_height_px": header_h,
        "menu_icon_size_px": icon_sz,
        "border_radius_px": radius,
        "logo_size_px": logo_size,
        "sidebar_font_size_px": sidebar_px,
        "sidebar_font_weight": nav_weight,
        "subnav_font_size_px": typo["subnav"],
        "body_font_size_px": body_font_px,
        "h1_font_size_px": h1_font_px,
        "h2_font_size_px": h2_font_px,
        "logo_text_size_px": logo_text_px,
        "button_font_size_px": typo["btn"],
        "body_font_weight": 400,
        "heading_font_weight": 600,
        "font_family": auth_font,
        "sidebar_font_family": font_family,
        "animation_enabled": bool(ui.animation_enabled) if ui else True,
        "light_primary_color": light_primary,
        "dark_primary_color": dark_primary,
        "user_theme_configured": theme_configured,
        "admin_default_primary": ADMIN_PANEL_DEFAULT_PRIMARY,
    }


def safe_build_portal_theme() -> dict[str, Any]:
    """Never raises; used by context processor before migrations or on DB errors."""
    try:
        return build_resolved_portal_theme()
    except Exception:
        typo = FONT_PRESETS["md"]
        return {
            "wl": None,
            "primary_color": "#0B3C5D",
            "secondary_color": "#072A42",
            "button_color": "#0B3C5D",
            "sidebar_bg": "#ffffff",
            "sidebar_text": "#102033",
            "sidebar_hover": "#f4f7fb",
            "sidebar_active": "#0B3C5D",
            "header_bg": "#ffffff",
            "content_text": "#0f172a",
            "topbar_border_color": "#e2e8f0",
            "topbar_title_color": "#0f172a",
            "button_text_color": "#ffffff",
            "button_hover_color": "#0B3C5D",
            "card_bg_color": "#ffffff",
            "card_border_color": "#e2e8f0",
            "card_shadow": "0 4px 14px rgba(15, 23, 42, 0.05)",
            "page_bg_color": "#ffffff",
            "muted_text_color": "#64748b",
            "mobile_button_color": "#0B3C5D",
            "mobile_button_text_color": "#ffffff",
            "table_header_bg_color": "#f8fafc",
            "table_row_hover_color": "rgba(15, 23, 42, 0.02)",
            "dark_page_bg_color": "#0b1220",
            "dark_text_color": "#e8eef7",
            "dark_muted_text_color": "#a8b4c7",
            "dark_sidebar_bg_color": "#0b1220",
            "dark_sidebar_text_color": "#e8eef7",
            "dark_sidebar_hover_color": "#111c2e",
            "dark_sidebar_active_color": "#0B3C5D",
            "dark_topbar_bg_color": "#0b1220",
            "dark_topbar_border_color": "#263246",
            "dark_topbar_title_color": "#e2e8f4",
            "dark_button_color": "#0B3C5D",
            "dark_button_text_color": "#ffffff",
            "dark_button_hover_color": "#0B3C5D",
            "dark_card_bg_color": "#111c2e",
            "dark_card_border_color": "#263246",
            "dark_table_header_bg_color": "#162840",
            "dark_table_row_hover_color": "rgba(255, 255, 255, 0.04)",
            "dark_mobile_button_color": "#0B3C5D",
            "dark_mobile_button_text_color": "#ffffff",
            "sidebar_width_px": 272,
            "sidebar_position": "left",
            "header_height_px": 56,
            "menu_icon_size_px": 22,
            "border_radius_px": 10,
            "logo_size_px": 40,
            "sidebar_font_size_px": typo["nav"],
            "sidebar_font_weight": WEIGHT_PRESETS["medium"],
            "subnav_font_size_px": typo["subnav"],
            "body_font_size_px": typo["body"],
            "h1_font_size_px": typo["h1"],
            "h2_font_size_px": typo["h2"],
            "logo_text_size_px": max(18, int(typo["logo_text"])),
            "button_font_size_px": typo["btn"],
            "body_font_weight": 400,
            "heading_font_weight": 600,
            "font_family": "Inter, system-ui, sans-serif",
            "sidebar_font_family": "Inter, system-ui, sans-serif",
            "animation_enabled": True,
            "light_primary_color": ADMIN_PANEL_DEFAULT_PRIMARY,
            "dark_primary_color": ADMIN_PANEL_DEFAULT_PRIMARY,
            "user_theme_configured": False,
            "admin_default_primary": ADMIN_PANEL_DEFAULT_PRIMARY,
        }
