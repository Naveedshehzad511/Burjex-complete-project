from django.contrib import admin

from .models import CommissionGroup, IBApplicationQuestion, IBCommissionRule, IBPlan, IBRequest


@admin.register(IBPlan)
class IBPlanAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "commission_rate", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name",)


@admin.register(CommissionGroup)
class CommissionGroupAdmin(admin.ModelAdmin):
    list_display = ("id", "name")
    search_fields = ("name",)


@admin.register(IBCommissionRule)
class IBCommissionRuleAdmin(admin.ModelAdmin):
    list_display = ("id", "plan", "commission_group", "commission_amount", "is_active")
    list_filter = ("plan", "commission_group", "is_active")
    search_fields = ("plan__name", "commission_group__name")


@admin.register(IBApplicationQuestion)
class IBApplicationQuestionAdmin(admin.ModelAdmin):
    list_display = ("id", "sort_order", "label", "input_type", "required", "is_active")
    list_filter = ("input_type", "required", "is_active")
    search_fields = ("label",)
    ordering = ("sort_order", "id")


@admin.register(IBRequest)
class IBRequestAdmin(admin.ModelAdmin):
    list_display = ("id", "ib_user", "client_user", "plan", "status", "requested_at", "processed_at")
    list_filter = ("status", "plan")
    search_fields = ("ib_user__email", "client_user__email", "notes")
    raw_id_fields = ("ib_user", "client_user")
