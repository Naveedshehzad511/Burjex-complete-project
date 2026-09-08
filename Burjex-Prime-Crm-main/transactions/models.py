from django.conf import settings
from django.db import models
from django.utils import timezone
import uuid


class PaymentGateway(models.Model):
    class Scope(models.TextChoices):
        DEPOSIT = "DEPOSIT", "Deposit"
        WITHDRAW = "WITHDRAW", "Withdraw"
        BOTH = "BOTH", "Both"

    class GatewayType(models.TextChoices):
        LOCAL = "LOCAL", "Local"
        THIRD_PARTY = "THIRD_PARTY", "Third Party"

    class PaymentMethod(models.TextChoices):
        BANK = "BANK", "Bank"
        CRYPTO = "CRYPTO", "Crypto"
        WALLET = "WALLET", "Wallet"

    class VisibilityStatus(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        INACTIVE = "INACTIVE", "Inactive"
        MAINTENANCE = "MAINTENANCE", "Maintenance"

    class FeeType(models.TextChoices):
        NONE = "NONE", "None"
        FIXED = "FIXED", "Fixed"
        PERCENT = "PERCENT", "Percentage"

    class RateMode(models.TextChoices):
        FIXED = "FIXED", "Fixed"
        MARKET = "MARKET", "Market"

    class ProcessingMode(models.TextChoices):
        INSTANT = "INSTANT", "Instant"
        MANUAL = "MANUAL", "Manual"

    name = models.CharField(max_length=120)
    code = models.CharField(max_length=80, unique=True)
    scope = models.CharField(max_length=15, choices=Scope.choices, default=Scope.BOTH)
    gateway_type = models.CharField(max_length=20, choices=GatewayType.choices, default=GatewayType.LOCAL)
    payment_method = models.CharField(max_length=20, choices=PaymentMethod.choices, default=PaymentMethod.BANK)
    currency = models.CharField(max_length=10, default="USD")
    min_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    max_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    processing_time = models.CharField(max_length=80, blank=True, default="")
    charges = models.CharField(max_length=80, blank=True, default="")
    icon = models.ImageField(upload_to="gateway_icons/", null=True, blank=True)
    instructions = models.TextField(blank=True, default="")
    description = models.TextField(blank=True, default="")

    # Treasury / professional settings
    category = models.CharField(max_length=80, blank=True, default="")
    visibility_status = models.CharField(
        max_length=15,
        choices=VisibilityStatus.choices,
        default=VisibilityStatus.ACTIVE,
    )
    fee_type = models.CharField(max_length=15, choices=FeeType.choices, default=FeeType.NONE)
    fee_value = models.DecimalField(max_digits=20, decimal_places=4, default=0)
    exchange_rate = models.DecimalField(max_digits=20, decimal_places=8, default=1)
    rate_mode = models.CharField(max_length=15, choices=RateMode.choices, default=RateMode.FIXED)
    rate_markup = models.DecimalField(max_digits=20, decimal_places=8, default=0)
    processing_mode = models.CharField(max_length=15, choices=ProcessingMode.choices, default=ProcessingMode.INSTANT)
    display_order = models.PositiveIntegerField(default=0)
    display_badge = models.CharField(max_length=80, blank=True, default="")
    require_payment_proof = models.BooleanField(default=False)

    # Withdrawal-oriented (stored for all rows; used when scope is withdraw/both)
    daily_withdraw_limit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    whitelist_required = models.BooleanField(default=False)
    auto_approve_withdraw = models.BooleanField(default=False)
    requires_kyc_for_method = models.BooleanField(default=False)
    requires_2fa_for_method = models.BooleanField(default=False)
    max_pending_per_user = models.PositiveIntegerField(default=0)
    cooldown_minutes = models.PositiveIntegerField(default=0)

    # Local fields
    account_name = models.CharField(max_length=120, blank=True, default="")
    bank_name = models.CharField(max_length=120, blank=True, default="")
    account_number = models.CharField(max_length=120, blank=True, default="")
    iban = models.CharField(max_length=120, blank=True, default="")
    swift_code = models.CharField(max_length=40, blank=True, default="")
    wallet_address = models.CharField(max_length=255, blank=True, default="")
    network = models.CharField(max_length=80, blank=True, default="")

    # Third-party fields
    api_key = models.CharField(max_length=255, blank=True, default="")
    secret_key = models.CharField(max_length=255, blank=True, default="")
    webhook_url = models.CharField(max_length=255, blank=True, default="")
    api_url = models.CharField(max_length=255, blank=True, default="")
    merchant_id = models.CharField(max_length=120, blank=True, default="")

    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["display_order", "name"]

    def save(self, *args, **kwargs):
        self.is_active = self.visibility_status != self.VisibilityStatus.INACTIVE
        super().save(*args, **kwargs)

    def client_can_see(self) -> bool:
        return self.visibility_status in (
            self.VisibilityStatus.ACTIVE,
            self.VisibilityStatus.MAINTENANCE,
        )

    def client_can_use(self) -> bool:
        return self.visibility_status == self.VisibilityStatus.ACTIVE

    @classmethod
    def client_visible_q(cls):
        return models.Q(visibility_status__in=[cls.VisibilityStatus.ACTIVE, cls.VisibilityStatus.MAINTENANCE])

    def __str__(self) -> str:
        return self.name


class Transaction(models.Model):
    class TxType(models.TextChoices):
        # Client-facing
        CLIENT_DEPOSIT = "CLIENT_DEPOSIT", "Client Deposit"
        CLIENT_WITHDRAW = "CLIENT_WITHDRAW", "Client Withdraw"

        # Wallet operations
        WALLET_DEPOSIT = "WALLET_DEPOSIT", "Wallet Deposit"
        WALLET_WITHDRAW = "WALLET_WITHDRAW", "Wallet Withdraw"

        # IB flows
        IB_WITHDRAW = "IB_WITHDRAW", "IB Withdraw"

        # Platform operations
        INTERNAL_TRANSFER = "INTERNAL_TRANSFER", "Internal Transfer"

        # Pending requests (captured separately in the UI)
        PENDING_DEPOSIT = "PENDING_DEPOSIT", "Pending Deposit"
        PENDING_WITHDRAW = "PENDING_WITHDRAW", "Pending Withdraw"
        PENDING_IB_WITHDRAW = "PENDING_IB_WITHDRAW", "Pending IB Withdraw"

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        COMPLETED = "COMPLETED", "Completed"
        REJECTED = "REJECTED", "Rejected"

    tx_type = models.CharField(max_length=40, choices=TxType.choices)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)

    actor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="transactions_as_actor",
    )

    # Used for internal transfers and some IB operations
    from_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="transactions_as_from",
    )
    to_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="transactions_as_to",
    )

    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")

    # Payment gateway reference / blockchain tx hash
    reference = models.CharField(max_length=200, blank=True)
    account_details = models.TextField(blank=True, default="")

    # Uploaded payment screenshot/receipt (optional).
    # For deposits, admins can review this on approval screens.
    payment_screenshot = models.FileField(upload_to="payment_screenshots/", null=True, blank=True)

    payment_gateway = models.ForeignKey(
        PaymentGateway,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="transactions",
    )

    created_at = models.DateTimeField(default=timezone.now)
    processed_at = models.DateTimeField(null=True, blank=True)

    notes = models.TextField(blank=True)
    reject_reason = models.TextField(blank=True, default="")
    request_uid = models.CharField(max_length=64, blank=True, default="", db_index=True)

    @property
    def user_notes(self) -> str:
        if not self.notes:
            return ""
        if "\n\nClient Notes:\n" in self.notes:
            return self.notes.split("\n\nClient Notes:\n")[1].strip()
        if "Manual deposit request from client portal." in self.notes:
            return ""
        if self.notes.strip() == "Withdraw request from client portal.":
            return ""
        return self.notes.strip()

    # Populated when a client withdrawal hold is created (wallet already reduced).
    balance_snapshot_wallet = models.DecimalField(
        max_digits=20,
        decimal_places=2,
        null=True,
        blank=True,
        help_text="User wallet_balance immediately after this withdrawal hold was placed.",
    )
    balance_snapshot_pending = models.DecimalField(
        max_digits=20,
        decimal_places=2,
        null=True,
        blank=True,
        help_text="User pending_withdraw total immediately after this withdrawal hold was placed.",
    )
    processed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="processed_transactions",
    )

    is_demo_ledger = models.BooleanField(
        default=False,
        db_index=True,
        help_text="When True, row is virtual/demo-only and excluded from real-money totals.",
    )

    class Meta:
        ordering = ["-created_at"]

    def mark_completed(self) -> None:
        self.status = self.Status.COMPLETED
        self.processed_at = timezone.now()
        self.save(update_fields=["status", "processed_at"])

    def __str__(self) -> str:
        return f"{self.tx_type} {self.amount} {self.currency} ({self.status})"


