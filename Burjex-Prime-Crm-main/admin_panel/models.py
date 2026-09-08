from decimal import Decimal

from django.core.exceptions import ValidationError
from django.core.validators import FileExtensionValidator
from django.db import models
from django.utils import timezone

from django.conf import settings

from accounts.models import _fernet_from_secret_key
from django.core.files.storage import FileSystemStorage
from pathlib import Path

_LOGO_DIR = Path(settings.BASE_DIR) / "static" / "uploads" / "logo"
_LOGO_DIR.mkdir(parents=True, exist_ok=True)
logo_storage = FileSystemStorage(
    location=str(_LOGO_DIR),
    base_url="/static/uploads/logo/",
)


class DashboardSettings(models.Model):
    show_my_accounts = models.BooleanField(default=True)
    show_balance = models.BooleanField(default=True)
    show_trading_accounts = models.BooleanField(default=True)
    show_buttons = models.BooleanField(default=True)
    show_profile_menu = models.BooleanField(default=True)

    enable_deposit_button = models.BooleanField(default=True)
    enable_withdraw_button = models.BooleanField(default=True)
    enable_trade_button = models.BooleanField(default=True)
    enable_open_new_account = models.BooleanField(default=True)
    enable_real_demo_tabs = models.BooleanField(default=True)
    enable_account_dropdown_menu = models.BooleanField(default=True)
    enforce_wallet_only_withdrawal = models.BooleanField(default=True)

    # Sidebar controls (mobile + desktop)
    show_sidebar_dashboard = models.BooleanField(default=True)
    show_sidebar_regulations = models.BooleanField(default=True)
    show_sidebar_my_fund = models.BooleanField(default=True)
    show_sidebar_ib_programme = models.BooleanField(default=True)
    show_sidebar_my_wallet = models.BooleanField(default=True)
    show_sidebar_trading = models.BooleanField(default=True)
    show_sidebar_competition = models.BooleanField(default=True)
    show_sidebar_trade_and_win = models.BooleanField(default=True)
    show_sidebar_news = models.BooleanField(default=True)
    show_sidebar_my_data = models.BooleanField(default=True)
    show_sidebar_support = models.BooleanField(default=True)

    # IB Programme submenu controls
    enable_ib_dashboard = models.BooleanField(default=True)
    enable_ib_my_clients = models.BooleanField(default=True)
    enable_ib_tree_chart = models.BooleanField(default=True)
    enable_ib_my_commission = models.BooleanField(default=True)
    enable_ib_withdraw = models.BooleanField(default=True)
    enable_team_deposit_report = models.BooleanField(default=True)
    enable_team_withdraw_report = models.BooleanField(default=True)

    # My Data submenu controls
    enable_deposit_report = models.BooleanField(default=True)
    enable_withdraw_report = models.BooleanField(default=True)
    enable_internal_transfers_report = models.BooleanField(default=True)
    enable_deal_report = models.BooleanField(default=True)
    enable_summary_report = models.BooleanField(default=True)

    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class DemoAccountSettings(models.Model):
    """Admin controls for demo-account provisioning and virtual balance."""

    auto_create_on_signup = models.BooleanField(default=True)
    default_balance = models.DecimalField(max_digits=20, decimal_places=2, default=10000)
    default_leverage = models.PositiveIntegerField(default=500)
    default_account_type = models.ForeignKey(
        "admin_panel.TradingAccountType",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="default_demo_settings",
    )
    default_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="demo_settings_defaults",
    )
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class BrandingSettings(models.Model):
    site_logo = models.ImageField(
        storage=logo_storage,
        upload_to="",
        blank=True,
        null=True,
    )

    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class PortalBrandingSettings(models.Model):
    """
    Separate visual assets for admin CRM vs client portal.
    Files are stored under MEDIA_ROOT/branding/ (served as /media/branding/...).
    """

    admin_logo = models.FileField(upload_to="branding", blank=True, null=True)
    admin_favicon = models.FileField(upload_to="branding", blank=True, null=True)
    admin_login_logo = models.FileField(upload_to="branding", blank=True, null=True)
    admin_sidebar_logo = models.FileField(upload_to="branding", blank=True, null=True)

    user_logo = models.FileField(upload_to="branding", blank=True, null=True)
    user_favicon = models.FileField(upload_to="branding", blank=True, null=True)
    user_login_logo = models.FileField(upload_to="branding", blank=True, null=True)
    user_dashboard_logo = models.FileField(upload_to="branding", blank=True, null=True)
    user_dashboard_logo_dark = models.FileField(
        upload_to="branding",
        blank=True,
        null=True,
        help_text="Optional dark-theme variant for client portal sidebar/header.",
    )

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Portal branding"
        verbose_name_plural = "Portal branding"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class LoginBrandingSettings(models.Model):
    """
    Dedicated login page branding (admin /user vs /admin/login).
    Files stored under MEDIA_ROOT/branding/login/.
    """

    admin_login_logo = models.FileField(upload_to="branding/login", blank=True, null=True)
    admin_login_background = models.FileField(upload_to="branding/login", blank=True, null=True)
    admin_login_title = models.CharField(max_length=120, blank=True, default="")
    admin_login_subtitle = models.CharField(max_length=255, blank=True, default="")
    admin_button_color = models.CharField(max_length=32, default="#0B3C5D")
    admin_background_overlay = models.CharField(max_length=80, default="rgba(15, 23, 42, 0.55)")

    user_login_logo = models.FileField(upload_to="branding/login", blank=True, null=True)
    user_login_background = models.FileField(upload_to="branding/login", blank=True, null=True)
    user_login_title = models.CharField(max_length=120, blank=True, default="")
    user_login_subtitle = models.CharField(max_length=255, blank=True, default="")
    user_button_color = models.CharField(max_length=32, default="#0B3C5D")
    user_background_overlay = models.CharField(max_length=80, default="rgba(15, 23, 42, 0.45)")

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Login branding"
        verbose_name_plural = "Login branding"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class AuthBrandingLogoSize(models.TextChoices):
    SMALL = "small", "Small"
    MEDIUM = "medium", "Medium"
    LARGE = "large", "Large"


class AuthBrandingLogoPosition(models.TextChoices):
    CENTER = "center", "Center"
    LEFT = "left", "Left"
    RIGHT = "right", "Right"


class AdminAuthBrandingSettings(models.Model):
    """Staff-facing auth pages and admin CRM shell company name / colours."""

    company_name = models.CharField(max_length=120, default="Burjex Prime")
    logo = models.ImageField(
        storage=logo_storage,
        upload_to="",
        blank=True,
        null=True,
    )
    background_logo = models.FileField(upload_to="branding/auth/admin", blank=True, null=True)
    primary_color = models.CharField(max_length=20, default="#0B3C5D")
    secondary_color = models.CharField(max_length=20, default="#072A42")
    button_color = models.CharField(max_length=20, default="#0B3C5D")
    panel_background_color = models.CharField(max_length=32, default="#0f172a")
    font_style = models.CharField(max_length=200, default="Inter, system-ui, sans-serif")
    text_size_px = models.PositiveSmallIntegerField(default=14)
    heading_size_px = models.PositiveSmallIntegerField(default=28)
    welcome_text = models.CharField(max_length=120, default="Welcome Back")
    logo_size = models.CharField(
        max_length=16,
        choices=AuthBrandingLogoSize.choices,
        default=AuthBrandingLogoSize.MEDIUM,
    )
    logo_position = models.CharField(
        max_length=16,
        choices=AuthBrandingLogoPosition.choices,
        default=AuthBrandingLogoPosition.CENTER,
    )
    logo_opacity = models.FloatField(default=0.10)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Admin auth branding"
        verbose_name_plural = "Admin auth branding"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class UserAuthBrandingSettings(models.Model):
    """Client-facing auth pages and client portal theme name / colours."""

    company_name = models.CharField(max_length=120, default="Burjex Prime")
    logo = models.ImageField(
        storage=logo_storage,
        upload_to="",
        blank=True,
        null=True,
    )
    background_logo = models.FileField(upload_to="branding/auth/user", blank=True, null=True)
    primary_color = models.CharField(max_length=20, default="#0B3C5D")
    secondary_color = models.CharField(max_length=20, default="#072A42")
    button_color = models.CharField(max_length=20, default="#0B3C5D")
    panel_background_color = models.CharField(max_length=32, default="#0f172a")
    font_style = models.CharField(max_length=200, default="Inter, system-ui, sans-serif")
    text_size_px = models.PositiveSmallIntegerField(default=14)
    heading_size_px = models.PositiveSmallIntegerField(default=28)
    welcome_text = models.CharField(max_length=120, default="Welcome Back")
    logo_size = models.CharField(
        max_length=16,
        choices=AuthBrandingLogoSize.choices,
        default=AuthBrandingLogoSize.MEDIUM,
    )
    logo_position = models.CharField(
        max_length=16,
        choices=AuthBrandingLogoPosition.choices,
        default=AuthBrandingLogoPosition.CENTER,
    )
    logo_opacity = models.FloatField(default=0.10)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "User auth branding"
        verbose_name_plural = "User auth branding"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class SidebarUISettings(models.Model):
    sidebar_bg_color = models.CharField(max_length=30, default="#0B1E3A")
    sidebar_text_color = models.CharField(max_length=30, default="#FFFFFF")
    sidebar_hover_color = models.CharField(max_length=60, default="rgba(255,255,255,0.06)")
    sidebar_active_color = models.CharField(max_length=60, default="rgba(255,255,255,0.10)")
    sidebar_width = models.PositiveIntegerField(default=260)
    font_size = models.PositiveIntegerField(default=15)
    font_family = models.CharField(max_length=120, default="Inter, system-ui")
    animation_enabled = models.BooleanField(default=True)
    logo_size_px = models.PositiveIntegerField(default=34)
    # Optional: overrides Brand Settings logo for the client (/user/) portal sidebar only.
    sidebar_logo = models.ImageField(
        storage=logo_storage,
        upload_to="sidebar",
        blank=True,
        null=True,
    )

    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class UserPortalThemeSettings(models.Model):
    """Admin-configured visual design for the client portal."""

    light_primary_color = models.CharField(
        max_length=32,
        blank=True,
        default="",
        help_text="Primary colour for user portal light mode. Empty = admin panel default.",
    )
    dark_primary_color = models.CharField(
        max_length=32,
        blank=True,
        default="",
        help_text="Primary colour for user portal dark mode. Empty = admin panel default.",
    )
    dark_page_bg_color = models.CharField(max_length=32, blank=True, default="")
    dark_text_color = models.CharField(max_length=32, blank=True, default="")
    dark_muted_text_color = models.CharField(max_length=32, blank=True, default="")
    dark_sidebar_bg_color = models.CharField(max_length=32, blank=True, default="")
    dark_sidebar_text_color = models.CharField(max_length=32, blank=True, default="")
    dark_sidebar_hover_color = models.CharField(max_length=32, blank=True, default="")
    dark_sidebar_active_color = models.CharField(max_length=32, blank=True, default="")
    dark_topbar_bg_color = models.CharField(max_length=32, blank=True, default="")
    dark_topbar_border_color = models.CharField(max_length=32, blank=True, default="")
    dark_topbar_title_color = models.CharField(max_length=32, blank=True, default="")
    dark_button_color = models.CharField(max_length=32, blank=True, default="")
    dark_button_text_color = models.CharField(max_length=32, blank=True, default="")
    dark_button_hover_color = models.CharField(max_length=32, blank=True, default="")
    dark_card_bg_color = models.CharField(max_length=32, blank=True, default="")
    dark_card_border_color = models.CharField(max_length=32, blank=True, default="")
    dark_table_header_bg_color = models.CharField(max_length=32, blank=True, default="")
    dark_table_row_hover_color = models.CharField(max_length=32, blank=True, default="")
    dark_mobile_button_color = models.CharField(max_length=32, blank=True, default="")
    dark_mobile_button_text_color = models.CharField(max_length=32, blank=True, default="")
    sidebar_bg_color = models.CharField(max_length=32, blank=True, default="")
    sidebar_text_color = models.CharField(max_length=32, blank=True, default="")
    sidebar_hover_color = models.CharField(max_length=32, blank=True, default="")
    sidebar_active_color = models.CharField(max_length=32, blank=True, default="")
    topbar_bg_color = models.CharField(max_length=32, blank=True, default="")
    topbar_border_color = models.CharField(max_length=32, blank=True, default="")
    topbar_title_color = models.CharField(max_length=32, blank=True, default="")
    button_color = models.CharField(max_length=32, blank=True, default="")
    button_text_color = models.CharField(max_length=32, blank=True, default="")
    button_hover_color = models.CharField(max_length=32, blank=True, default="")
    card_bg_color = models.CharField(max_length=32, blank=True, default="")
    card_border_color = models.CharField(max_length=32, blank=True, default="")
    card_shadow = models.CharField(max_length=160, blank=True, default="")
    page_bg_color = models.CharField(max_length=32, blank=True, default="")
    text_color = models.CharField(max_length=32, blank=True, default="")
    muted_text_color = models.CharField(max_length=32, blank=True, default="")
    mobile_button_color = models.CharField(max_length=32, blank=True, default="")
    mobile_button_text_color = models.CharField(max_length=32, blank=True, default="")
    table_header_bg_color = models.CharField(max_length=32, blank=True, default="")
    table_row_hover_color = models.CharField(max_length=32, blank=True, default="")
    font_family = models.CharField(max_length=160, blank=True, default="")
    sidebar_width_px = models.PositiveIntegerField(null=True, blank=True)
    logo_size_px = models.PositiveIntegerField(null=True, blank=True)
    border_radius_px = models.PositiveIntegerField(null=True, blank=True)
    body_font_size_px = models.PositiveIntegerField(null=True, blank=True)
    h1_font_size_px = models.PositiveIntegerField(null=True, blank=True)
    h2_font_size_px = models.PositiveIntegerField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "User portal theme"
        verbose_name_plural = "User portal theme"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    @property
    def is_configured(self) -> bool:
        ignored = {"id", "updated_at"}
        for field in self._meta.fields:
            if field.name in ignored:
                continue
            value = getattr(self, field.name, None)
            if isinstance(value, str) and value.strip():
                return True
            if value not in ("", None):
                return True
        return False


