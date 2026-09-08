from django.conf import settings
from django.db import models
from django.utils import timezone


class IBPlan(models.Model):
    name = models.CharField(max_length=180, unique=True)
    description = models.TextField(blank=True)

    # Flat commission (optional) used by some broker setups
    commission_rate = models.DecimalField(max_digits=10, decimal_places=4, default=0)
    is_active = models.BooleanField(default=True)

    def __str__(self) -> str:
        return self.name


class CommissionGroup(models.Model):
    name = models.CharField(max_length=120, unique=True)
    description = models.TextField(blank=True)

    def __str__(self) -> str:
        return self.name


class IBCommissionRule(models.Model):
    plan = models.ForeignKey(IBPlan, on_delete=models.CASCADE, related_name="commission_rules")
    commission_group = models.ForeignKey(CommissionGroup, on_delete=models.CASCADE, related_name="commission_rules")

    # Backward-compatible default amount (mapped to level1 for old data).
    commission_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level_count = models.PositiveSmallIntegerField(default=1)
    level1 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level2 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level3 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level4 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level5 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level6 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level7 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level8 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level9 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    level10 = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    is_active = models.BooleanField(default=True)

    class Meta:
        unique_together = ("plan", "commission_group")

    def __str__(self) -> str:
        return f"{self.plan} / {self.commission_group}"


class IBApplicationQuestion(models.Model):
    """Configurable questions on the client IB application form (admin-managed)."""

    class InputType(models.TextChoices):
        YES_NO = "YES_NO", "Yes / No"
        TEXT = "TEXT", "Short text"
        TEXTAREA = "TEXTAREA", "Long text"
        SELECT = "SELECT", "Single choice"
        MULTI = "MULTI", "Multiple choice"
        NUMBER = "NUMBER", "Number"

    sort_order = models.PositiveIntegerField(default=0)
    label = models.CharField(max_length=300)
    input_type = models.CharField(max_length=20, choices=InputType.choices, default=InputType.TEXT)
    choices = models.TextField(blank=True, help_text="One option per line (for Single / Multiple choice).")
    required = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["sort_order", "id"]

    def __str__(self) -> str:
        return self.label

    def choice_lines(self) -> list[str]:
        return [ln.strip() for ln in (self.choices or "").splitlines() if ln.strip()]


class IBRequest(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    ib_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="ib_requests_as_ib",
    )
    client_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="ib_requests_as_client",
    )

    plan = models.ForeignKey(IBPlan, on_delete=models.SET_NULL, null=True, blank=True)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)

    requested_at = models.DateTimeField(default=timezone.now)
    processed_at = models.DateTimeField(null=True, blank=True)
    notes = models.TextField(blank=True)
    full_name = models.CharField(max_length=150, blank=True)
    email = models.EmailField(blank=True)
    trading_account = models.CharField(max_length=64, blank=True)
    country = models.CharField(max_length=80, blank=True)
    application_data = models.JSONField(default=dict, blank=True)

    def __str__(self) -> str:
        return f"IBRequest {self.ib_user_id} -> {self.client_user_id} ({self.status})"


class IBProfile(models.Model):

    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="ib_profile")
    ib_level = models.ForeignKey(
        "ib.IBLevel",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="ib_profiles_at_level",
    )
    ib_code = models.CharField(max_length=32, unique=True)
    referral_link = models.CharField(max_length=255, blank=True)
    can_view_clients = models.BooleanField(default=False)
    link_clicks = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:
        return str(self.user_id)


class IBCommissionSettings(models.Model):
    class CommissionType(models.TextChoices):
        SPREAD_ONLY = "SPREAD_ONLY", "Spread Only"
        COMMISSION_ONLY = "COMMISSION_ONLY", "Commission Only"
        SPREAD_AND_COMMISSION = "SPREAD_AND_COMMISSION", "Spread + Commission"

    commission_type = models.CharField(max_length=30, choices=CommissionType.choices, default=CommissionType.SPREAD_AND_COMMISSION)
    commission_per_lot = models.DecimalField(max_digits=12, decimal_places=2, default=10)
    default_percentage = models.DecimalField(max_digits=5, decimal_places=2, default=50)
    use_matrix_commission_first = models.BooleanField(
        default=True,
        help_text="If True, resolve IB payout via IBCommissionMatrixRule (symbol > group > level %). "
        "If False, use legacy IBPairCommission / IBGroupCommission chain first.",
    )
    enable_withdraw_internal = models.BooleanField(default=True)
    enable_withdraw_bank = models.BooleanField(default=True)
    enable_withdraw_crypto = models.BooleanField(default=True)
    enable_withdraw_manual = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class IBPairCommission(models.Model):
    symbol = models.CharField(max_length=30, unique=True)
    percentage = models.DecimalField(max_digits=5, decimal_places=2, default=50)
    is_active = models.BooleanField(default=True)

    def __str__(self) -> str:
        return self.symbol


