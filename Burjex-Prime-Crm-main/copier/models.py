from django.conf import settings
from django.db import models
from django.utils import timezone


class CopyTradingAccount(models.Model):
    class Status(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        INACTIVE = "INACTIVE", "Inactive"

    name = models.CharField(max_length=200, unique=True)
    master_trader = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="copier_master_accounts")
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.ACTIVE)
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return self.name


class CopierFollower(models.Model):
    copy_account = models.ForeignKey(CopyTradingAccount, on_delete=models.CASCADE, related_name="followers")
    follower = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="copier_followed_accounts")

    follower_risk_multiplier = models.DecimalField(max_digits=10, decimal_places=3, default=1)
    status = models.CharField(max_length=20, default="ACTIVE")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        unique_together = ("copy_account", "follower")

    def __str__(self) -> str:
        return f"{self.copy_account_id} -> {self.follower_id}"