class WhiteLabelProfile(models.Model):
    """
    Client portal white-label profile. Only one row should have ``is_active_for_portal``;
    others are ready for multi-brand / multi-company switching (activate per deployment).
    """

    class FontSizePreset(models.TextChoices):
        SMALL = "sm", "Small"
        MEDIUM = "md", "Medium"
        LARGE = "lg", "Large"

    class FontWeightPreset(models.TextChoices):
        NORMAL = "normal", "Normal"
        MEDIUM = "medium", "Medium"
        BOLD = "bold", "Bold"

    class SidebarPosition(models.TextChoices):
        LEFT = "left", "Left"
        RIGHT = "right", "Right"

    name = models.CharField(max_length=120, default="Default")
    slug = models.SlugField(max_length=64, unique=True, blank=True, default="")
    is_active_for_portal = models.BooleanField(default=False, db_index=True)

    primary_color = models.CharField(max_length=32, blank=True, default="")
    secondary_color = models.CharField(max_length=32, blank=True, default="")
    sidebar_bg_color = models.CharField(max_length=32, blank=True, default="")
    header_bg_color = models.CharField(max_length=32, blank=True, default="")
    button_color = models.CharField(max_length=32, blank=True, default="")
    content_text_color = models.CharField(max_length=32, blank=True, default="")

    font_size_preset = models.CharField(
        max_length=8,
        choices=FontSizePreset.choices,
        default=FontSizePreset.MEDIUM,
    )
    font_weight_preset = models.CharField(
        max_length=16,
        choices=FontWeightPreset.choices,
        default=FontWeightPreset.MEDIUM,
    )

    sidebar_position = models.CharField(
        max_length=8,
        choices=SidebarPosition.choices,
        default=SidebarPosition.LEFT,
    )
    sidebar_width_px = models.PositiveIntegerField(null=True, blank=True)
    header_height_px = models.PositiveIntegerField(null=True, blank=True)
    menu_icon_size_px = models.PositiveIntegerField(null=True, blank=True)
    border_radius_px = models.PositiveIntegerField(null=True, blank=True)

    company_name_override = models.CharField(max_length=160, blank=True, default="")
    footer_text = models.TextField(blank=True, default="")

    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return f"{self.name} ({'active' if self.is_active_for_portal else 'inactive'})"

    def save(self, *args, **kwargs):
        if not self.slug:
            from django.utils.text import slugify

            base = slugify(self.name) or "profile"
            candidate = base
            n = 0
            while WhiteLabelProfile.objects.exclude(pk=self.pk).filter(slug=candidate).exists():
                n += 1
                candidate = f"{base}-{n}"
            self.slug = candidate
        if self.is_active_for_portal:
            WhiteLabelProfile.objects.exclude(pk=self.pk).update(is_active_for_portal=False)
        super().save(*args, **kwargs)

    @classmethod
    def get_active_portal_profile(cls):
        return cls.objects.filter(is_active_for_portal=True).first()


