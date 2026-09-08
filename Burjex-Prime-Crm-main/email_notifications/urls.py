"""URL patterns for email_notifications app."""

from django.urls import path

from . import views

app_name = "email_notifications"

urlpatterns = [
    path(
        "track/<uuid:log_id>/pixel.png",
        views.tracking_pixel,
        name="tracking-pixel",
    ),
]
