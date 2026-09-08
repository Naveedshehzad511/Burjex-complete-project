from __future__ import annotations

from decimal import Decimal

from django import forms

from accounts.models import MT5Group

from .models import MatchTraderBrokerGroup, PortalBrandingSettings, TradingAccountType
from .services.mt5_group_mapping import sync_mt5_group_derived_fields


class GroupForm(forms.ModelForm):
    class Meta:
        model = MT5Group
        fields = ["crm_group_name", "platform", "platform_group_name", "description", "is_active"]

    def clean_crm_group_name(self):
        value = (self.cleaned_data.get("crm_group_name") or "").strip()
        if not value:
            raise forms.ValidationError("Group name is required.")
        return value

    def clean_platform(self):
        value = (self.cleaned_data.get("platform") or "").strip()
        if not value:
            raise forms.ValidationError("Platform is required.")
        valid = {c for c, _ in MT5Group.BrokerPlatform.choices}
        if value not in valid:
            raise forms.ValidationError("Invalid platform.")
        return value

    def clean_platform_group_name(self):
        value = (self.cleaned_data.get("platform_group_name") or "").strip()
        if not value:
            raise forms.ValidationError("Select a platform group from the tree (no manual entry).")
        return value[:120]

    def clean(self):
        cleaned = super().clean()
        platform = cleaned.get("platform")
        pg = (cleaned.get("platform_group_name") or "").strip()
        if platform == MT5Group.BrokerPlatform.MATCH_TRADER and pg:
            if not MatchTraderBrokerGroup.objects.filter(name=pg, is_active=True).exists():
                self.add_error(
                    "platform_group_name",
                    "This Match-Trader group is not in the catalog. Sync groups from the Match-Trader integration first.",
                )
        return cleaned

    def save(self, commit=True):
        instance = super().save(commit=False)
        sync_mt5_group_derived_fields(instance)
        if commit:
            instance.save()
        return instance


class AccountTypeForm(forms.ModelForm):
    class Meta:
        model = TradingAccountType
        fields = [
            "account_name",
            "account_code",
            "display_order",
            "crm_group",
            "pricing_type",
            "spread_value",
            "commission",
            "description",
            "is_active",
        ]

    def clean_account_name(self):
        value = (self.cleaned_data.get("account_name") or "").strip()
        if not value:
            raise forms.ValidationError("Account type name is required.")
        return value

    def clean_account_code(self):
        value = (self.cleaned_data.get("account_code") or "").strip().upper()
        if not value:
            raise forms.ValidationError("Account code is required.")
        return value

    def clean(self):
        cleaned = super().clean()
        pricing_type = (cleaned.get("pricing_type") or TradingAccountType.PricingType.SPREAD).upper()
        spread_value = cleaned.get("spread_value")
        commission = cleaned.get("commission")
        crm_group = cleaned.get("crm_group")

        if not crm_group:
            self.add_error("crm_group", "Please select a mapped group.")

        if pricing_type == TradingAccountType.PricingType.SPREAD and spread_value is None:
            self.add_error("spread_value", "Spread value is required for Spread pricing.")
        if pricing_type == TradingAccountType.PricingType.COMMISSION:
            if commission is None or Decimal(str(commission)) <= Decimal("0"):
                self.add_error("commission", "Commission per lot is required for Commission pricing.")
        return cleaned


class BrandingForm(forms.ModelForm):
    class Meta:
        model = PortalBrandingSettings
        fields = [
            "admin_logo",
            "admin_favicon",
            "admin_login_logo",
            "admin_sidebar_logo",
            "user_logo",
            "user_favicon",
            "user_login_logo",
            "user_dashboard_logo",
            "user_dashboard_logo_dark",
        ]