class MatchTraderBrokerGroup(models.Model):
    """Catalog of Match-Trader server group names for CRM ↔ platform mapping (dropdown source)."""

    class Category(models.TextChoices):
        TRADING = "TRADING", "Trading group"
        ACCOUNT = "ACCOUNT", "Account group"
        SERVER = "SERVER", "Server"

    sync_category = models.CharField(
        max_length=20,
        choices=Category.choices,
        default=Category.TRADING,
        db_index=True,
        help_text="Source list from broker API sync (trading / account / server).",
    )
    name = models.CharField(
        max_length=120,
        help_text="Exact name on Match-Trader (e.g. standard).",
    )
    description = models.TextField(blank=True, default="")
    is_active = models.BooleanField(default=True)
    crm_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="match_trader_broker_groups",
        help_text="Optional CRM (MT5) group mapping for this Match-Trader row.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["sync_category", "name", "id"]
        verbose_name = "Match-Trader broker group"
        verbose_name_plural = "Match-Trader broker groups"
        constraints = [
            models.UniqueConstraint(
                fields=["sync_category", "name"],
                name="uniq_match_trader_broker_cat_name",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.get_sync_category_display()}: {self.name}"


class TradingAccountType(models.Model):
    class Platform(models.TextChoices):
        MT5 = "MT5", "MT5"
        MT4 = "MT4", "MT4"

    class Currency(models.TextChoices):
        USD = "USD", "USD"
        EUR = "EUR", "EUR"
        GBP = "GBP", "GBP"
        AUD = "AUD", "AUD"

    class SpreadType(models.TextChoices):
        RAW = "RAW", "Raw"
        STANDARD = "STANDARD", "Standard"
        CUSTOM = "CUSTOM", "Custom"

    class PricingType(models.TextChoices):
        SPREAD = "SPREAD", "Spread"
        COMMISSION = "COMMISSION", "Commission"

    class AccountCategory(models.TextChoices):
        LIVE = "LIVE", "Live"
        DEMO = "DEMO", "Demo"

    account_name = models.CharField(max_length=80)
    account_code = models.CharField(max_length=20, unique=True)
    account_category = models.CharField(max_length=10, choices=AccountCategory.choices, default=AccountCategory.LIVE)
    headline = models.CharField(max_length=180, blank=True, default="")
    min_spread = models.DecimalField(max_digits=12, decimal_places=4, default=0)
    account_mode = models.CharField(max_length=30, default="REGULAR_ONLY")
    crm_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="account_types",
        help_text="CRM group from Group Management (maps to MT5 / Match-Trader at group level).",
    )
    display_order = models.PositiveIntegerField(default=0)
    pricing_type = models.CharField(
        max_length=20,
        choices=PricingType.choices,
        default=PricingType.SPREAD,
        help_text="Client portal shows spread or commission only, per selection.",
    )
    spread_value = models.DecimalField(
        max_digits=12,
        decimal_places=4,
        null=True,
        blank=True,
        help_text="Used when pricing type is Spread (e.g. pips/points).",
    )
    description = models.TextField(blank=True, default="")
    platform = models.CharField(max_length=10, choices=Platform.choices, default=Platform.MT5)
    currency = models.CharField(max_length=10, choices=Currency.choices, default=Currency.USD)
    server_name = models.CharField(max_length=180, blank=True, default="")
    manual_group_name = models.CharField(max_length=180, blank=True, default="")
    leverage_options = models.JSONField(default=list, blank=True)
    demo_enabled = models.BooleanField(default=False)
    demo_group = models.ForeignKey(
        "accounts.MT5Group",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="demo_account_types",
        help_text="If this is a Live account with demo enabled, specify the group for demo accounts.",
    )
    user_type = models.CharField(max_length=20, default="INDIVIDUAL")
    suitable_for = models.CharField(max_length=120, blank=True, default="All Traders")
    kyc_requirement = models.CharField(max_length=20, default="NONE")

    # New Demo Balance fields
    min_demo_balance = models.DecimalField(max_digits=12, decimal_places=2, default=100.00, help_text="Minimum initial balance for Demo Accounts")
    max_demo_balance = models.DecimalField(max_digits=12, decimal_places=2, default=100000.00, help_text="Maximum initial balance for Demo Accounts")
    
    geographic_restrictions_enabled = models.BooleanField(default=False)
    geographic_mode = models.CharField(max_length=20, default="ALLOW")
    geographic_countries = models.TextField(blank=True, default="")
    require_email_verified = models.BooleanField(default=False)
    require_phone_verified = models.BooleanField(default=False)
    require_id_document = models.BooleanField(default=False)
    require_proof_of_address = models.BooleanField(default=False)
    max_live_accounts = models.PositiveIntegerField(default=1)
    max_demo_accounts = models.PositiveIntegerField(default=1)
    demo_expiry_days = models.PositiveIntegerField(default=0)
    max_total_balance = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    max_single_deposit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    min_first_deposit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    max_withdrawal_per_request = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    max_withdrawal_per_day = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    max_withdrawal_requests_per_day = models.PositiveIntegerField(default=0)
    inactivity_fee_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    inactivity_fee_after_days = models.PositiveIntegerField(default=0)
    maintenance_fee_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    min_deposit = models.DecimalField(max_digits=16, decimal_places=2, default=0)
    max_leverage = models.PositiveIntegerField(default=500)
    commission = models.DecimalField(
        max_digits=16,
        decimal_places=2,
        default=0,
        help_text="Commission per lot when pricing type is Commission.",
    )
    spread_type = models.CharField(max_length=20, choices=SpreadType.choices, default=SpreadType.STANDARD)
    spread = models.CharField(max_length=50, blank=True, default="")
    swap_free = models.BooleanField(default=False)
    stop_out_level = models.PositiveIntegerField(default=30)
    margin_call_level = models.PositiveIntegerField(default=50)
    is_active = models.BooleanField(default=True)
    is_default = models.BooleanField(
        default=False,
        help_text="True for CRM-seeded templates (STANDARD/PRO/RAW/VIP). Deleting them is permanent; requests no longer recreate removed types.",
    )
    mt5_symbol_suffix = models.CharField(
        max_length=32,
        blank=True,
        default="",
        help_text="Suffix appended to base symbols for this account type (e.g. .PRO, .ECN). Used for symbol matching.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["display_order", "account_name", "-created_at"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"{self.account_name} ({self.platform})"

    def portal_pricing_spread_text(self) -> str:
        if self.spread_value is not None:
            return str(self.spread_value)
        return (self.spread or "").strip() or "—"

    def portal_pricing_commission_text(self) -> str:
        return str(self.commission or 0)


class TradingAccountRequest(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        APPROVED = "APPROVED", "Approved"
        REJECTED = "REJECTED", "Rejected"

    user = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="trading_account_requests")
    account_type = models.ForeignKey(TradingAccountType, on_delete=models.CASCADE, related_name="requests")
    currency = models.CharField(max_length=10, default="USD")
    leverage = models.PositiveIntegerField(default=100)
    status = models.CharField(max_length=15, choices=Status.choices, default=Status.PENDING)
    admin_note = models.CharField(max_length=255, blank=True, default="")
    created_mt5_account = models.ForeignKey(
        "accounts.MT5Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="created_from_requests",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    processed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"Request #{self.id} - {self.user.email}"


class SymbolGroup(models.Model):
    """Logical grouping for symbols (Forex, Metals, …) — used by IB commission rules."""

    name = models.CharField(max_length=120, unique=True)
    slug = models.SlugField(max_length=120, unique=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class TradingSymbol(models.Model):
    class SymbolType(models.TextChoices):
        FOREX = "FOREX", "Forex"
        METAL = "METAL", "Metal"
        CRYPTO = "CRYPTO", "Crypto"
        INDICES = "INDICES", "Indices"
        STOCKS = "STOCKS", "Stocks"

    code = models.CharField(max_length=40, db_index=True)
    display_name = models.CharField(max_length=160, blank=True, default="")
    symbol_type = models.CharField(max_length=20, choices=SymbolType.choices, default=SymbolType.FOREX)
    group = models.ForeignKey(SymbolGroup, null=True, blank=True, on_delete=models.SET_NULL, related_name="symbols")
    suffix = models.CharField(
        max_length=32,
        blank=True,
        default="",
        help_text="Optional suffix for MT5 (e.g. .ecn). Stored separately from base code.",
    )
    digits = models.PositiveSmallIntegerField(null=True, blank=True)
    contract_size = models.DecimalField(max_digits=20, decimal_places=4, null=True, blank=True)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["code", "suffix"]
        constraints = [
            models.UniqueConstraint(fields=["code", "suffix"], name="uniq_tradingsymbol_code_suffix"),
        ]

    def mt5_symbol(self) -> str:
        base = (self.code or "").strip().upper()
        suf = (self.suffix or "").strip()
        return f"{base}{suf}" if suf else base

    def __str__(self) -> str:
        return self.mt5_symbol()


class CrmGroupSymbol(models.Model):
    """
    Platform-synced instrument per CRM group (accounts.MT5Group is the master CRM group row).
    Populated by Match-Trader / MT5 Web API / X9 sync — not manually edited in production UI.
    """

    class SourcePlatform(models.TextChoices):
        MATCH_TRADER = "MATCH_TRADER", "Match-Trader"
        MT5 = "MT5", "MT5"
        X9 = "X9", "X9"
        UNKNOWN = "UNKNOWN", "Unknown"

    mt5_group = models.ForeignKey(
        "accounts.MT5Group",
        on_delete=models.CASCADE,
        related_name="crm_synced_symbols",
    )
    symbol_name = models.CharField(max_length=64, db_index=True)
    source_platform = models.CharField(
        max_length=20,
        choices=SourcePlatform.choices,
        default=SourcePlatform.UNKNOWN,
    )
    raw_payload = models.JSONField(default=dict, blank=True)
    synced_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["mt5_group_id", "symbol_name"]
        constraints = [
            models.UniqueConstraint(fields=["mt5_group", "symbol_name"], name="uniq_crmgroupsymbol_group_name"),
        ]

    def __str__(self) -> str:
        return f"{self.symbol_name} ({self.mt5_group_id})"


class CrmGroupSyncStatus(models.Model):
    """Last symbol sync attempt per CRM group (MT5Group)."""

    mt5_group = models.OneToOneField(
        "accounts.MT5Group",
        on_delete=models.CASCADE,
        related_name="crm_symbol_sync_status",
    )
    last_attempt_at = models.DateTimeField(null=True, blank=True)
    last_success_at = models.DateTimeField(null=True, blank=True)
    last_error = models.TextField(blank=True, default="")
    symbol_count = models.PositiveIntegerField(default=0)

    def __str__(self) -> str:
        return f"Sync {self.mt5_group_id}"


class BrokerCrmCommissionSettings(models.Model):
    """Broker-side per-lot charge tracked in CRM for testing (production often uses MT5 only)."""

    enable_crm_lot_commission = models.BooleanField(default=False)
    notes = models.TextField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "Broker CRM commission (testing)"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class SimulatedIBTrade(models.Model):
    """Admin-only simulated trade for IB commission / markup estimates."""

    created_by = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="simulated_trades_created",
    )
    client = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="simulated_trades_as_client")
    ib_user = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="simulated_trades_as_ib",
    )
    symbol = models.CharField(max_length=48)
    lots = models.DecimalField(max_digits=14, decimal_places=4)
    profit_per_lot = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    commission_per_lot_client = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    ib_commission_estimate = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    company_profit_estimate = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    account_type = models.ForeignKey(TradingAccountType, null=True, blank=True, on_delete=models.SET_NULL)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"Sim {self.client_id} {self.symbol} {self.lots} lots"


class TradingAccount(models.Model):
    class Status(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        DISABLED = "DISABLED", "Disabled"

    user = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="trading_accounts")
    account_number = models.CharField(max_length=32, unique=True)
    account_type = models.CharField(max_length=80)
    leverage = models.PositiveIntegerField(default=100)
    currency = models.CharField(max_length=10, default="USD")
    balance = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.ACTIVE)
    server = models.CharField(max_length=120, blank=True, default="MT5-Live")
    mt5_account = models.OneToOneField(
        "accounts.MT5Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="trading_account_row",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "trading_accounts"
        ordering = ["-created_at"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"{self.account_number} ({self.user_id})"


class ComplianceSettings(models.Model):
    # Identity settings
    enable_identity_verification = models.BooleanField(default=True)
    identity_allow_reupload = models.BooleanField(default=True)
    identity_lock_after_approval = models.BooleanField(default=True)
    identity_require_expiry = models.BooleanField(default=True)
    identity_allow_multiple_documents = models.BooleanField(default=False)

    # Address settings (optional by default — identity-only KYC matches mobile)
    enable_address_verification = models.BooleanField(default=False)
    address_allow_reupload = models.BooleanField(default=True)
    address_lock_after_approval = models.BooleanField(default=True)

    # Bank/Crypto settings
    enable_bank_verification = models.BooleanField(default=True)
    bank_lock_after_approval = models.BooleanField(default=True)
    enable_crypto_verification = models.BooleanField(default=True)
    crypto_lock_after_approval = models.BooleanField(default=True)

    # UI settings
    show_compliance_section = models.BooleanField(default=True)
    show_bank_section = models.BooleanField(default=True)
    show_crypto_section = models.BooleanField(default=True)

    otp_email_enabled = models.BooleanField(default=False)
    otp_sms_enabled = models.BooleanField(default=False)
    otp_google_auth_future = models.BooleanField(default=False)
    withdrawal_requires_compliance = models.BooleanField(default=True)
    allow_withdraw_without_kyc = models.BooleanField(
        default=False,
        help_text="If enabled, clients may withdraw without approved identity KYC.",
    )
    allow_deposit_without_kyc = models.BooleanField(
        default=True,
        help_text="If disabled, clients need approved KYC before depositing.",
    )
    allow_ib_request_without_kyc = models.BooleanField(
        default=False,
        help_text="If enabled, clients may submit IB applications without approved KYC.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class MaintenanceSettings(models.Model):
    enabled = models.BooleanField(default=False)
    secret_bypass_key = models.CharField(max_length=255, blank=True, default="")
    title = models.CharField(max_length=160, blank=True, default="System Under Maintenance")
    message = models.TextField(
        blank=True,
        default="We are currently performing scheduled maintenance. Please check back shortly.",
    )
    estimated_time = models.CharField(max_length=120, blank=True, default="")
    support_email = models.EmailField(blank=True, default="")
    allow_whitelist_ip = models.BooleanField(default=False)
    whitelist_ips = models.TextField(
        blank=True,
        default="",
        help_text="Comma-separated IPs that can bypass maintenance mode.",
    )
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class UserActivitySettings(models.Model):
    class ActivePeriodPreset(models.TextChoices):
        DAYS_7 = "7", "7 Days"
        DAYS_15 = "15", "15 Days"
        DAYS_30 = "30", "30 Days"
        CUSTOM = "CUSTOM", "Custom"

    active_period_preset = models.CharField(
        max_length=10,
        choices=ActivePeriodPreset.choices,
        default=ActivePeriodPreset.DAYS_30,
    )
    custom_active_days = models.PositiveIntegerField(default=30)
    active_days = models.PositiveIntegerField(
        default=15,
        help_text="Users count as active if they logged in within this many days (and meet balance rules).",
    )
    min_balance = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("1.00"),
        help_text="Minimum live MT5 account balance (USD) for active-user rules.",
    )
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    def effective_active_days(self) -> int:
        """Prefer django.conf.settings.active_days when set; otherwise model field (min 1)."""
        model_days = max(int(self.active_days or 15), 1)
        return max(int(getattr(settings, "active_days", model_days)), 1)

    def effective_min_balance(self) -> Decimal:
        return Decimal(str(self.min_balance or Decimal("1.00")))


class RiskMonitorSettings(models.Model):
    high_frequency_threshold = models.PositiveIntegerField(default=30)
    
    # New thresholds for Risk Monitor Module
    short_duration_max_seconds = models.PositiveIntegerField(default=30)
    high_profit_threshold = models.DecimalField(max_digits=20, decimal_places=2, default=500.00)
    large_lot_threshold = models.DecimalField(max_digits=10, decimal_places=2, default=3.00)
    hft_trades_per_minute = models.PositiveIntegerField(default=10)
    single_symbol_monitoring_days = models.PositiveIntegerField(default=7)
    hedging_time_window_minutes = models.PositiveIntegerField(default=60)
    multiple_ip_monitoring_days = models.PositiveIntegerField(default=1)
    enable_country_mismatch = models.BooleanField(default=True)
    
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class RequiredDocument(models.Model):
    class Category(models.TextChoices):
        IDENTITY = "IDENTITY", "Identity"
        ADDRESS = "ADDRESS", "Address"

    name = models.CharField(max_length=120)
    category = models.CharField(max_length=20, choices=Category.choices, default=Category.IDENTITY)
    is_enabled = models.BooleanField(default=True)
    is_required = models.BooleanField(default=True)
    is_custom = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["category", "name"]
        unique_together = [("name", "category")]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"{self.category}: {self.name}"


class BankField(models.Model):
    field_key = models.CharField(max_length=40, unique=True)
    label = models.CharField(max_length=120)
    is_enabled = models.BooleanField(default=True)
    is_required = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["id"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return self.label


class CryptoNetwork(models.Model):
    code = models.CharField(max_length=40, unique=True)
    label = models.CharField(max_length=120)
    is_enabled = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["label"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return self.label


class SignupSettings(models.Model):
    class FieldMode(models.TextChoices):
        REQUIRED = "REQUIRED", "Required"
        OPTIONAL = "OPTIONAL", "Optional"
        HIDDEN = "HIDDEN", "Hidden"

    first_name_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.REQUIRED)
    last_name_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.REQUIRED)
    full_name_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.HIDDEN)
    email_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.REQUIRED)
    phone_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.REQUIRED)
    password_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.REQUIRED)
    country_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.OPTIONAL)
    address_mode = models.CharField(max_length=10, choices=FieldMode.choices, default=FieldMode.OPTIONAL)
    captcha_enabled = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class EmailVerificationSettings(models.Model):
    enabled = models.BooleanField(default=True)
    required = models.BooleanField(default=True)
    token_expiry_hours = models.PositiveIntegerField(default=24)
    allow_resend = models.BooleanField(default=True)
    email_template = models.TextField(
        default=(
            "Hello {{name}}\n\nPlease verify your email:\n\n{{verify_url}}\n\nThank you."
        )
    )
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class SMTPSettings(models.Model):
    smtp_host = models.CharField(max_length=120, blank=True, default="")
    smtp_port = models.PositiveIntegerField(default=587)
    smtp_username = models.CharField(max_length=255, blank=True, default="")
    smtp_password = models.CharField(max_length=255, blank=True, default="")
    sender_email = models.EmailField(blank=True, default="")
    sender_name = models.CharField(max_length=120, blank=True, default="")
    use_tls = models.BooleanField(default=True)
    use_ssl = models.BooleanField(default=False)
    imap_host = models.CharField(max_length=120, blank=True, default="")
    imap_port = models.PositiveIntegerField(default=993)
    imap_username = models.CharField(max_length=255, blank=True, default="")
    imap_password = models.CharField(max_length=255, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class EmailLog(models.Model):
    class Status(models.TextChoices):
        SENT = "SENT", "Sent"
        FAILED = "FAILED", "Failed"

    user = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True, blank=True, related_name="email_logs")
    email = models.EmailField()
    subject = models.CharField(max_length=255)
    body = models.TextField(blank=True, default="")
    event_key = models.CharField(max_length=80, blank=True, default="", db_index=True)
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.SENT)
    error_message = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"{self.email} - {self.subject}"


