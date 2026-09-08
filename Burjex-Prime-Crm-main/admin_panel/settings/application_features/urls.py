from django.urls import path

from . import views

urlpatterns = [
    path("", views.application_features_hub, name="admin-settings-application-features"),
    path("dashboard/", views.dashboard_settings, name="admin-dashboard-settings"),
    path("sidebar-ui/", views.sidebar_settings, name="admin-sidebar-settings"),
    path("signup-fields/", views.signup_fields, name="admin-signup-fields-settings"),
    path("email-verification/", views.email_verification, name="admin-email-verification-settings"),
    path("user-settings/", views.user_settings, name="admin-user-settings"),
]

