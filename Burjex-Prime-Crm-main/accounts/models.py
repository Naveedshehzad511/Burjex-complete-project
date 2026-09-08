import base64
import hashlib
import uuid
from datetime import timedelta
from cryptography.fernet import Fernet

from django.conf import settings
from django.contrib.auth.models import AbstractUser
from django.db import models
from django.utils import timezone


# Withdrawal / compliance: max saved destinations per user (user + admin combined).
MAX_VERIFIED_BANK_ACCOUNTS_PER_USER = 5
MAX_VERIFIED_CRYPTO_WALLETS_PER_USER = 5


def _fernet_from_secret_key() -> Fernet:
    """
    Deterministic Fernet key derived from SECRET_KEY.
    Note: Replace with a dedicated random key per environment in production.
    """
    digest = hashlib.sha256(settings.SECRET_KEY.encode("utf-8")).digest()
    key = base64.urlsafe_b64encode(digest)
    return Fernet(key)


class User(AbstractUser):
    class Roles(models.TextChoices):
        ADMIN = "ADMIN", "Admin"
        IB = "IB", "IB"
        CLIENT = "CLIENT", "Client"
        TRADER = "TRADER", "Trader"
        BANKER = "BANKER", "Banker"
        COPIER = "COPIER", "Copier"
        SALES_MANAGER = "SALES_MANAGER", "Sales Manager"
        MANAGER = "MANAGER", "Account Manager"

    class AccountStatus(models.TextChoices):
        APPROVED = "APPROVED", "Approve"
        PENDING = "PENDING", "Pending"
        SUSPENDED = "SUSPENDED", "Suspended"
        BLOCKED = "BLOCKED", "Blocked"

    role = models.CharField(max_length=20, choices=Roles.choices, default=Roles.CLIENT)

    # Used by admin dashboard ("FTD Users" / "Non FTD Users")
    ftd_user = models.BooleanField(default=False)

    # Used by admin dashboard ("Pending Clients")
    class KYCStatus(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        EXPIRED = "EXPIRED", "Expired"
        REJECTED = "REJECTED", "Rejected"

    class KYCComponentStatus(models.TextChoices):
        INCOMPLETE = "incomplete", "Incomplete"
        PENDING = "pending", "Pending"
        VERIFIED = "verified", "Verified"
        REJECTED = "rejected", "Rejected"

    kyc_status = models.CharField(max_length=20, choices=KYCStatus.choices, default=KYCStatus.PENDING)
    kyc_identity_front_status = models.CharField(
        max_length=16,
        choices=KYCComponentStatus.choices,
        default=KYCComponentStatus.INCOMPLETE,
    )
    kyc_identity_back_status = models.CharField(
        max_length=16,
        choices=KYCComponentStatus.choices,
        default=KYCComponentStatus.INCOMPLETE,
    )
    kyc_address_status = models.CharField(
        max_length=16,
        choices=KYCComponentStatus.choices,
        default=KYCComponentStatus.INCOMPLETE,
    )
    kyc_final_status = models.CharField(
        max_length=16,
        choices=KYCComponentStatus.choices,
        default=KYCComponentStatus.INCOMPLETE,
    )
    kyc_reject_reason = models.TextField(blank=True, default="")
    kyc_approved_by = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="kyc_approvals_made",
    )
    kyc_approved_at = models.DateTimeField(null=True, blank=True)

    referral_code = models.CharField(max_length=32, unique=True, blank=True)
    phone = models.CharField(max_length=40, blank=True)
    country = models.CharField(max_length=120, blank=True)
    email_verified = models.BooleanField(default=False)
    email_token = models.CharField(max_length=120, blank=True, default="")
    email_verified_at = models.DateTimeField(null=True, blank=True)
    email_token_created_at = models.DateTimeField(null=True, blank=True)
    wallet_balance = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    pending_withdraw = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    address = models.CharField(max_length=255, blank=True, default="")
    referred_by = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="referrals",
    )

    crm_department = models.ForeignKey(
        "admin_panel.CrmDepartment",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="staff_users",
    )
    crm_role = models.ForeignKey(
        "admin_panel.CrmRole",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="staff_users",
        help_text="CRM permission template (folders: KYC, Finance, Sales, etc.).",
    )
    registered_via_sales_manager = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="clients_registered_via_manager",
        limit_choices_to={"role": Roles.SALES_MANAGER},
    )

    marketing_name = models.CharField(max_length=120, blank=True, default="")
    account_status = models.CharField(
        max_length=20,
        choices=AccountStatus.choices,
        default=AccountStatus.APPROVED,
    )
    ib_linked_at = models.DateTimeField(null=True, blank=True)
    ib_linked_by = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="ib_links_recorded",
    )
    force_password_change = models.BooleanField(default=False)
    phone_verified = models.BooleanField(default=False)
    avatar = models.ImageField(
        upload_to="user_avatars/",
        blank=True,
        null=True,
        help_text="Optional profile photo shown in the client portal header.",
    )

    # Google Authenticator (TOTP) — enabled only after client completes setup in portal
    totp_secret = models.CharField(max_length=64, blank=True, default="")
    totp_enabled = models.BooleanField(default=False)

    def save(self, *args, **kwargs):
        # Auto-assign a referral code for new users.
        if not self.referral_code:
            import secrets

            while True:
                code = secrets.token_urlsafe(12)[:32].upper()
                if not User.objects.filter(referral_code=code).exists():
                    self.referral_code = code
                    break
        # Do not regenerate a verification token after email is verified (one-time link flow).
        if not self.email_token and not self.email_verified:
            self.email_token = uuid.uuid4().hex

        if not self.is_superuser:
            if self.account_status in (self.AccountStatus.SUSPENDED, self.AccountStatus.BLOCKED):
                self.is_active = False
            elif self.account_status == self.AccountStatus.APPROVED:
                # Clients stay inactive until email is verified (admin can verify manually).
                if self.role == self.Roles.CLIENT and not self.email_verified:
                    self.is_active = False
                else:
                    self.is_active = True

        # Make `createsuperuser` usable immediately:
        # ensure superusers can access the admin panel by default.
        if self.is_superuser and self.role == self.Roles.CLIENT:
            self.role = self.Roles.ADMIN

        super().save(*args, **kwargs)

    def is_admin(self) -> bool:
        # Admin panel access roles.
        return self.role in {self.Roles.ADMIN, self.Roles.BANKER}

    def is_sales_manager(self) -> bool:
        return self.role == self.Roles.SALES_MANAGER

    def is_account_manager(self) -> bool:
        """Restricted CRM manager: assigned clients + portal permissions only."""
        return self.role == self.Roles.MANAGER

    def can_access_sales_portal(self) -> bool:
        return self.is_admin() or self.is_sales_manager()

    def can_access_manager_portal(self) -> bool:
        return self.is_account_manager()

    def can_use_staff_login_portal(self) -> bool:
        """May authenticate via /admin/login/ (admin, banker, sales manager, account manager)."""
        return self.is_admin() or self.is_sales_manager() or self.is_account_manager()

    def staff_home_path(self) -> str:
        if self.is_sales_manager():
            return "/sales/dashboard/"
        if self.is_account_manager():
            return "/manager/dashboard/"
        return "/admin/dashboard/"

    def is_crm_portal_staff(self) -> bool:
        """Staff who use CRM shell (/sales or /admin) but are not client-portal users."""
        return self.can_access_sales_portal()

    def is_ib(self) -> bool:
        return self.role == self.Roles.IB

    def is_client(self) -> bool:
        return self.role == self.Roles.CLIENT

    def is_trader(self) -> bool:
        return self.role == self.Roles.TRADER

    def is_user(self) -> bool:
        # Client portal login — exclude admin, banker, sales staff, and account managers.
        if self.is_admin() or self.is_sales_manager() or self.is_account_manager():
            return False
        return True

    def display_name(self) -> str:
        n = f"{self.first_name} {self.last_name}".strip()
        return n or (self.email or self.username or "")

    @property
    def profile_display_name(self) -> str:
        """Template-friendly alias for display_name()."""
        return self.display_name()

    @property
    def is_verified(self) -> bool:
        """Email confirmed and account approved — used in portal profile UI."""
        return bool(self.email_verified) and self.account_status == self.AccountStatus.APPROVED