class EmailSystemSettings(models.Model):
    """Global email automation master switch."""

    master_enabled = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "Email system settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class EmailGlobalLayout(models.Model):
    """Master wrapper: logo, header/footer snippets, footer legal block. Body comes from each EmailTemplate."""

    wrap_enabled = models.BooleanField(default=True)
    site_base_url = models.CharField(
        max_length=255,
        blank=True,
        default="",
        help_text="Public site URL (e.g. https://broker.com) for absolute image links in emails.",
    )
    company_logo = models.ImageField(upload_to="email_layout/logos/", blank=True, null=True)
    header_html = models.TextField(blank=True, default="", help_text="Optional HTML below logo (supports {{variables}}).")
    footer_html = models.TextField(blank=True, default="", help_text="Optional HTML below the footer block.")
    risk_disclaimer = models.TextField(
        blank=True,
        default="Risk disclaimer: Trading forex and CFDs involves substantial risk and is not suitable for all investors.",
    )
    company_address = models.TextField(blank=True, default="")
    support_email = models.CharField(max_length=254, blank=True, default="")
    website_url = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_global_layout"
        verbose_name_plural = "Email global layouts"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


def _validate_email_logo_file_size(file_obj) -> None:
    if not file_obj:
        return
    size = getattr(file_obj, "size", None)
    if size is None and hasattr(file_obj, "file") and getattr(file_obj, "file", None):
        try:
            size = file_obj.file.size
        except Exception:
            size = None
    if size is not None and size > 2 * 1024 * 1024:
        raise ValidationError("Logo size must be under 2MB.")


_EMAIL_LOGO_FIELD_VALIDATORS = [
    FileExtensionValidator(allowed_extensions=["png", "jpg", "jpeg", "svg"]),
    _validate_email_logo_file_size,
]