class InternalTransfer(models.Model):
    class TransferType(models.TextChoices):
        WALLET_TO_TRADING = "WALLET_TO_TRADING", "Wallet to Trading Account"
        TRADING_TO_WALLET = "TRADING_TO_WALLET", "Trading Account to Wallet"
        TRADING_TO_TRADING = "TRADING_TO_TRADING", "Trading Account to Trading Account"
        IB_TO_TRADING = "IB_TO_TRADING", "IB Wallet to Trading Account"
        IB_TO_WALLET = "IB_TO_WALLET", "IB Wallet to Wallet"

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="internal_transfers")
    transfer_type = models.CharField(max_length=40, choices=TransferType.choices)
    from_account = models.CharField(max_length=120)
    to_account = models.CharField(max_length=120)
    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    note = models.CharField(max_length=255, blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)
    processed_at = models.DateTimeField(null=True, blank=True)
    processed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="processed_internal_transfers",
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.user_id} {self.transfer_type} {self.amount} {self.status}"


class Match2PayTransaction(models.Model):
    """Tracks a Match2Pay crypto deposit session until completion (webhook or poller)."""

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        COMPLETED = "COMPLETED", "Completed"
        FAILED = "FAILED", "Failed"
        EXPIRED = "EXPIRED", "Expired"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="match2pay_transactions",
    )
    payment_gateway = models.ForeignKey(
        PaymentGateway,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="match2pay_transactions",
    )
    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")
    network = models.CharField(max_length=20, db_index=True)
    payment_id = models.CharField(max_length=120, unique=True, db_index=True)
    txid = models.CharField(max_length=200, blank=True, default="", db_index=True)
    address = models.CharField(max_length=255, blank=True, default="")
    qr_code_data = models.TextField(
        blank=True,
        default="",
        help_text="Base64 image data or absolute URL for QR display.",
    )
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING, db_index=True)
    raw_create_response = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.payment_id} {self.amount} {self.currency} ({self.status})"


