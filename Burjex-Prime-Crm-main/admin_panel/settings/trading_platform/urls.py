from django.urls import path

from . import views

urlpatterns = [
    path("", views.trading_platform_settings, name="admin-trading-platform-settings"),
]

