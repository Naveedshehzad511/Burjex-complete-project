from django.apps import AppConfig


class EmailNotificationsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "email_notifications"
    verbose_name = "Email Notifications"

    def ready(self):
        # Import signal handlers so they connect to Django's signal dispatcher.
        import email_notifications.signals  # noqa: F401