class UserRestriction(models.Model):
    """Per-user portal / financial toggles controlled from admin user settings."""

    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="restriction")
    disable_deposit = models.BooleanField(default=False)
    disable_withdraw = models.BooleanField(default=False)
    disable_transfer = models.BooleanField(default=False)
    disable_internal_transfer = models.BooleanField(default=False)
    disable_wallet_to_mt5 = models.BooleanField(default=False)
    disable_mt5_to_wallet = models.BooleanField(default=False)
    disable_ib_withdraw = models.BooleanField(default=False)
    disable_trading = models.BooleanField(default=False)
    disable_create_mt5 = models.BooleanField(default=False)
    disable_profile_access = models.BooleanField(default=False)
    disable_client_area = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Restrictions for user {self.user_id}"


class MT5Group(models.Model):
    """
    CRM group (Group Management): CRM label + platform + platform group + derived technical name.
    Account types reference this row only; platform groups are loaded from connected integrations.
    """

    class BrokerPlatform(models.TextChoices):
        MT5 = "MT5", "MT5"
        MATCH_TRADER = "MATCH_TRADER", "Match-Trader"
        X9_TRADER = "X9_TRADER", "X9 Trader"
        BTRADER = "BTRADER", "BTrader"

    crm_group_name = models.CharField(
        max_length=120,
        blank=True,
        default="",
        help_text="Display name in CRM (e.g. Standard, ECN, Pro).",
    )
    platform = models.CharField(
        max_length=32,
        choices=BrokerPlatform.choices,
        default=BrokerPlatform.MT5,
        db_index=True,
        help_text="Trading platform this row maps to.",
    )
    platform_group_name = models.CharField(
        max_length=120,
        blank=True,
        default="",
        help_text="Exact group name on the platform (from live API / synced catalog).",
    )
    name = models.CharField(
        max_length=120,
        unique=True,
        help_text="Internal unique key / MT5 server group string when platform is MT5.",
    )
    match_trader_broker_group = models.ForeignKey(
        "admin_panel.MatchTraderBrokerGroup",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="crm_mt5_groups",
        help_text="Match-Trader trading group for this CRM group (Group Management).",
    )
    is_active = models.BooleanField(default=True)
    description = models.TextField(blank=True)

    class Meta:
        verbose_name = "Broker group"
        verbose_name_plural = "Broker groups"

    def __str__(self) -> str:
        return self.crm_group_name or self.name


