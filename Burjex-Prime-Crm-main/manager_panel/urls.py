from django.urls import path

from . import views

urlpatterns = [
    path("dashboard/", views.manager_dashboard, name="manager-dashboard"),
    path("dashboard", views.manager_dashboard, name="manager-dashboard-ns"),
    path("api/dashboard/", views.manager_dashboard_api, name="manager-dashboard-api"),
]