class BalanceLedger(models.Model):
    class EntryType(models.TextChoices):
        WITHDRAW_HOLD = "WITHDRAW_HOLD", "Withdraw Hold"
        WITHDRAW_APPROVE = "WITHDRAW_APPROVE", "Withdraw Approve"
        WITHDRAW_REJECT = "WITHDRAW_REJECT", "Withdraw Reject"
        DEPOSIT_APPROVE = "deposit_approve", "Deposit Approve"
        DEPOSIT_REJECT = "deposit_reject", "Deposit Reject"
        TRANSFER_DEBIT = "TRANSFER_DEBIT", "Transfer Debit"
        TRANSFER_CREDIT = "TRANSFER_CREDIT", "Transfer Credit"

    entry_uid = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="balance_ledger_entries")
    entry_type = models.CharField(max_length=30, choices=EntryType.choices)
    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")
    wallet_before = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_after = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    pending_before = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    pending_after = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    trading_before = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    trading_after = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    reference = models.CharField(max_length=120, blank=True, default="")
    note = models.CharField(max_length=255, blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-created_at"]


class ProcessedAction(models.Model):
    """
    Tracks globally unique IDs for all financial operations to guarantee they are processed exactly once.
    """
    unique_id = models.CharField(max_length=255, unique=True, db_index=True)
    action_type = models.CharField(max_length=100)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.action_type} - {self.unique_id}"