class EmailTemplateSettings(models.Model):
    """Header branding for all wrapped transactional emails (solo row)."""

    class LogoPosition(models.TextChoices):
        LEFT = "left", "Left"
        CENTER = "center", "Center"
        RIGHT = "right", "Right"

    class LogoSize(models.TextChoices):
        SMALL = "small", "Small"
        MEDIUM = "medium", "Medium"
        LARGE = "large", "Large"

    email_logo = models.FileField(
        upload_to="email_template_settings/logos/",
        blank=True,
        null=True,
        max_length=500,
        help_text="PNG, JPG, or SVG. Used in email headers when set.",
        validators=_EMAIL_LOGO_FIELD_VALIDATORS,
    )
    logo_position = models.CharField(
        max_length=10,
        choices=LogoPosition.choices,
        default=LogoPosition.CENTER,
    )
    logo_size = models.CharField(
        max_length=10,
        choices=LogoSize.choices,
        default=LogoSize.MEDIUM,
    )
    header_color = models.CharField(max_length=7, default="#0B1C3F")
    text_color = models.CharField(
        max_length=7,
        default="#FFFFFF",
        help_text="Company name text on the email header bar.",
    )
    button_color = models.CharField(
        max_length=7,
        default="#0B3C5D",
        help_text="Primary button color used in wrapped email templates.",
    )
    company_name_override = models.CharField(
        max_length=180,
        blank=True,
        default="",
        help_text="Optional company name override for all outgoing transactional emails.",
    )
    show_company_name = models.BooleanField(
        default=True,
        help_text="When a logo is set, also show the company name under the logo.",
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_template_settings"
        verbose_name_plural = "Email template settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    def __str__(self) -> str:
        return "Email template settings"


class EmailPurpose(models.Model):
    """Admin-defined email purposes for template routing."""

    purpose_name = models.CharField(max_length=120, unique=True)
    purpose_key = models.SlugField(max_length=80, unique=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "email_purposes"
        ordering = ["purpose_name"]

    def __str__(self) -> str:
        return self.purpose_name


class EmailTemplate(models.Model):
    """Admin-editable templates for automated notifications."""

    class TemplateType(models.TextChoices):
        FORGOT_PASSWORD = "forgot_password", "Forgot Password"
        SIGNUP_WELCOME = "signup_welcome", "Signup Welcome"
        EMAIL_VERIFICATION = "email_verification", "Email Verification"
        OTP_VERIFICATION = "otp_verification", "OTP Verification"
        KYC_APPROVED = "kyc_approved", "KYC Approved"
        KYC_REJECTED = "kyc_rejected", "KYC Rejected"
        DEPOSIT_CONFIRMATION = "deposit_confirmation", "Deposit Confirmation"
        WITHDRAWAL_CONFIRMATION = "withdrawal_confirmation", "Withdrawal Confirmation"
        ACCOUNT_CREATED = "account_created", "Account Created"
        CUSTOM = "custom", "Custom Template"

    class EventKey(models.TextChoices):
        ACCOUNT_CREATED = "account_created", "Account Created"
        EMAIL_VERIFICATION = "email_verification", "Email Verification"
        EMAIL_VERIFIED = "email_verified", "Email Verified"
        FORGOT_PASSWORD = "forgot_password", "Forgot Password"
        KYC_APPROVED = "kyc_approved", "KYC Approved"
        KYC_REJECTED = "kyc_rejected", "KYC Rejected"
        KYC_SUBMITTED = "kyc_submitted", "KYC Submitted"
        IDENTITY_SUBMITTED = "identity_submitted", "Identity Documents Submitted"
        IDENTITY_APPROVED = "identity_approved", "Identity Verification Approved"
        IDENTITY_REJECTED = "identity_rejected", "Identity Verification Rejected"
        ADDRESS_SUBMITTED = "address_submitted", "Address Documents Submitted"
        ADDRESS_APPROVED = "address_approved", "Address Verification Approved"
        ADDRESS_REJECTED = "address_rejected", "Address Verification Rejected"
        ACCOUNT_VERIFIED = "account_verified", "Account Fully Verified"
        WITHDRAWAL_APPROVED = "withdrawal_approved", "Withdrawal Approved"
        WITHDRAWAL_REJECTED = "withdrawal_rejected", "Withdrawal Rejected"
        WITHDRAWAL_SUBMITTED = "withdrawal_submitted", "Withdrawal Submitted"
        DEPOSIT_APPROVED = "deposit_approved", "Deposit Approved"
        DEPOSIT_REJECTED = "deposit_rejected", "Deposit Rejected"
        DEPOSIT_SUBMITTED = "deposit_submitted", "Deposit Submitted"
        IB_REQUEST_APPROVED = "ib_request_approved", "IB Request Approved"
        IB_REQUEST_REJECTED = "ib_request_rejected", "IB Request Rejected"
        SIGNUP_WELCOME = "signup_welcome", "Signup Welcome"
        PASSWORD_RESET = "password_reset", "Password Reset"
        ACCOUNT_APPROVED = "account_approved", "Account Approved"
        REAL_ACCOUNT_CREATED = "real_account_created", "Real Account Created"
        DEMO_ACCOUNT_CREATED = "demo_account_created", "Demo Account Created"
        OTP_VERIFICATION = "otp_verification", "OTP Verification"

    class Category(models.TextChoices):
        USER = "user", "User Emails"
        ADMIN = "admin", "Admin Emails"
        PARTNER = "partner", "Partner Emails"

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        INACTIVE = "inactive", "Inactive"

    template_type = models.CharField(
        max_length=40,
        choices=TemplateType.choices,
        default=TemplateType.CUSTOM,
        db_index=True,
    )
    event_key = models.CharField(
        max_length=64,
        unique=True,
        blank=True,
        default="",
        help_text="Routing key used by send_event_email (e.g. forgot_password, deposit_submitted).",
    )
    name = models.CharField(max_length=120)
    slug = models.SlugField(max_length=140, unique=True, db_index=True, blank=True, default="")
    subject = models.CharField(max_length=255)
    category = models.CharField(max_length=20, choices=Category.choices, default=Category.USER, db_index=True)
    purpose = models.ForeignKey(
        "EmailPurpose",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="templates",
    )
    html_content = models.TextField(
        help_text="Use variables: {{name}}, {{email}}, {{amount}}, {{reason}}, {{company_name}}, {{date}}, {{account_number}}, {{verify_url}}, {{upload_url}}",
    )
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.ACTIVE, db_index=True)
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_templates"
        ordering = ["category", "name", "event_key"]

    def __str__(self) -> str:
        return self.name

    def save(self, *args, **kwargs):
        if self.status not in {self.Status.ACTIVE, self.Status.INACTIVE}:
            self.status = self.Status.ACTIVE if self.is_active else self.Status.INACTIVE
        self.is_active = self.status == self.Status.ACTIVE
        if not self.slug:
            from django.utils.text import slugify

            raw = self.event_key or self.name or "template"
            base = slugify(raw)[:120] or "template"
            candidate = base
            idx = 0
            while EmailTemplate.objects.exclude(pk=self.pk).filter(slug=candidate).exists():
                idx += 1
                candidate = f"{base[:110]}-{idx}"
            self.slug = candidate
        super().save(*args, **kwargs)

    @property
    def body(self) -> str:
        # Backward compatibility for existing callsites.
        return self.html_content

    @body.setter
    def body(self, value: str) -> None:
        self.html_content = value or ""

    @property
    def send_enabled(self) -> bool:
        # Backward compatibility for existing callsites.
        return self.status == self.Status.ACTIVE

    @send_enabled.setter
    def send_enabled(self, value: bool) -> None:
        enabled = bool(value)
        self.is_active = enabled
        self.status = self.Status.ACTIVE if enabled else self.Status.INACTIVE


class EmailTemplateMapping(models.Model):
    """Explicit mapping for Purpose -> Template assignment."""

    purpose = models.OneToOneField(
        "EmailPurpose",
        on_delete=models.CASCADE,
        related_name="template_mapping",
    )
    template = models.ForeignKey(
        "EmailTemplate",
        on_delete=models.CASCADE,
        related_name="purpose_mappings",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_template_mapping"
        ordering = ["purpose__purpose_name"]

    def __str__(self) -> str:
        return f"{self.purpose} -> {self.template}"


class TagCategory(models.Model):
    class Type(models.TextChoices):
        RISK = "risk", "Risk Tags"
        ACCOUNT_TYPE = "account_type", "Account Type Tags"
        IB_LEVEL = "ib_level", "IB Level Tags"
        LEAD_HANDLING = "lead_handling", "Lead Handling Tags"
        FEATURE = "feature", "Feature Tags"
        CLIENT = "client", "Client Tags"

    name = models.CharField(max_length=120)
    type = models.CharField(max_length=40, choices=Type.choices, unique=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class Tag(models.Model):
    name = models.CharField(max_length=120)
    description = models.TextField(blank=True, default="")
    category = models.ForeignKey(TagCategory, on_delete=models.CASCADE, related_name="tags")
    color = models.CharField(max_length=20, default="#64748b")
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["category__name", "name"]
        constraints = [
            models.UniqueConstraint(fields=["category", "name"], name="uniq_tag_category_name"),
        ]

    def __str__(self) -> str:
        return self.name


class UserTag(models.Model):
    user = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="user_tags")
    tag = models.ForeignKey(Tag, on_delete=models.CASCADE, related_name="user_tags")
    assigned_by = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="assigned_user_tags",
    )
    notes = models.CharField(max_length=255, blank=True, default="")
    assigned_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-assigned_at"]
        constraints = [
            models.UniqueConstraint(fields=["user", "tag"], name="uniq_user_tag"),
        ]

    def __str__(self) -> str:
        return f"{self.user_id}:{self.tag_id}"


class StatusBadgeSettings(models.Model):
    """
    Admin-configurable labels/colors for user list status badges (merged with code defaults in views).
    """

    data = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "Status badge settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class WalletTreasurySettings(models.Model):
    """Central wallet controls (Settings → Treasury → Wallet)."""

    wallet_system_enabled = models.BooleanField(default=True)
    auto_create_wallet_on_registration = models.BooleanField(default=True)

    allow_deposits_to_wallet = models.BooleanField(default=True)
    wallet_min_deposit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_max_deposit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_deposit_maintenance = models.BooleanField(default=False)

    allow_withdrawals_from_wallet = models.BooleanField(default=True)
    wallet_min_withdraw = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_max_withdraw = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_daily_withdraw_limit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    wallet_withdraw_maintenance = models.BooleanField(default=False)

    allow_wallet_to_trading = models.BooleanField(default=True)
    allow_trading_to_wallet = models.BooleanField(default=True)
    allow_p2p_transfers = models.BooleanField(default=True)

    require_kyc_wallet_withdraw = models.BooleanField(default=False)
    require_2fa_wallet_withdraw = models.BooleanField(default=False)
    wallet_withdraw_cooldown_minutes = models.PositiveIntegerField(default=0)
    wallet_max_pending_withdrawals = models.PositiveIntegerField(default=0)

    show_wallet_dashboard = models.BooleanField(default=True)
    wallet_in_total_balance = models.BooleanField(default=True)
    show_wallet_sidebar = models.BooleanField(default=True)

    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "Wallet treasury settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class TransferTreasurySettings(models.Model):
    """Internal / P2P transfer controls (Settings → Treasury → Transfer)."""

    class FeeType(models.TextChoices):
        FIXED = "FIXED", "Fixed"
        PERCENT = "PERCENT", "Percentage"

    class ProcessingMode(models.TextChoices):
        INSTANT = "INSTANT", "Instant"
        MANUAL = "MANUAL", "Manual"

    internal_transfers_enabled = models.BooleanField(default=True)
    internal_maintenance_mode = models.BooleanField(default=False)
    internal_min_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    internal_max_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    internal_fee_type = models.CharField(max_length=15, choices=FeeType.choices, default=FeeType.FIXED)
    internal_fee_value = models.DecimalField(max_digits=20, decimal_places=4, default=0)
    internal_daily_limit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    internal_cooldown_minutes = models.PositiveIntegerField(default=0)
    internal_processing_mode = models.CharField(
        max_length=15, choices=ProcessingMode.choices, default=ProcessingMode.INSTANT
    )

    p2p_enabled = models.BooleanField(default=True)
    p2p_min_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    p2p_max_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    p2p_fee_value = models.DecimalField(max_digits=20, decimal_places=4, default=0)
    p2p_daily_limit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    p2p_cooldown_minutes = models.PositiveIntegerField(default=0)

    transfer_require_kyc = models.BooleanField(default=False)
    transfer_require_2fa = models.BooleanField(default=False)
    transfer_max_pending = models.PositiveIntegerField(default=0)

    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "Transfer treasury settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


def _org_public_id() -> str:
    import uuid

    return f"ORG-{uuid.uuid4().hex[:10].upper()}"


class OrganizationProfileSettings(models.Model):
    organization_id = models.CharField(max_length=24, unique=True, default=_org_public_id, editable=False)
    domain = models.CharField(max_length=160, blank=True, default="")
    application_name = models.CharField(max_length=140, blank=True, default="")
    company_name = models.CharField(max_length=160, blank=True, default="")
    registration_number = models.CharField(max_length=120, blank=True, default="")
    support_email = models.EmailField(blank=True, default="")
    primary_phone = models.CharField(max_length=40, blank=True, default="")
    website_url = models.URLField(blank=True, default="")
    client_area_url = models.URLField(blank=True, default="")
    application_timezone = models.CharField(max_length=64, blank=True, default="UTC")
    business_license = models.CharField(max_length=180, blank=True, default="")
    incorporation_country = models.CharField(max_length=120, blank=True, default="")
    registered_address = models.TextField(blank=True, default="")
    logo = models.ImageField(upload_to="organization/", blank=True, null=True)
    # Mobile / portal asset slots (System Management → Branding).
    app_icon = models.ImageField(
        upload_to="organization/icons/",
        blank=True,
        null=True,
        help_text="App launcher icon. Recommended 1024×1024 px PNG.",
    )
    login_logo = models.ImageField(
        upload_to="organization/login/",
        blank=True,
        null=True,
        help_text="Sign-in / splash logo. Recommended 600×200 px (or square mark).",
    )
    sidebar_logo = models.ImageField(
        upload_to="organization/sidebar/",
        blank=True,
        null=True,
        help_text="Sidebar / drawer logo. Recommended 200×200 px.",
    )
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class LegalAgreementSettings(models.Model):
    icon = models.ImageField(upload_to="legal/", blank=True, null=True)
    name = models.CharField(max_length=140, blank=True, default="Legal Agreements")
    tagline = models.CharField(max_length=255, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class LegalDocument(models.Model):
    class Category(models.TextChoices):
        ESSENTIAL = "ESSENTIAL", "Essential Documents"
        TRADING = "TRADING", "Trading Policies"
        REGIONAL = "REGIONAL", "Regional Policies"
        ADDITIONAL = "ADDITIONAL", "Additional Policies"
        CUSTOM = "CUSTOM", "Custom Documents"

    category = models.CharField(max_length=20, choices=Category.choices, db_index=True)
    title = models.CharField(max_length=180)
    link = models.URLField(blank=True, default="")
    file = models.FileField(upload_to="legal_documents/", blank=True, null=True)
    order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["category", "order", "id"]
        constraints = [
            models.UniqueConstraint(fields=["category", "title"], name="uniq_legal_document_category_title"),
        ]

    def __str__(self) -> str:
        return f"{self.get_category_display()}: {self.title}"


class LegalAgreementsSettings(models.Model):
    icon = models.ImageField(upload_to="legal/", blank=True, null=True)
    name = models.CharField(max_length=140, blank=True, default="")
    tagline = models.CharField(max_length=255, blank=True, default="")
    terms_conditions_url = models.URLField(blank=True, default="")
    privacy_policy_url = models.URLField(blank=True, default="")
    client_agreement_url = models.URLField(blank=True, default="")
    risk_disclosure_url = models.URLField(blank=True, default="")
    aml_policy_url = models.URLField(blank=True, default="")
    cookie_policy_url = models.URLField(blank=True, default="")
    disclaimer_url = models.URLField(blank=True, default="")
    bonus_credit_policy_url = models.URLField(blank=True, default="")
    withdrawal_policy_url = models.URLField(blank=True, default="")
    deposit_policy_url = models.URLField(blank=True, default="")
    us_client_policy_url = models.URLField(blank=True, default="")
    eu_uk_client_policy_url = models.URLField(blank=True, default="")
    complaints_policy_url = models.URLField(blank=True, default="")
    conflict_interest_policy_url = models.URLField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class LegalCustomDocument(models.Model):
    settings = models.ForeignKey(LegalAgreementsSettings, on_delete=models.CASCADE, related_name="custom_documents")
    name = models.CharField(max_length=160)
    url = models.URLField()
    description = models.TextField(blank=True, default="")
    sort_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["sort_order", "id"]


class TradingPlatformSettings(models.Model):
    platform_icon = models.FileField(upload_to="platforms/", blank=True, null=True)
    platform_name = models.CharField(max_length=140, blank=True, default="MetaTrader 5")
    tagline = models.CharField(max_length=255, blank=True, default="")
    web_terminal_link = models.URLField(blank=True, default="")
    ios_download_link = models.URLField(blank=True, default="")
    android_download_link = models.URLField(blank=True, default="")
    windows_download_link = models.URLField(blank=True, default="")
    macos_download_link = models.URLField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class TradingPlatform(models.Model):
    name = models.CharField(max_length=140)
    tagline = models.CharField(max_length=255, blank=True, default="")
    icon = models.FileField(upload_to="platforms/", blank=True, null=True)
    web_terminal_link = models.URLField(blank=True, default="")
    ios_link = models.URLField(blank=True, default="")
    ios_file = models.FileField(upload_to="platforms/downloads/", blank=True, null=True)
    android_link = models.URLField(blank=True, default="")
    android_file = models.FileField(upload_to="platforms/downloads/", blank=True, null=True)
    windows_link = models.URLField(blank=True, default="")
    windows_file = models.FileField(upload_to="platforms/downloads/", blank=True, null=True)
    mac_link = models.URLField(blank=True, default="")
    mac_file = models.FileField(upload_to="platforms/downloads/", blank=True, null=True)
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-is_active", "name", "-updated_at"]

    def __str__(self) -> str:
        return self.name


TRADING_PLATFORM_SLUGS: dict[str, str] = {
    "MT4": "mt4",
    "MT5": "mt5",
    "CTRADER": "ctrader",
    "MATCH_TRADER": "match-trader",
    "TRADELOCKER": "tradelocker",
    "VERTEX_TRADER": "vertex-trader",
    "X9_TRADER": "x9-trader",
    "BTRADER": "btrader",
}
TRADING_PLATFORM_SLUG_TO_CODE: dict[str, str] = {v: k for k, v in TRADING_PLATFORM_SLUGS.items()}


class TradingPlatformIntegration(models.Model):
    """Per-platform API/integration settings (admin-configured; public fields sync to client portal)."""

    class Platform(models.TextChoices):
        MT4 = "MT4", "MetaTrader 4"
        MT5 = "MT5", "MetaTrader 5"
        CTRADER = "CTRADER", "cTrader"
        MATCH_TRADER = "MATCH_TRADER", "Match Trader"
        TRADELOCKER = "TRADELOCKER", "TradeLocker"
        VERTEX_TRADER = "VERTEX_TRADER", "Vertex Trader"
        X9_TRADER = "X9_TRADER", "X9 Trader"
        BTRADER = "BTRADER", "BTrader"

    platform = models.CharField(max_length=32, choices=Platform.choices, unique=True, db_index=True)
    enabled = models.BooleanField(
        default=False,
        help_text="Pause integration without deleting credentials.",
    )
    api_key = models.TextField(blank=True, default="", help_text="From your integration provider.")
    secret_key = models.TextField(blank=True, default="", help_text="Optional second credential.")
    api_version = models.CharField(max_length=40, blank=True, default="")
    payment_gateway_uuid = models.CharField(max_length=120, blank=True, default="")
    live_manager_token = models.TextField(blank=True, default="")
    demo_manager_token = models.TextField(blank=True, default="")
    server_name = models.CharField(max_length=200, blank=True, default="")
    broker_name = models.CharField(max_length=200, blank=True, default="")
    network_address = models.CharField(max_length=500, blank=True, default="")
    live_network_address = models.CharField(max_length=500, blank=True, default="")
    demo_network_address = models.CharField(max_length=500, blank=True, default="")
    api_server_url = models.CharField(
        max_length=500,
        blank=True,
        default="",
        help_text="Base URL for API or WebTrader (https://...).",
    )
    quick_notes = models.TextField(blank=True, default="", help_text="Shown in admin overview card.")
    admin_notes = models.TextField(blank=True, default="", help_text="Internal notes (admin only).")
    status_message = models.CharField(
        max_length=255,
        blank=True,
        default="",
        help_text="Short line shown next to Quick Notes (e.g. connection hint).",
    )
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    last_test_at = models.DateTimeField(null=True, blank=True)
    extended_config = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["platform"]
        verbose_name = "Trading platform integration"
        verbose_name_plural = "Trading platform integrations"

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return self.get_platform_display()

    @classmethod
    def ensure_defaults(cls):
        for value, _label in cls.Platform.choices:
            cls.objects.get_or_create(platform=value)

    def status_badge(self) -> tuple[str, str]:
        """(css_class, label) — Active | Inactive | Configurable."""
        if self.platform == self.Platform.MATCH_TRADER:
            return MatchTraderSettings.integration_hub_badge(self.enabled)
        if not self.enabled:
            return "inactive", "Inactive"
        if self.platform == self.Platform.CTRADER:
            if not (self.server_name or "").strip() or not ((self.live_network_address or "").strip() or (self.demo_network_address or "").strip()):
                return "configurable", "Configurable"
        elif self.platform == self.Platform.BTRADER:
            # keyId + HMAC secret + gateway URL (tenant resolved from the key).
            if (
                not (self.server_name or "").strip()
                or not (self.api_server_url or "").strip()
                or not (self.api_key or "").strip()
                or not (self.secret_key or "").strip()
            ):
                return "configurable", "Configurable"
        else:
            if not (self.server_name or "").strip() or not (self.api_server_url or "").strip():
                return "configurable", "Configurable"
        return "active", "Active"

    def url_slug(self) -> str:
        return TRADING_PLATFORM_SLUGS.get(self.platform, self.platform.lower())


class MatchTraderSettings(models.Model):
    """Broker API credentials and sync flags for Match-Trader (singleton row, pk=1)."""

    class ConnectionStatus(models.TextChoices):
        DISCONNECTED = "Disconnected", "Disconnected"
        CONNECTED = "Connected", "Connected"
        ERROR = "Error", "Error"

    class Environment(models.TextChoices):
        LIVE = "LIVE", "Live"
        SANDBOX = "SANDBOX", "Sandbox"

    base_url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        help_text="Broker HTTPS URL used for gRPC/health context (e.g. same host as REST).",
    )
    rest_base_url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        help_text="HTTPS base for Match-Trader REST (groups, catalog). If empty, Base URL is used.",
    )
    grpc_address = models.CharField(
        max_length=500,
        blank=True,
        default="",
        help_text="gRPC endpoint (e.g. host:port).",
    )
    api_key_encrypted = models.TextField(blank=True, default="")
    is_active = models.BooleanField(default=False)
    connection_status = models.CharField(
        max_length=32,
        choices=ConnectionStatus.choices,
        default=ConnectionStatus.DISCONNECTED,
    )
    last_connected = models.DateTimeField(null=True, blank=True)
    last_save_at = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Last explicit Save Configuration (activation requires a successful test after this).",
    )
    last_test_success_at = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Last successful gRPC TLS handshake to the broker gRPC endpoint.",
    )
    sync_users = models.BooleanField(default=False)
    sync_accounts = models.BooleanField(default=False)
    sync_trades = models.BooleanField(default=False)
    sync_balance = models.BooleanField(default=False)
    sync_deposits = models.BooleanField(default=False)
    sync_withdrawals = models.BooleanField(default=False)
    sync_orders = models.BooleanField(default=False)
    sync_positions = models.BooleanField(default=False)
    environment = models.CharField(
        max_length=16,
        choices=Environment.choices,
        default=Environment.LIVE,
    )
    last_test_latency_ms = models.PositiveIntegerField(null=True, blank=True)
    last_grpc_ok = models.BooleanField(default=False)
    last_sync_at = models.DateTimeField(null=True, blank=True)
    accounts_connected_count = models.PositiveIntegerField(default=0)
    open_trades_running_count = models.PositiveIntegerField(default=0)
    pending_orders_display_count = models.PositiveIntegerField(default=0)
    last_connection_error = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "match_trader_config"
        verbose_name = "Match-Trader configuration"
        verbose_name_plural = "Match-Trader configuration"

    def __str__(self) -> str:
        return "Match-Trader"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    def has_api_key(self) -> bool:
        return bool((self.api_key_encrypted or "").strip())

    def has_credentials(self) -> bool:
        return (
            bool((self.base_url or "").strip())
            and bool((self.grpc_address or "").strip())
            and self.has_api_key()
        )

    def connection_display_label(self) -> str:
        """Human-readable connection line for admin UI (not the raw DB enum)."""
        if not self.has_credentials():
            return "Not Configured"
        if self.connection_status == self.ConnectionStatus.CONNECTED:
            return "Connected"
        if self.connection_status == self.ConnectionStatus.ERROR:
            return "Failed"
        return "Pending"

    def activation_ready(self) -> bool:
        """True when save + successful test ordering allows turning the integration live."""
        if not self.has_credentials():
            return False
        if self.connection_status != self.ConnectionStatus.CONNECTED:
            return False
        if not self.last_save_at or not self.last_test_success_at:
            return False
        return self.last_test_success_at >= self.last_save_at

    def set_api_key(self, plain: str) -> None:
        if not (plain or "").strip():
            return
        f = _fernet_from_secret_key()
        self.api_key_encrypted = f.encrypt(plain.strip().encode("utf-8")).decode("utf-8")

    def get_api_key(self) -> str:
        if not self.api_key_encrypted:
            return ""
        try:
            return _fernet_from_secret_key().decrypt(self.api_key_encrypted.encode("utf-8")).decode("utf-8")
        except Exception:
            return ""

    @classmethod
    def integration_hub_badge(cls, trading_row_enabled: bool) -> tuple[str, str]:
        mt = cls.get_solo()
        if not mt.has_credentials():
            return "inactive", "Inactive"
        if mt.is_active and trading_row_enabled:
            return "active", "Active"
        if mt.connection_status == cls.ConnectionStatus.CONNECTED:
            return "configurable", "Connected"
        if mt.connection_status == cls.ConnectionStatus.ERROR:
            return "inactive", "Failed"
        return "inactive", "Inactive"


