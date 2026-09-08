from django.urls import path

from . import views

urlpatterns = [
    path("", views.branding_settings, name="admin-branding-logo"),
]