class MT5Account(models.Model):
    class AccountType(models.TextChoices):
        LIVE = "LIVE", "Live"
        DEMO = "DEMO", "Demo"

    class Status(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        INACTIVE = "INACTIVE", "Inactive"
        CLOSED = "CLOSED", "Closed"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="mt5_accounts")
    account_type = models.CharField(max_length=10, choices=AccountType.choices, default=AccountType.LIVE)

    login_id = models.CharField(max_length=64, unique=True)
    server = models.CharField(max_length=200)

    group = models.ForeignKey(MT5Group, null=True, blank=True, on_delete=models.SET_NULL, related_name="mt5_accounts")
    leverage = models.PositiveIntegerField(default=100)

    status = models.CharField(max_length=15, choices=Status.choices, default=Status.ACTIVE)
    account_label = models.CharField(max_length=60, blank=True, default="")
    trading_enabled = models.BooleanField(default=True)
    deposit_enabled = models.BooleanField(default=True)
    withdraw_enabled = models.BooleanField(default=True)

    mt5_password_encrypted = models.TextField(blank=True)
    investor_password_encrypted = models.TextField(blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    # Snapshot fields for the user portal "Trading Account Card".
    # In production, sync these from MT5 periodically via your integration.
    balance = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    credit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    equity = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    free_margin = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    unrealized_pnl = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    last_sync_at = models.DateTimeField(null=True, blank=True)

    def set_mt5_password(self, plain_password: str) -> None:
        if not plain_password:
            self.mt5_password_encrypted = ""
            return
        f = _fernet_from_secret_key()
        token = f.encrypt(plain_password.encode("utf-8"))
        self.mt5_password_encrypted = token.decode("utf-8")

    def get_mt5_password(self) -> str:
        if not self.mt5_password_encrypted:
            return ""
        f = _fernet_from_secret_key()
        plain = f.decrypt(self.mt5_password_encrypted.encode("utf-8"))
        return plain.decode("utf-8")

    def set_investor_password(self, plain_password: str) -> None:
        if not plain_password:
            self.investor_password_encrypted = ""
            return
        f = _fernet_from_secret_key()
        token = f.encrypt(plain_password.encode("utf-8"))
        self.investor_password_encrypted = token.decode("utf-8")

    def get_investor_password(self) -> str:
        if not self.investor_password_encrypted:
            return ""
        f = _fernet_from_secret_key()
        plain = f.decrypt(self.investor_password_encrypted.encode("utf-8"))
        return plain.decode("utf-8")

    def __str__(self) -> str:
        return f"{self.user_id}:{self.login_id}"


class Document(models.Model):
    class DocType(models.TextChoices):
        PASSPORT = "PASSPORT", "Passport"
        NATIONAL_ID = "NATIONAL_ID", "National ID"
        ID_DOCUMENT_FRONT = "ID_DOCUMENT_FRONT", "ID Document (front)"
        ID_DOCUMENT_BACK = "ID_DOCUMENT_BACK", "ID Document (back)"
        UTILITY_BILL = "UTILITY_BILL", "Utility Bill"
        PROOF_OF_ADDRESS = "PROOF_OF_ADDRESS", "Proof of Address"
        SELFIE = "SELFIE", "Selfie / Liveness"
        OTHER = "OTHER", "Other"

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        EXPIRED = "EXPIRED", "Expired"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="documents")
    doc_type = models.CharField(max_length=40, choices=DocType.choices, default=DocType.OTHER)
    file = models.FileField(upload_to="user_documents/")

    expires_at = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    uploaded_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="uploaded_documents",
    )
    uploaded_at = models.DateTimeField(default=timezone.now)
    comment = models.TextField(blank=True)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="reviewed_documents",
    )
    review_comment = models.TextField(blank=True, default="")

    def is_expired(self) -> bool:
        return self.expires_at is not None and self.expires_at < timezone.localdate()