class MatchTraderLog(models.Model):
    """Structured Match-Trader integration logs (admin monitor + diagnostics)."""

    class Kind(models.TextChoices):
        CONNECTION = "connection", "Connection"
        ERROR = "error", "Error"
        API = "api", "API"

    kind = models.CharField(max_length=32, choices=Kind.choices, db_index=True)
    message = models.TextField()
    success = models.BooleanField(default=True, db_index=True)
    detail = models.JSONField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        db_table = "match_trader_logs"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.kind} {self.created_at:%Y-%m-%d %H:%M}"


class MatchTraderUserSnapshot(models.Model):
    """Cached trading summary per client for Match-Trader (filled by background sync)."""

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="match_trader_snapshot",
    )
    balance = models.DecimalField(max_digits=20, decimal_places=2, default=Decimal("0"))
    equity = models.DecimalField(max_digits=20, decimal_places=2, default=Decimal("0"))
    margin = models.DecimalField(max_digits=20, decimal_places=2, default=Decimal("0"))
    open_trades_count = models.PositiveIntegerField(default=0)
    pending_orders_count = models.PositiveIntegerField(default=0)
    open_trades_json = models.JSONField(default=list, blank=True)
    pending_orders_json = models.JSONField(default=list, blank=True)
    trade_history_json = models.JSONField(default=list, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "match_trader_user_snapshots"

    def __str__(self) -> str:
        return f"MT snapshot user={self.user_id}"


class EmailInboxMessage(models.Model):
    sender = models.EmailField()
    subject = models.CharField(max_length=255, blank=True, default="")
    message = models.TextField(blank=True, default="")
    received_at = models.DateTimeField(null=True, blank=True)
    raw_date = models.CharField(max_length=255, blank=True, default="")
    replied = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-received_at", "-created_at"]

    
    @property
    def base_account_type(self):
        if self.mt5_account:
            return self.mt5_account.account_type
        if "demo" in str(self.account_type).lower():
            return "DEMO"
        return "LIVE"

    @property
    def credit(self):
        return self.mt5_account.credit if self.mt5_account else 0

    @property
    def unrealized_pnl(self):
        return self.mt5_account.unrealized_pnl if self.mt5_account else 0

    @property
    def equity(self):
        return self.mt5_account.equity if self.mt5_account else self.balance

    @property
    def free_margin(self):
        return self.mt5_account.free_margin if self.mt5_account else self.balance

    @property
    def login_id(self):
        return self.account_number

    @property
    def group(self):
        return self.mt5_account.group if self.mt5_account else None

    @property
    def trading_enabled(self):
        return self.mt5_account.trading_enabled if self.mt5_account else True

    def __str__(self):
        return f"{self.sender} - {self.subject}"


class ComplianceIntegration(models.Model):
    class Provider(models.TextChoices):
        SUMSUB = "SUMSUB", "Sumsub"
        ONFIDO = "ONFIDO", "Onfido"
        SHUFTI_PRO = "SHUFTI_PRO", "Shufti Pro"
        KYC_VERIFICATION = "KYC_VERIFICATION", "KYC Verification"
        CUSTOM_API = "CUSTOM_API", "Custom API"
        IDNOW = "IDNOW", "IDnow"
        KYC_CHAIN = "KYC_CHAIN", "KYC Chain"
        VERIFF = "VERIFF", "Veriff"

    class Environment(models.TextChoices):
        SANDBOX = "SANDBOX", "Sandbox"
        LIVE = "LIVE", "Live"

    provider = models.CharField(max_length=30, choices=Provider.choices, unique=True)
    enabled = models.BooleanField(default=False)
    api_key = models.TextField(blank=True, default="")
    secret_key = models.TextField(blank=True, default="")
    webhook_url = models.CharField(max_length=500, blank=True, default="")
    callback_url = models.CharField(max_length=500, blank=True, default="")
    environment = models.CharField(max_length=10, choices=Environment.choices, default=Environment.SANDBOX)
    integration_name = models.CharField(max_length=120, blank=True, default="")
    status_text = models.CharField(max_length=120, blank=True, default="")
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "compliance_integrations"
        ordering = ["provider"]


class ComplianceOfficer(models.Model):
    user = models.OneToOneField("accounts.User", on_delete=models.CASCADE, related_name="compliance_officer")
    enabled = models.BooleanField(default=True)
    max_capacity = models.PositiveIntegerField(default=20)
    notes = models.TextField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "compliance_officers"


class KYCStatus(models.Model):
    code = models.CharField(max_length=30, unique=True)
    label = models.CharField(max_length=80)
    is_terminal = models.BooleanField(default=False)
    sort_order = models.PositiveIntegerField(default=0)

    class Meta:
        db_table = "kyc_status"
        ordering = ["sort_order", "id"]


class KYCRequest(models.Model):
    class RequestType(models.TextChoices):
        INDIVIDUAL = "INDIVIDUAL", "Individual"
        CORPORATE = "CORPORATE", "Corporate"

    class Priority(models.TextChoices):
        LOW = "LOW", "Low"
        NORMAL = "NORMAL", "Normal"
        HIGH = "HIGH", "High"
        URGENT = "URGENT", "Urgent"

    user = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="kyc_requests")
    assigned_officer = models.ForeignKey(
        ComplianceOfficer,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="requests",
    )
    request_type = models.CharField(max_length=20, choices=RequestType.choices, default=RequestType.INDIVIDUAL)
    status = models.CharField(max_length=30, default="PENDING_REVIEW", db_index=True)
    source = models.CharField(max_length=30, blank=True, default="PORTAL")
    priority = models.CharField(max_length=10, choices=Priority.choices, default=Priority.NORMAL)
    partial_approved = models.BooleanField(default=False)
    submitted_at = models.DateTimeField(default=timezone.now)
    approved_at = models.DateTimeField(null=True, blank=True)
    rejected_at = models.DateTimeField(null=True, blank=True)
    last_activity_at = models.DateTimeField(default=timezone.now)
    processing_time_minutes = models.PositiveIntegerField(default=0)
    rejection_reason = models.TextField(blank=True, default="")
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        db_table = "kyc_requests"
        ordering = ["-submitted_at"]


