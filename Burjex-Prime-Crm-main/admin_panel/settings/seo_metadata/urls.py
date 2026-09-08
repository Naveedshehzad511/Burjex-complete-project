from django.urls import path

from . import views

urlpatterns = [
    path("", views.seo_metadata_settings, name="admin-settings-seo-metadata"),
]

