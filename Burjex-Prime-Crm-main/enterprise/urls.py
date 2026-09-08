from django.urls import path

from . import views

urlpatterns = [
    path("live/", views.health_live, name="enterprise-health-live"),
    path("ready/", views.health_ready, name="enterprise-health-ready"),
]