class KYCDocument(models.Model):
    request = models.ForeignKey(KYCRequest, on_delete=models.CASCADE, related_name="documents")
    document_type = models.CharField(max_length=80, blank=True, default="")
    file_url = models.CharField(max_length=500, blank=True, default="")
    status = models.CharField(max_length=20, default="PENDING")
    notes = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)
    reviewed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "kyc_documents"
        ordering = ["-created_at"]


class ComplianceLog(models.Model):
    request = models.ForeignKey(KYCRequest, on_delete=models.SET_NULL, null=True, blank=True, related_name="logs")
    actor = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True, blank=True)
    action = models.CharField(max_length=80)
    details = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "compliance_logs"
        ordering = ["-created_at"]


class SupportIntegration(models.Model):
    class IntegrationType(models.TextChoices):
        WHATSAPP_DIRECT = "WHATSAPP_DIRECT", "WhatsApp Direct"
        # LIVE_CHAT = "LIVE_CHAT", "Live Chat"
        TAWK_TO = "TAWK_TO", "Tawk.to"
        ZOHO_SALESIQ = "ZOHO_SALESIQ", "Zoho SalesIQ"
        # EMAIL_SUPPORT = "EMAIL_SUPPORT", "Email Support"
        # CUSTOM_API = "CUSTOM_API", "Custom API Support"

    integration_type = models.CharField(max_length=30, choices=IntegrationType.choices, unique=True)
    integration_name = models.CharField(max_length=120, blank=True, default="")
    category = models.CharField(max_length=40, blank=True, default="CUSTOMER_SUPPORT")
    enabled = models.BooleanField(default=False)
    status = models.CharField(max_length=10, default="INACTIVE")
    phone_number = models.CharField(max_length=40, blank=True, default="")
    prefilled_message = models.TextField(blank=True, default="")
    # chat_bubble_icon = models.CharField(max_length=255, blank=True, default="")
    # chat_widget = models.TextField(blank=True, default="")
    embed_code = models.TextField(blank=True, default="")
    embed_script = models.TextField(blank=True, default="")
    # support_email = models.EmailField(blank=True, default="")
    # api_url = models.CharField(max_length=500, blank=True, default="")
    # token = models.TextField(blank=True, default="")
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "support_integrations"
        ordering = ["integration_type"]


class SupportSettings(models.Model):
    floating_button_enabled = models.BooleanField(default=True)
    floating_position = models.CharField(max_length=20, default="BOTTOM_RIGHT")
    floating_icon = models.CharField(max_length=255, blank=True, default="")
    default_ticket_email = models.EmailField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "support_settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class SupportLog(models.Model):
    integration = models.ForeignKey(SupportIntegration, on_delete=models.SET_NULL, null=True, blank=True)
    user = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True, blank=True)
    action = models.CharField(max_length=80)
    status = models.CharField(max_length=20, default="OK")
    payload = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "support_logs"
        ordering = ["-created_at"]


class EmailProvider(models.Model):
    class Provider(models.TextChoices):
        AMAZON_SES = "AMAZON_SES", "Amazon SES"
        MAILGUN = "MAILGUN", "Mailgun"
        POSTMARK = "POSTMARK", "Postmark"
        SENDGRID = "SENDGRID", "SendGrid"
        ZEPTOMAIL = "ZEPTOMAIL", "ZeptoMail"
        SMTP_UNIVERSAL = "SMTP_UNIVERSAL", "SMTP Universal"
        REOON = "REOON", "Reoon Email Verifier"
        ZOHO_MAIL = "ZOHO_MAIL", "Zoho Mail"

    provider = models.CharField(max_length=30, choices=Provider.choices, unique=True)
    enabled = models.BooleanField(default=False)
    enable_integration = models.BooleanField(
        default=False,
        help_text="Reoon and other providers: master toggle for the integration UI.",
    )
    is_active = models.BooleanField(default=False)
    integration_name = models.CharField(max_length=120, blank=True, default="")
    api_key = models.CharField(max_length=2048, blank=True, default="")
    secret_key = models.TextField(blank=True, default="")
    domain = models.CharField(max_length=255, blank=True, default="")
    sender_email = models.EmailField(blank=True, default="")
    sender_name = models.CharField(max_length=120, blank=True, default="")
    smtp_host = models.CharField(max_length=255, blank=True, default="")
    smtp_port = models.PositiveIntegerField(default=587)
    username = models.CharField(max_length=255, blank=True, default="")
    password = models.TextField(blank=True, default="")
    encryption = models.CharField(max_length=10, default="TLS")
    extra_config = models.JSONField(default=dict, blank=True)
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_providers"
        ordering = ["provider"]


