from django.conf import settings
from django.db import models


class EnterpriseSecuritySettings(models.Model):
    """Centralized enterprise security toggles (singleton pk=1)."""

    failed_login_max_attempts = models.PositiveIntegerField(default=10)
    failed_login_lockout_seconds = models.PositiveIntegerField(default=900)
    suspicious_failures_per_ip = models.PositiveIntegerField(default=8)
    email_security_alerts = models.BooleanField(default=True)
    withdrawal_submitted_alert = models.BooleanField(default=True)
    login_new_device_alert = models.BooleanField(default=True)
    risk_alert_threshold = models.PositiveIntegerField(default=75)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Enterprise security settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class AuditLogChannel(models.TextChoices):
    ADMIN = "ADMIN", "Admin"
    CLIENT = "CLIENT", "Client"
    STAFF = "STAFF", "Staff"
    SYSTEM = "SYSTEM", "System"


class AuditLog(models.Model):
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    actor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="audit_actions",
    )
    actor_email = models.CharField(max_length=254, blank=True, default="")
    action = models.CharField(max_length=80, db_index=True)
    entity_type = models.CharField(max_length=60, db_index=True)
    entity_id = models.CharField(max_length=64, blank=True, default="")
    channel = models.CharField(
        max_length=20,
        choices=AuditLogChannel.choices,
        default=AuditLogChannel.SYSTEM,
    )
    ip = models.GenericIPAddressField(null=True, blank=True)
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["entity_type", "entity_id"]),
        ]


class LoginChannel(models.TextChoices):
    ADMIN = "ADMIN", "Admin"
    CLIENT = "CLIENT", "Client"


class LoginEvent(models.Model):
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="login_events",
    )
    username_attempt = models.CharField(max_length=254, blank=True, default="")
    success = models.BooleanField(default=False)
    channel = models.CharField(
        max_length=20,
        choices=LoginChannel.choices,
        default=LoginChannel.CLIENT,
    )
    ip = models.GenericIPAddressField(null=True, blank=True)
    user_agent = models.CharField(max_length=512, blank=True, default="")
    suspicious = models.BooleanField(default=False)
    notes = models.CharField(max_length=255, blank=True, default="")

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["ip", "created_at"]),
        ]


class BookingType(models.TextChoices):
    A_BOOK = "A_BOOK", "A-Book"
    B_BOOK = "B_BOOK", "B-Book"


class ClientRiskProfile(models.Model):
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="risk_profile",
    )
    risk_score = models.PositiveIntegerField(default=0)
    exposure_limit_usd = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    exposure_current_usd = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    booking = models.CharField(
        max_length=10,
        choices=BookingType.choices,
        default=BookingType.B_BOOK,
    )
    monitoring_notes = models.TextField(blank=True, default="")
    last_assessed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "Client risk profile"


class RiskAlert(models.Model):
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="risk_alerts",
    )
    level = models.CharField(max_length=20, default="MEDIUM")
    message = models.CharField(max_length=500)
    acknowledged = models.BooleanField(default=False)
    acknowledged_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]


class StaffNotification(models.Model):
    recipient = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="staff_notifications",
    )
    title = models.CharField(max_length=200)
    body = models.TextField(blank=True)
    action_url = models.CharField(
        max_length=512,
        blank=True,
        default="",
        help_text="Optional path or URL to open when the notification is clicked (e.g. /admin-panel/tickets/).",
    )
    read_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]

    @property
    def is_read(self) -> bool:
        return bool(self.read_at)