class IBGroupCommission(models.Model):
    group_name = models.CharField(max_length=60, unique=True)
    percentage = models.DecimalField(max_digits=5, decimal_places=2, default=50)
    is_active = models.BooleanField(default=True)

    def __str__(self) -> str:
        return self.group_name


class IBLevel(models.Model):
    class LevelType(models.TextChoices):
        DIRECT = "DIRECT", "Direct Level"
        PROGRESSION = "PROGRESSION", "Progression Level"

    class MetricWindow(models.TextChoices):
        ALL_TIME = "ALL_TIME", "All Time"
        DAILY = "DAILY", "Daily"
        WEEKLY = "WEEKLY", "Weekly"
        MONTHLY = "MONTHLY", "Monthly"

    class PrimaryProgressMetric(models.TextChoices):
        VOLUME = "VOLUME", "Volume"
        DEPOSIT = "DEPOSIT", "Deposit"
        REFERRALS = "REFERRALS", "Referrals"

    name = models.CharField(max_length=40, unique=True)
    level_type = models.CharField(max_length=20, choices=LevelType.choices, default=LevelType.PROGRESSION)
    target_lots = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    target_deposit = models.DecimalField(max_digits=16, decimal_places=2, default=0)
    target_active_clients = models.PositiveIntegerField(
        default=0,
        help_text="Minimum active referred clients to qualify for this level (0 = ignore).",
    )
    min_referrals = models.PositiveIntegerField(
        default=0,
        help_text="Minimum referrals for this tier (0 = ignore). Synced from target_active_clients if unset.",
    )
    metric_window = models.CharField(
        max_length=20,
        choices=MetricWindow.choices,
        default=MetricWindow.ALL_TIME,
        help_text="Which rolling window to use when comparing volume/deposit/referrals for this level.",
    )
    commission_percentage = models.DecimalField(max_digits=5, decimal_places=2, default=30)
    min_holding_period_seconds = models.PositiveIntegerField(
        default=0,
        help_text="Minimum position hold time for commission (0 = disabled). Requires hold_seconds on trade event.",
    )
    cap_daily = models.DecimalField(max_digits=20, decimal_places=2, default=0, help_text="0 = no cap")
    cap_weekly = models.DecimalField(max_digits=20, decimal_places=2, default=0, help_text="0 = no cap")
    cap_monthly = models.DecimalField(max_digits=20, decimal_places=2, default=0, help_text="0 = no cap")
    cap_per_trade = models.DecimalField(max_digits=20, decimal_places=2, default=0, help_text="0 = no cap")
    downgrade_review_days = models.PositiveIntegerField(default=0, help_text="0 = auto-downgrade disabled")
    downgrade_grace_days = models.PositiveIntegerField(default=0)
    downgrade_to_level = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="downgrade_sources",
    )
    primary_progress_metric = models.CharField(
        max_length=20,
        choices=PrimaryProgressMetric.choices,
        default=PrimaryProgressMetric.VOLUME,
    )
    benefits = models.TextField(blank=True)
    sequence = models.PositiveIntegerField(default=1)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["sequence", "id"]

    def __str__(self) -> str:
        return self.name


class IBLevelReward(models.Model):
    class RewardKind(models.TextChoices):
        CASH = "CASH", "Cash Reward"
        TRIP = "TRIP", "Trip Reward"
        MOBILE = "MOBILE", "Mobile Reward"
        CAR = "CAR", "Car Reward"
        BONUS = "BONUS", "Bonus Reward"

    ib_level = models.ForeignKey(IBLevel, on_delete=models.CASCADE, related_name="rewards")
    reward_kind = models.CharField(max_length=20, choices=RewardKind.choices)
    title = models.CharField(max_length=200)
    value_text = models.CharField(max_length=500, blank=True, default="")
    sort_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["ib_level_id", "sort_order", "id"]


class IBLevelAccountTypeDefault(models.Model):
    """Optional MT5 group defaults per account type when an IB is at this level."""

    ib_level = models.ForeignKey(IBLevel, on_delete=models.CASCADE, related_name="account_type_defaults")
    account_type = models.ForeignKey(
        "admin_panel.TradingAccountType",
        on_delete=models.CASCADE,
        related_name="ib_level_defaults",
    )
    live_mt5_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="ib_level_live_defaults",
    )
    demo_mt5_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="ib_level_demo_defaults",
    )

    class Meta:
        unique_together = [("ib_level", "account_type")]


