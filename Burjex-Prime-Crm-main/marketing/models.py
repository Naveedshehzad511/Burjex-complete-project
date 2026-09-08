from django.conf import settings
from django.db import models
from django.utils import timezone


class MarketingCampaign(models.Model):
    name = models.CharField(max_length=200, unique=True)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return self.name


class Lead(models.Model):
    class Status(models.TextChoices):
        NEW = "NEW", "New"
        QUALIFIED = "QUALIFIED", "Qualified"
        INACTIVE = "INACTIVE", "Inactive"
        CONVERTED = "CONVERTED", "Converted"

    campaign = models.ForeignKey(MarketingCampaign, on_delete=models.CASCADE, related_name="leads")

    full_name = models.CharField(max_length=180, blank=True)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=60, blank=True)

    assigned_to = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="assigned_leads",
    )
    department = models.ForeignKey(
        "admin_panel.CrmDepartment",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="leads",
    )
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.NEW)
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return self.email or f"Lead {self.id}"


class SalesFunnelVisitor(models.Model):
    """Pre-registration capture from the public site popup (Sales funnel — Visitors stage)."""

    full_name = models.CharField(max_length=180)
    email = models.EmailField(db_index=True)
    phone = models.CharField(max_length=60, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    page_url = models.CharField(max_length=500, blank=True)
    referrer = models.CharField(max_length=500, blank=True)

    converted_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_visitor_captures",
    )

    assigned_manager = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_visitors_as_manager",
    )
    assigned_agent = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_visitors_as_agent",
    )
    last_contact_at = models.DateTimeField(null=True, blank=True)
    last_contacted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_visitor_last_contacts",
    )

    is_dropped = models.BooleanField(default=False)
    profit_potential_usd = models.DecimalField(max_digits=14, decimal_places=2, default=2500)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["-created_at"]),
            models.Index(fields=["email", "converted_user"]),
        ]

    def __str__(self) -> str:
        return f"{self.email} ({self.created_at.date()})"


class SalesFunnelProfile(models.Model):
    """Per-client funnel assignment, LTV estimate, and drop tracking."""

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="sales_funnel_profile",
    )
    assigned_manager = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_clients_as_manager",
    )
    assigned_agent = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_clients_as_agent",
    )
    estimated_profit_potential_usd = models.DecimalField(max_digits=14, decimal_places=2, default=5000)

    is_dropped = models.BooleanField(default=False)
    dropped_at = models.DateTimeField(null=True, blank=True)
    dropped_reason = models.CharField(max_length=500, blank=True)

    last_contact_at = models.DateTimeField(null=True, blank=True)
    last_contacted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="funnel_client_last_contacts",
    )
    internal_notes = models.TextField(blank=True)

    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Funnel profile #{self.user_id}"


class SalesFunnelContactLog(models.Model):
    class Channel(models.TextChoices):
        CALL = "CALL", "Call"
        EMAIL = "EMAIL", "Email"
        WHATSAPP = "WHATSAPP", "WhatsApp"
        NOTE = "NOTE", "Note"
        ASSIGN = "ASSIGN", "Assignment"

    visitor = models.ForeignKey(
        SalesFunnelVisitor,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="contact_logs",
    )
    client = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="sales_funnel_contact_logs",
    )
    channel = models.CharField(max_length=20, choices=Channel.choices)
    body = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="sales_funnel_actions_logged",
    )
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.channel} @ {self.created_at}"


class MarketingWithdrawRequest(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"
        COMPLETED = "COMPLETED", "Completed"

    requester = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="marketing_withdraw_requests")
    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")

    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PENDING)
    reference = models.CharField(max_length=200, blank=True)
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return f"MarketingWithdraw {self.requester_id} {self.amount} {self.currency}"
