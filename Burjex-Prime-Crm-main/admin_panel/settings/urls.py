from django.urls import include, path

urlpatterns = [
    path("trading-platform/", include("admin_panel.settings.trading_platform.urls")),
    path("legal-agreements/", include("admin_panel.settings.legal_agreements.urls")),
    path("branding/", include("admin_panel.settings.branding.urls")),
    path("user-portal-theme/", include("admin_panel.settings.user_portal_theme.urls")),
]