class BankDetails(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    class PaymentChannel(models.TextChoices):
        BANK_TRANSFER = "BANK_TRANSFER", "Bank Transfer"
        CRYPTO = "CRYPTO", "Crypto"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="bank_details")
    payment_channel = models.CharField(max_length=30, choices=PaymentChannel.choices, default=PaymentChannel.BANK_TRANSFER)

    bank_name = models.CharField(max_length=180, blank=True)
    bank_address = models.TextField(blank=True)
    country = models.CharField(max_length=120, blank=True)
    swift_code = models.CharField(max_length=40, blank=True)
    account_holder_name = models.CharField(max_length=180, blank=True)
    account_number = models.CharField(max_length=120, blank=True)
    iban = models.CharField(max_length=64, blank=True)

    crypto_wallet_address = models.CharField(max_length=200, blank=True)
    crypto_network = models.CharField(max_length=40, blank=True)  # e.g. TRC20 / ERC20

    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"{self.user_id} ({self.status})"


class KYCIdentity(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="kyc_identity_records")
    document_type = models.CharField(max_length=120, default="Passport")
    full_name_on_document = models.CharField(
        max_length=200,
        blank=True,
        default="",
        help_text="Legal name as shown on ID (used for admin KYC name matching).",
    )
    expiry_date = models.DateField(null=True, blank=True)
    front_file = models.FileField(upload_to="kyc/identity/front/")
    back_file = models.FileField(upload_to="kyc/identity/back/", null=True, blank=True)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(default=timezone.now)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="reviewed_kyc_identities"
    )

    class Meta:
        ordering = ["-created_at"]


class KYCAddress(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="kyc_address_records")
    document_type = models.CharField(max_length=120, default="Utility Bill")
    document_file = models.FileField(upload_to="kyc/address/")
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(default=timezone.now)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="reviewed_kyc_addresses"
    )

    class Meta:
        ordering = ["-created_at"]


class VerifiedBankAccount(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="verified_bank_accounts")
    account_name = models.CharField(max_length=180)
    account_number = models.CharField(max_length=120)
    iban = models.CharField(max_length=80, blank=True, default="")
    swift_code = models.CharField(max_length=40, blank=True, default="")
    bank_name = models.CharField(max_length=180)
    bank_address = models.CharField(max_length=255, blank=True, default="")
    branch = models.CharField(max_length=120, blank=True, default="", help_text="Optional branch / location.")
    country = models.CharField(max_length=120)
    proof_file = models.FileField(upload_to="kyc/bank/", null=True, blank=True)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(default=timezone.now)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="reviewed_bank_accounts"
    )

    class Meta:
        ordering = ["-created_at"]


class VerifiedCryptoAddress(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="verified_crypto_addresses")
    wallet_name = models.CharField(max_length=120, blank=True, default="", help_text="Optional label shown to the user (e.g. Main wallet).")
    network = models.CharField(max_length=80)
    wallet_address = models.CharField(max_length=255)
    verification_file = models.FileField(upload_to="kyc/crypto/", null=True, blank=True)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(default=timezone.now)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="reviewed_crypto_addresses"
    )

    class Meta:
        ordering = ["-created_at"]


class Bonus(models.Model):
    class Status(models.TextChoices):
        GIVEN = "GIVEN", "Given"
        REMOVED = "REMOVED", "Removed"
        PENDING = "PENDING", "Pending"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="bonuses")
    mt5_account = models.ForeignKey(
        "accounts.MT5Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="bonuses",
        help_text="The MT5 account this bonus was applied to."
    )
    amount = models.DecimalField(max_digits=20, decimal_places=2)
    currency = models.CharField(max_length=10, default="USD")

    status = models.CharField(max_length=10, choices=Status.choices, default=Status.GIVEN)
    reason = models.CharField(max_length=200, blank=True)

    granted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="granted_bonuses",
    )
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self) -> str:
        return f"{self.user_id} bonus {self.amount} {self.currency}"


