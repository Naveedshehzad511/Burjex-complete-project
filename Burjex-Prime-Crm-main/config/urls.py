"""
URL configuration for config project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/6.0/topics/http/urls/
"""
from django.contrib import admin
from django.conf import settings
from django.conf.urls.static import static
from django.urls import include, path, re_path
from django.views.generic import RedirectView
from .language_views import set_language_prefix
from marketing.views import visitor_capture_submit
from accounts.views import (
    AdminLoginView,
    UserLoginView,
    admin_logout,
    admin_totp_verify_view,
    client_logout,
    client_signup_view,
    email_verification_sent_view,
    forgot_password_view,
    reset_password_view,
    resend_verification_view,
    user_totp_verify_view,
    verify_email_view,
)
from admin_panel.security_views import maintenance_page
from admin_panel.integrations_views import match2pay_webhook_stub
from btrader_integration.webhook import btrader_webhook

urlpatterns = [
    path("i18n/", include("django.conf.urls.i18n")),
    re_path(r"^(?P<lang_code>en|ur|ar)/$", set_language_prefix, name="set-language-prefix"),
    path("health/", include("enterprise.urls")),
    path("django-admin/", admin.site.urls),
    # Must be before `admin/` include so login/logout are not swallowed by admin_panel.
    path("admin/login/totp/", admin_totp_verify_view, name="admin-totp-verify"),
    path("admin/login/", AdminLoginView.as_view(), name="admin-login"),
    path("admin/login", AdminLoginView.as_view(), name="admin-login-ns"),
    path("admin/logout/", admin_logout, name="admin_logout"),
    path("admin/", include("admin_panel.urls")),
    path("sales/", include("sales_panel.urls")),
    path("manager/", include("manager_panel.urls")),
    # Must be before `user/` include.
    path("user/login/totp/", user_totp_verify_view, name="user-totp-verify"),
    path("user/login/", UserLoginView.as_view(), name="user-login"),
    path("user/login", UserLoginView.as_view(), name="user-login-ns"),
    path("user/", include("user_portal.urls")),
    path("login/", UserLoginView.as_view(), name="client-login"),
    path("login", UserLoginView.as_view(), name="client-login-ns"),
    path("signup/", client_signup_view, name="client-signup"),
    path("signup", client_signup_view, name="client-signup-ns"),
    path("register/", client_signup_view, name="client-register"),
    path("register", client_signup_view, name="client-register-ns"),
    path("forgot-password/", forgot_password_view, name="forgot-password"),
    path("forgot-password", forgot_password_view, name="forgot-password-ns"),
    path("reset-password/<uidb64>/<token>/", reset_password_view, name="reset-password"),
    path("reset-password/<uidb64>/<token>", reset_password_view, name="reset-password-ns"),
    path("verify-email/<str:token>/", verify_email_view, name="verify-email"),
    path("email-verification-sent/", email_verification_sent_view, name="email-verification-sent"),
    path("resend-verification/", resend_verification_view, name="resend-verification"),
    path("logout/", client_logout, name="logout"),
    path("accounts/", include("accounts.urls")),
    path("chat/", include("live_chat.urls")),
    path("maintenance/", maintenance_page, name="maintenance-page"),
    path("visitor-capture/", visitor_capture_submit, name="visitor-capture"),
    path("api/v1/", include("api.urls")),
    path("api/integrations/", include("admin_panel.api_urls")),
    path("api/match2pay/webhook/", match2pay_webhook_stub, name="api-match2pay-webhook"),
    path("api/btrader/webhook/", btrader_webhook, name="api-btrader-webhook"),
    path("email/", include("email_notifications.urls")),
    path("ckeditor5/", include("django_ckeditor_5.urls")),
    path("", RedirectView.as_view(pattern_name="user-dashboard", permanent=False)),
]

# Robust serving of static and media files under Gunicorn/WSGI
from django.views.static import serve
from django.urls import re_path

urlpatterns += [
    re_path(r'^static/(?P<path>.*)$', serve, {'document_root': settings.STATIC_ROOT}),
    re_path(r'^media/(?P<path>.*)$', serve, {'document_root': settings.MEDIA_ROOT}),
]

handler404 = "config.views.page_not_found"
