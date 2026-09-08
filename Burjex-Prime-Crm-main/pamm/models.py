from django.conf import settings
from django.db import models
from django.utils import timezone


class PAMMAccount(models.Model):
    name = models.CharField(max_length=200, unique=True)
    master = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="pamm_accounts_as_master",
    )

    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return self.name


class PAMMInvestor(models.Model):
    class Status(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        WITHDRAW_REQUESTED = "WITHDRAW_REQUESTED", "Withdraw Requested"
        WITHDRAWN = "WITHDRAWN", "Withdrawn"

    pamm_account = models.ForeignKey(PAMMAccount, on_delete=models.CASCADE, related_name="investors")
    investor = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="pamm_investments")

    investment_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    status = models.CharField(max_length=30, choices=Status.choices, default=Status.ACTIVE)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        unique_together = ("pamm_account", "investor")

    def __str__(self) -> str:
        return f"{self.pamm_account_id} / {self.investor_id}"
