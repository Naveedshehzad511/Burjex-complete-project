from django.urls import path

from . import views

urlpatterns = [
    path("", views.user_portal_theme_settings, name="admin-user-portal-theme"),
]