class ClientNotification(models.Model):
    """
    In-app notifications for client portal users (created by admins from System Management).
    One row per recipient.
    """

    class NotificationType(models.TextChoices):
        BONUS = "bonus", "Bonus"
        OFFER = "offer", "Offer"
        ANNOUNCEMENT = "announcement", "Announcement"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="client_notifications",
    )
    title = models.CharField(max_length=255)
    message = models.TextField()
    notification_type = models.CharField(
        max_length=20,
        choices=NotificationType.choices,
        default=NotificationType.ANNOUNCEMENT,
    )
    is_read = models.BooleanField(default=False, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["user", "-created_at"]),
            models.Index(fields=["user", "is_read"]),
        ]

    def __str__(self) -> str:
        return f"{self.user_id}: {self.title[:50]}"


class AccountDeletionRequest(models.Model):
    """A client's request to have their account and personal data erased.

    Deliberately a REQUEST rather than an immediate destructive delete. Two
    reasons, and both are hard constraints rather than preferences:

    1. This is a regulated broker. AML/KYC and transaction records carry a
       statutory retention period that outlives the client relationship, so a
       true "delete everything now" is not lawful. What can be erased is the
       personal profile; the ledger has to survive in a form the regulator
       accepts.
    2. A client may hold open positions, a wallet balance or an in-flight
       withdrawal. Those are financial obligations in both directions and have
       to be settled by a human before anything is erased.

    The store rules are satisfied by the flow, not by immediacy: Apple requires
    that deletion can be *initiated* from inside the app, and Google requires a
    documented route that is reachable without installing it. Both accept a
    verified request with a stated timeline where regulation demands one.

    The grace window mirrors the pattern users already know from Facebook and
    X - the request is reversible from the app until [grace_until] passes, so a
    tap made in anger is recoverable and a genuine departure still completes on
    a predictable date.
    """

    # Long enough that an accidental or angry request can be walked back, short
    # enough to be a credible answer to "when will my data be gone".
    GRACE_DAYS = 30

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        CANCELLED = "CANCELLED", "Cancelled"
        COMPLETED = "COMPLETED", "Completed"
        REJECTED = "REJECTED", "Rejected"

    class Reason(models.TextChoices):
        NO_LONGER_TRADING = "NO_LONGER_TRADING", "No longer trading"
        PRIVACY = "PRIVACY", "Privacy concerns"
        SWITCHING_BROKER = "SWITCHING_BROKER", "Switching to another broker"
        DUPLICATE = "DUPLICATE", "Duplicate account"
        UNHAPPY = "UNHAPPY", "Unhappy with the service"
        OTHER = "OTHER", "Other"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="deletion_requests",
    )
    reason = models.CharField(max_length=32, choices=Reason.choices, default=Reason.OTHER)
    details = models.TextField(blank=True, default="")
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)

    requested_at = models.DateTimeField(default=timezone.now)
    # Cancellable by the client up to this moment; erasure happens after it.
    grace_until = models.DateTimeField()

    # Snapshot of what the client owed or was owed when they asked. Recorded at
    # request time because it is the thing staff must clear, and because
    # balances move - the reviewer needs to see the position as it stood.
    obligations_snapshot = models.JSONField(default=dict, blank=True)

    processed_at = models.DateTimeField(null=True, blank=True)
    processed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="processed_deletion_requests",
    )
    staff_note = models.TextField(blank=True, default="")

    class Meta:
        ordering = ["-requested_at"]
        indexes = [
            models.Index(fields=["status", "grace_until"]),
            models.Index(fields=["user", "status"]),
        ]
        constraints = [
            # One live request per client. Without this, repeated taps on a slow
            # connection queue up duplicates and staff process the same erasure
            # more than once. Partial index so historical rows stay unaffected.
            models.UniqueConstraint(
                fields=["user"],
                condition=models.Q(status="PENDING"),
                name="uniq_pending_deletion_request_per_user",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.user_id}: {self.status} ({self.requested_at:%Y-%m-%d})"

    def save(self, *args, **kwargs):
        if not self.grace_until:
            self.grace_until = self.requested_at + timedelta(days=self.GRACE_DAYS)
        return super().save(*args, **kwargs)

    @property
    def is_cancellable(self) -> bool:
        return self.status == self.Status.PENDING

    @property
    def days_remaining(self) -> int:
        if self.status != self.Status.PENDING:
            return 0
        return max(0, (self.grace_until - timezone.now()).days)
