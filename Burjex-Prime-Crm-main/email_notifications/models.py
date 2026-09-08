"""email_notifications models: SMTP settings, notification templates, and send logs."""

from __future__ import annotations

import uuid

from django.conf import settings
from django.db import models
from django.utils import timezone
from solo.models import SingletonModel

from .encryption import decrypt_value, encrypt_value


# ---------------------------------------------------------------------------
# 1. EmailNotificationSettings (Singleton — primary SMTP config)
# ---------------------------------------------------------------------------

class EmailNotificationSettings(SingletonModel):
    """
    Primary SMTP configuration for the CRM.
    Password is stored Fernet-encrypted using the project SECRET_KEY.
    Falls back to environment variables when fields are blank.
    """

    class EncryptionType(models.TextChoices):
        NONE = "NONE", "None"
        SSL = "SSL", "SSL"
        TLS = "TLS", "TLS"

    smtp_host = models.CharField(
        max_length=255,
        blank=True,
        default="",
        help_text="SMTP server hostname (e.g. smtp.gmail.com).",
    )
    smtp_port = models.PositiveIntegerField(
        default=587,
        help_text="SMTP port (587 for TLS, 465 for SSL, 25 for none).",
    )
    smtp_username = models.CharField(
        max_length=255,
        blank=True,
        default="",
    )
    smtp_password_encrypted = models.TextField(
        blank=True,
        default="",
        help_text="Fernet-encrypted SMTP password. Use set_password() / get_password().",
    )
    encryption_type = models.CharField(
        max_length=4,
        choices=EncryptionType.choices,
        default=EncryptionType.TLS,
    )
    from_email = models.EmailField(
        blank=True,
        default="",
        help_text='Sender email address (the "From" field).',
    )
    from_name = models.CharField(
        max_length=120,
        blank=True,
        default="",
        help_text='Display name for outgoing emails (e.g. "Burjex Prime").',
    )
    is_active = models.BooleanField(
        default=True,
        help_text="Master switch: disable to stop all outgoing notification emails.",
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Email notification settings"
        verbose_name_plural = "Email notification settings"

    def __str__(self) -> str:
        return "Email Notification Settings"

    # --- Encrypted password helpers ---

    def set_password(self, plain_password: str) -> None:
        self.smtp_password_encrypted = encrypt_value(plain_password)

    def get_password(self) -> str:
        return decrypt_value(self.smtp_password_encrypted)

    @property
    def use_tls(self) -> bool:
        return self.encryption_type == self.EncryptionType.TLS

    @property
    def use_ssl(self) -> bool:
        return self.encryption_type == self.EncryptionType.SSL

    @property
    def formatted_from_email(self) -> str:
        """Return 'Name <email>' when both are set."""
        if self.from_name and self.from_email:
            return f"{self.from_name} <{self.from_email}>"
        return self.from_email or "no-reply@example.com"


# ---------------------------------------------------------------------------
# 2. NotificationTemplate
# ---------------------------------------------------------------------------

class NotificationTemplate(models.Model):
    """Admin-editable HTML email templates keyed by event."""

    class Category(models.TextChoices):
        AUTH = "AUTH", "Authentication"
        TRADING = "TRADING", "Trading"
        IB = "IB", "Introducing Broker"
        SUPPORT = "SUPPORT", "Support"
        MARKETING = "MARKETING", "Marketing"

    name = models.CharField(max_length=120)
    subject = models.CharField(
        max_length=255,
        help_text="Supports {{variable}} placeholders (e.g. {{company_name}}).",
    )
    category = models.CharField(
        max_length=20,
        choices=Category.choices,
        default=Category.AUTH,
        db_index=True,
    )
    event_key = models.SlugField(
        max_length=80,
        unique=True,
        help_text="Unique key used to trigger this template (e.g. welcome_email, deposit_confirmation).",
    )
    html_content = models.TextField(
        help_text=(
            "HTML body with {{variable}} placeholders. "
            "Available: {{user_name}}, {{user_email}}, {{otp}}, {{amount}}, "
            "{{company_name}}, {{reason}}, {{date}}, {{verify_url}}, etc."
        ),
    )
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["category", "name"]
        verbose_name = "Notification template"
        verbose_name_plural = "Notification templates"

    def __str__(self) -> str:
        return f"{self.name} [{self.event_key}]"


# ---------------------------------------------------------------------------
# 3. NotificationLog
# ---------------------------------------------------------------------------

class NotificationLog(models.Model):
    """Immutable log of every notification email attempt."""

    class Status(models.TextChoices):
        QUEUED = "QUEUED", "Queued"
        SENT = "SENT", "Sent"
        FAILED = "FAILED", "Failed"
        OPENED = "OPENED", "Opened"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    recipient = models.EmailField(db_index=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="notification_logs",
    )
    template = models.ForeignKey(
        NotificationTemplate,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="logs",
    )
    event_key = models.CharField(max_length=80, blank=True, default="", db_index=True)
    subject = models.CharField(max_length=255, blank=True, default="")
    status = models.CharField(
        max_length=10,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    error_details = models.TextField(blank=True, default="")
    opened_at = models.DateTimeField(null=True, blank=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-created_at"]
        verbose_name = "Notification log"
        verbose_name_plural = "Notification logs"
        indexes = [
            models.Index(fields=["recipient", "-created_at"]),
            models.Index(fields=["-created_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.recipient} — {self.event_key} ({self.status})"

    def mark_opened(self) -> None:
        """Set status to OPENED on first tracking-pixel hit."""
        if not self.opened_at:
            self.opened_at = timezone.now()
            self.status = self.Status.OPENED
            self.save(update_fields=["opened_at", "status"])
