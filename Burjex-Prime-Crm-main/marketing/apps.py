from django.apps import AppConfig


class MarketingConfig(AppConfig):
    name = "marketing"
    default_auto_field = "django.db.models.BigAutoField"

    def ready(self) -> None:
        from . import signals  # noqa: F401
