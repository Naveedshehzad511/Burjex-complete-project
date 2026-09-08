from django.contrib import admin

from .models import (
    Lead,
    MarketingCampaign,
    MarketingWithdrawRequest,
    SalesFunnelContactLog,
    SalesFunnelProfile,
    SalesFunnelVisitor,
)


@admin.register(MarketingCampaign)
class MarketingCampaignAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "is_active", "created_at")
    list_filter = ("is_active",)
    search_fields = ("name",)


@admin.register(Lead)
class LeadAdmin(admin.ModelAdmin):
    list_display = ("id", "campaign", "full_name", "email", "phone", "status", "assigned_to", "created_at")
    list_filter = ("status", "campaign")
    search_fields = ("email", "full_name", "phone")
    raw_id_fields = ("campaign", "assigned_to")


@admin.register(SalesFunnelVisitor)
class SalesFunnelVisitorAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "full_name",
        "email",
        "phone",
        "created_at",
        "converted_user",
        "is_dropped",
        "assigned_manager",
        "assigned_agent",
    )
    list_filter = ("is_dropped", "created_at")
    search_fields = ("email", "full_name", "phone")
    raw_id_fields = (
        "converted_user",
        "assigned_manager",
        "assigned_agent",
        "last_contacted_by",
    )


@admin.register(SalesFunnelProfile)
class SalesFunnelProfileAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "is_dropped", "assigned_manager", "assigned_agent", "last_contact_at")
    list_filter = ("is_dropped",)
    search_fields = ("user__email", "internal_notes")
    raw_id_fields = ("user", "assigned_manager", "assigned_agent", "last_contacted_by")


@admin.register(SalesFunnelContactLog)
class SalesFunnelContactLogAdmin(admin.ModelAdmin):
    list_display = ("id", "channel", "visitor", "client", "created_by", "created_at")
    list_filter = ("channel", "created_at")
    raw_id_fields = ("visitor", "client", "created_by")


@admin.register(MarketingWithdrawRequest)
class MarketingWithdrawRequestAdmin(admin.ModelAdmin):
    list_display = ("id", "requester", "amount", "currency", "status", "reference", "created_at")
    list_filter = ("status", "currency")
    search_fields = ("requester__email", "reference")
    raw_id_fields = ("requester",)