class IBProgressMetrics(models.Model):
    """Rolling IB qualification metrics (master IB only)."""

    ib_user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="ib_progress_metrics",
    )
    all_time_volume = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    all_time_lots = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    all_time_team_deposit = models.DecimalField(max_digits=22, decimal_places=2, default=0)
    referral_count = models.PositiveIntegerField(default=0)
    daily_volume = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    daily_lots = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    daily_team_deposit = models.DecimalField(max_digits=22, decimal_places=2, default=0)
    daily_referrals = models.PositiveIntegerField(default=0)
    daily_period = models.DateField(null=True, blank=True)
    weekly_volume = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    weekly_lots = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    weekly_team_deposit = models.DecimalField(max_digits=22, decimal_places=2, default=0)
    weekly_referrals = models.PositiveIntegerField(default=0)
    week_start = models.DateField(null=True, blank=True)
    monthly_volume = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    monthly_lots = models.DecimalField(max_digits=22, decimal_places=4, default=0)
    monthly_team_deposit = models.DecimalField(max_digits=22, decimal_places=2, default=0)
    monthly_referrals = models.PositiveIntegerField(default=0)
    month_start = models.DateField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class IBLevelUpgradeRequest(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    ib_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="ib_level_upgrade_requests",
    )
    from_level = models.ForeignKey(
        IBLevel,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="upgrade_requests_from",
    )
    to_level = models.ForeignKey(
        IBLevel,
        on_delete=models.CASCADE,
        related_name="upgrade_requests_to",
    )
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    notes = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    processed_at = models.DateTimeField(null=True, blank=True)
    processed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="ib_level_upgrades_processed",
    )

    class Meta:
        ordering = ["-created_at", "-id"]


class IBCommissionMatrixRule(models.Model):
    """
    CRM-side IB payout rules by IB level, optional account type, symbol group, or single-symbol override.
    """

    class CommissionMode(models.TextChoices):
        PERCENT = "PERCENT", "Percentage"
        FIXED_PER_LOT = "FIXED_PER_LOT", "Fixed per lot"

    ib_level = models.ForeignKey(IBLevel, on_delete=models.CASCADE, related_name="matrix_rules")
    account_type = models.ForeignKey(
        "admin_panel.TradingAccountType",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="ib_matrix_rules",
        help_text="Empty = all account types.",
    )
    symbol_group = models.ForeignKey(
        "admin_panel.SymbolGroup",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="ib_matrix_rules",
    )
    trading_symbol = models.ForeignKey(
        "admin_panel.TradingSymbol",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="ib_matrix_symbol_overrides",
        help_text="Legacy: TradingSymbol row. Prefer mt5_crm_group + matrix_symbol_name for platform-synced symbols.",
    )
    mt5_crm_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="ib_matrix_rules",
        help_text="CRM group (Group Management). When set, rule applies to this group's synced symbol universe.",
    )
    matrix_symbol_name = models.CharField(
        max_length=64,
        blank=True,
        default="",
        help_text="Exact instrument (e.g. EURUSD). Empty = all symbols under mt5_crm_group.",
    )
    commission_mode = models.CharField(
        max_length=20,
        choices=CommissionMode.choices,
        default=CommissionMode.PERCENT,
    )
    value = models.DecimalField(max_digits=14, decimal_places=4, default=0)
    priority = models.PositiveSmallIntegerField(default=0, help_text="Higher matches first.")
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-priority", "id"]

    def __str__(self) -> str:
        if self.mt5_crm_group_id:
            sym = (self.matrix_symbol_name or "").strip() or "*"
            return f"{self.ib_level} / CRM:{self.mt5_crm_group_id}:{sym}"
        return f"{self.ib_level} / {self.trading_symbol or self.symbol_group or 'all'}"


class IBUserCommission(models.Model):
    ib_user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="ib_user_commissions")
    plan = models.ForeignKey(IBPlan, on_delete=models.CASCADE, related_name="ib_user_commissions")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("ib_user", "plan")]
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.ib_user_id} -> {self.plan_id}"


class IBPlanSymbolRebate(models.Model):
    plan = models.ForeignKey(IBPlan, on_delete=models.CASCADE, related_name="symbol_rebates")
    symbol = models.CharField(max_length=64, db_index=True)
    account_type = models.ForeignKey(
        "admin_panel.TradingAccountType",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="plan_symbol_rebates",
        help_text="Optional account type mapping for custom rebates per account type."
    )
    rebate_per_lot = models.DecimalField(max_digits=12, decimal_places=4, default=0)
    is_active = models.BooleanField(default=True)

    class Meta:
        unique_together = ("plan", "symbol", "account_type")

    def __str__(self) -> str:
        atype = f" ({self.account_type.account_name})" if self.account_type else ""
        return f"{self.plan.name} - {self.symbol}{atype}: ${self.rebate_per_lot}/lot"


class ProcessedMT5Deal(models.Model):
    deal_id = models.CharField(max_length=64, unique=True, db_index=True)
    login_id = models.CharField(max_length=64, db_index=True)
    symbol = models.CharField(max_length=32)
    volume_lots = models.DecimalField(max_digits=12, decimal_places=4)
    close_time = models.DateTimeField(db_index=True)
    account_group = models.CharField(max_length=120)
    rebate_rate = models.DecimalField(max_digits=12, decimal_places=4)
    rebate_amount = models.DecimalField(max_digits=20, decimal_places=4)
    ib_user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="processed_deals")
    plan = models.ForeignKey(IBPlan, on_delete=models.SET_NULL, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-close_time"]

    def __str__(self) -> str:
        return f"Deal {self.deal_id} for IB {self.ib_user.email}: ${self.rebate_amount}"