class SMSProvider(models.Model):
    class Provider(models.TextChoices):
        TWILIO_VERIFY = "TWILIO_VERIFY", "Twilio Verify"
        TWILIO_WHATSAPP = "TWILIO_WHATSAPP", "Twilio WhatsApp"
        CUSTOM_SMS_API = "CUSTOM_SMS_API", "Custom SMS API"

    provider = models.CharField(max_length=30, choices=Provider.choices, unique=True)
    enabled = models.BooleanField(default=False)
    is_active = models.BooleanField(default=False)
    api_key = models.TextField(blank=True, default="")
    sender_id = models.CharField(max_length=80, blank=True, default="")
    sender_email = models.EmailField(blank=True, default="")
    api_url = models.CharField(max_length=500, blank=True, default="")
    account_sid = models.CharField(max_length=255, blank=True, default="")
    auth_token = models.TextField(blank=True, default="")
    phone_number = models.CharField(max_length=40, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "sms_providers"
        ordering = ["provider"]


class EmailSettings(models.Model):
    default_provider = models.ForeignKey(EmailProvider, on_delete=models.SET_NULL, null=True, blank=True, related_name="+")
    event_template_map = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "email_settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class SMSSettings(models.Model):
    default_provider = models.ForeignKey(SMSProvider, on_delete=models.SET_NULL, null=True, blank=True, related_name="+")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "sms_settings"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class EmailProviderLog(models.Model):
    user = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True, blank=True)
    email = models.EmailField()
    subject = models.CharField(max_length=255, blank=True, default="")
    body = models.TextField(blank=True, default="")
    provider = models.CharField(max_length=30, blank=True, default="")
    status = models.CharField(max_length=20, default="SENT")
    error_message = models.TextField(blank=True, default="")
    event_key = models.CharField(max_length=80, blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "email_logs"
        ordering = ["-created_at"]


class SMSLog(models.Model):
    user = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True, blank=True)
    provider = models.CharField(max_length=30, blank=True, default="")
    to_phone = models.CharField(max_length=40)
    message = models.TextField(blank=True, default="")
    status = models.CharField(max_length=20, default="SENT")
    error_message = models.TextField(blank=True, default="")
    event_key = models.CharField(max_length=80, blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "sms_logs"
        ordering = ["-created_at"]



class IntegrationConnectionLog(models.Model):
    """Audit trail for integration test connections and errors."""

    integration_slug = models.CharField(max_length=80, db_index=True)
    category = models.CharField(max_length=40, blank=True, default="")
    success = models.BooleanField(default=False)
    message = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class AIIntegration(models.Model):
    class Slug(models.TextChoices):
        BROKERET_AI = "BROKERET_AI", "Brokeret AI"
        BUILTIN_AI = "BUILTIN_AI", "Built-in AI"
        CHATGPT = "CHATGPT", "ChatGPT"
        GEMINI = "GEMINI", "Gemini"
        GROK = "GROK", "Grok"

    slug = models.CharField(max_length=32, choices=Slug.choices, unique=True, db_index=True)
    enabled = models.BooleanField(default=False)
    integration_name = models.CharField(max_length=120, blank=True, default="")
    category = models.CharField(max_length=40, default="AI_ML")
    status = models.CharField(max_length=12, default="INACTIVE")
    api_key = models.TextField(blank=True, default="")
    api_secret = models.TextField(blank=True, default="")
    base_url = models.CharField(max_length=500, blank=True, default="")
    model_name = models.CharField(max_length=120, blank=True, default="")
    extra_config = models.JSONField(default=dict, blank=True)
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["slug"]

    @classmethod
    def ensure_defaults(cls):
        for value, label in cls.Slug.choices:
            cls.objects.get_or_create(slug=value, defaults={"integration_name": label, "category": "AI_ML"})


class ReCaptchaIntegrationSettings(models.Model):
    enabled = models.BooleanField(default=False)
    site_key = models.CharField(max_length=255, blank=True, default="")
    secret_key = models.TextField(blank=True, default="")
    version = models.CharField(max_length=20, default="v2_checkbox")
    apply_login = models.BooleanField(default=False)
    apply_signup = models.BooleanField(default=True)
    apply_withdrawal = models.BooleanField(default=False)
    score_threshold = models.DecimalField(max_digits=3, decimal_places=2, default=0.5)
    enable_logging = models.BooleanField(default=False)
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class Google2FAIntegrationSettings(models.Model):
    enabled = models.BooleanField(default=False)
    method_google_auth = models.BooleanField(default=True)
    method_microsoft_auth = models.BooleanField(default=True)
    method_authy = models.BooleanField(default=False)
    apply_client_login = models.BooleanField(default=False)
    apply_admin_login = models.BooleanField(default=False)
    apply_withdrawal = models.BooleanField(default=False)
    apply_password_change = models.BooleanField(default=False)
    apply_wallet_access = models.BooleanField(default=False)
    apply_profile_changes = models.BooleanField(default=False)
    backup_codes_enabled = models.BooleanField(default=True)
    remember_device_days = models.PositiveIntegerField(default=30)
    force_2fa_admin = models.BooleanField(default=False)
    force_2fa_clients = models.BooleanField(default=False)
    otp_expiry_seconds = models.PositiveIntegerField(default=30)
    max_attempts = models.PositiveIntegerField(default=5)
    lockout_seconds = models.PositiveIntegerField(default=900)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class Match2PayIntegrationSettings(models.Model):
    enabled = models.BooleanField(default=False)
    api_token = models.TextField(blank=True, default="")
    api_secret = models.TextField(blank=True, default="")
    merchant_id = models.CharField(max_length=120, blank=True, default="")
    api_url = models.CharField(max_length=500, blank=True, default="")
    documentation_url = models.URLField(max_length=500, blank=True, default="")
    webhook_url = models.CharField(max_length=500, blank=True, default="")
    currencies_config = models.JSONField(default=dict, blank=True)
    deposit_auto_credit = models.BooleanField(default=False)
    deposit_manual_approval = models.BooleanField(default=True)
    deposit_confirmations = models.PositiveIntegerField(default=3)
    withdrawal_enabled = models.BooleanField(default=False)
    withdrawal_manual_approval = models.BooleanField(default=True)
    withdrawal_fee_percent = models.DecimalField(max_digits=6, decimal_places=2, default=0)
    last_test_ok = models.BooleanField(null=True, blank=True)
    last_test_at = models.DateTimeField(null=True, blank=True)
    last_test_detail = models.CharField(max_length=500, blank=True, default="")
    last_webhook_test_ok = models.BooleanField(null=True, blank=True)
    last_webhook_test_at = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class CrmDepartment(models.Model):
    """Organizational unit for RBAC and lead routing (Sales, KYC, Finance, Support, etc.)."""

    name = models.CharField(max_length=120)
    slug = models.SlugField(max_length=64, unique=True, db_index=True)
    description = models.TextField(blank=True, default="")
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class CrmRole(models.Model):
    """
    Named permission template for sales staff (Sales Manager, KYC Officer, etc.).
    Assign to users via User.crm_role; CrmRoleGrant rows define allowed actions.
    """

    name = models.CharField(max_length=120)
    slug = models.SlugField(max_length=64, unique=True, db_index=True)
    description = models.TextField(blank=True, default="")
    is_system = models.BooleanField(
        default=False,
        help_text="Built-in roles seeded by migrations; can still edit grants.",
    )
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class CrmRoleGrant(models.Model):
    """Permission flag for a CrmRole (same codes as CrmPermissionGrant.permission_code)."""

    role = models.ForeignKey(
        "CrmRole",
        on_delete=models.CASCADE,
        related_name="grants",
    )
    permission_code = models.CharField(max_length=64, db_index=True)
    granted = models.BooleanField(default=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["role", "permission_code"],
                name="crm_role_grant_unique_role_code",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.role.slug} {self.permission_code}={'Y' if self.granted else 'N'}"


class CrmStaffProfile(models.Model):
    """
    Extra CRM fields for staff. Sales managers use referral_slug for public signup links:
    /register?manager=<slug>
    """

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="crm_staff_profile",
    )
    referral_slug = models.SlugField(
        max_length=80,
        unique=True,
        db_index=True,
        help_text="URL segment for manager referral links (e.g. john-smith).",
    )

    class Meta:
        verbose_name = "CRM staff profile"
        verbose_name_plural = "CRM staff profiles"

    def __str__(self) -> str:
        return f"{self.user_id} ({self.referral_slug})"


class ManagerClient(models.Model):
    """
    Explicit CRM assignment of client users to a sales manager (admin-driven).
    Keeps history of who assigned; syncs User.registered_via_sales_manager for scoping.
    """

    manager = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="assigned_manager_clients",
        limit_choices_to={"role": "SALES_MANAGER"},
    )
    client = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="manager_client_assignments",
        limit_choices_to={"role": "CLIENT"},
    )
    assigned_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="manager_clients_assigned_by_me",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "manager client assignment"
        verbose_name_plural = "manager client assignments"
        constraints = [
            models.UniqueConstraint(
                fields=["manager", "client"],
                name="uniq_manager_client_pair",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.manager_id} → {self.client_id}"


class ManagerTarget(models.Model):
    """
    KPI target for a sales manager (deposit or trading volume in lots).
    Progress is computed for the current calendar period unless start_date/end_date are set.
    Only one row per manager should have is_active=True (enforced via constraint).
    """

    class TargetType(models.TextChoices):
        DEPOSIT = "deposit", "Deposit based"
        VOLUME = "volume", "Volume based"

    class Period(models.TextChoices):
        MONTHLY = "monthly", "Monthly"
        WEEKLY = "weekly", "Weekly"
        DAILY = "daily", "Daily"

    manager = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="manager_targets",
        limit_choices_to={"role__in": ["SALES_MANAGER", "MANAGER"]},
    )
    target_type = models.CharField(max_length=16, choices=TargetType.choices)
    target_value = models.DecimalField(
        max_digits=20,
        decimal_places=4,
        help_text="Deposit: currency amount (e.g. USD). Volume: sum of lots.",
    )
    period = models.CharField(max_length=16, choices=Period.choices, default=Period.MONTHLY)
    start_date = models.DateField(
        null=True,
        blank=True,
        help_text="Optional fixed window start; if set with end_date, overrides period.",
    )
    end_date = models.DateField(null=True, blank=True)
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "manager_targets"
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["manager"],
                condition=models.Q(is_active=True),
                name="uniq_active_manager_target_per_manager",
            ),
        ]

    def __str__(self) -> str:
        return f"Target {self.manager_id} {self.target_type} {self.target_value}"


class CrmPermissionGrant(models.Model):
    """
    Enable/disable a granular CRM permission for a user or for everyone in a department.
    User-level rows override department-level rows for the same permission_code.
    """

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="crm_permission_grants",
    )
    department = models.ForeignKey(
        "CrmDepartment",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="crm_permission_grants",
    )
    permission_code = models.CharField(max_length=64, db_index=True)
    granted = models.BooleanField(
        default=True,
        help_text="False explicitly denies even if department allows.",
    )

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=models.Q(user__isnull=False) | models.Q(department__isnull=False),
                name="crm_perm_grant_has_target",
            ),
            models.CheckConstraint(
                condition=~(models.Q(user__isnull=False) & models.Q(department__isnull=False)),
                name="crm_perm_grant_single_target",
            ),
            models.UniqueConstraint(
                fields=["user", "permission_code"],
                condition=models.Q(department__isnull=True),
                name="crm_perm_grant_unique_user_code",
            ),
            models.UniqueConstraint(
                fields=["department", "permission_code"],
                condition=models.Q(user__isnull=True),
                name="crm_perm_grant_unique_dept_code",
            ),
        ]

    def __str__(self) -> str:
        t = f"user {self.user_id}" if self.user_id else f"dept {self.department_id}"
        return f"{t} {self.permission_code}={'Y' if self.granted else 'N'}"


class ManagerPortalPermission(models.Model):
    """
    Fine-grained visibility for Account Manager role (MANAGER).
    Admins set these when provisioning managers; disabled flags hide UI and API data.
    """

    manager = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="manager_portal_permissions",
        limit_choices_to={"role": "MANAGER"},
    )
    view_clients = models.BooleanField(default=False)
    view_deposit = models.BooleanField(default=False)
    view_withdrawal = models.BooleanField(default=False)
    view_volume = models.BooleanField(default=False)
    view_balance = models.BooleanField(default=False)
    view_trades = models.BooleanField(default=False)
    view_personal_info = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "manager_permissions"

    def __str__(self) -> str:
        return f"perms:{self.manager_id}"


class ManagerAssignedClient(models.Model):
    """Clients explicitly assigned to an Account Manager (separate from sales ManagerClient)."""

    manager = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="manager_portal_assignments",
        limit_choices_to={"role": "MANAGER"},
    )
    client = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="account_manager_assignments",
        limit_choices_to={"role__in": ["CLIENT", "TRADER", "COPIER"]},
    )
    assigned_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="manager_portal_assignments_made",
    )
    assigned_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "manager_assigned_clients"
        constraints = [
            models.UniqueConstraint(fields=["manager", "client"], name="uniq_manager_portal_manager_client"),
        ]

    def __str__(self) -> str:
        return f"{self.manager_id} → {self.client_id}"


class SystemModule(models.Model):
    class Stability(models.TextChoices):
        DEVELOPMENT = "development", "Development"
        STABLE = "stable", "Stable"

    module_name = models.CharField(max_length=120, unique=True, db_index=True)
    stability = models.CharField(max_length=16, choices=Stability.choices, default=Stability.DEVELOPMENT)
    is_locked = models.BooleanField(default=False, db_index=True)
    locked_at = models.DateTimeField(null=True, blank=True)
    locked_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="locked_system_modules",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "system_modules"
        ordering = ["module_name"]

    def __str__(self) -> str:
        return self.module_name


class ModuleVersion(models.Model):
    module = models.ForeignKey(SystemModule, on_delete=models.CASCADE, related_name="versions")
    module_version = models.CharField(max_length=40, db_index=True)
    backup_path = models.CharField(max_length=500, blank=True, default="")
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="created_module_versions",
    )
    change_summary = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        db_table = "module_versions"
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(fields=["module", "module_version"], name="uniq_module_version_per_module"),
        ]

    def __str__(self) -> str:
        return f"{self.module.module_name}@{self.module_version}"


class ModuleChangeLog(models.Model):
    module = models.ForeignKey(SystemModule, on_delete=models.CASCADE, related_name="change_logs")
    changed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="module_change_logs",
    )
    change_type = models.CharField(max_length=60, blank=True, default="")
    change_summary = models.TextField(blank=True, default="")
    changed_paths = models.JSONField(default=list, blank=True)
    metadata = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        db_table = "module_change_logs"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.module.module_name}:{self.change_type or 'update'}"


class StabilityProfile(models.Model):
    class Mode(models.TextChoices):
        DEVELOPMENT = "development", "Development"
        STABLE = "stable", "Stable"

    mode = models.CharField(max_length=16, choices=Mode.choices, default=Mode.DEVELOPMENT)
    updated_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="stability_profiles_updated",
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "stability_profiles"

    @classmethod
    def get_solo(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
