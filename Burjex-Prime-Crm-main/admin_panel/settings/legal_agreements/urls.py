from django.urls import path

from . import views

urlpatterns = [
    path("", views.legal_agreements_settings_page, name="admin-legal-agreements"),
]

