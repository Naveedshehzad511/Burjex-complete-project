from django.contrib import admin

from .models import (
    AuditLog,
    ClientRiskProfile,
    LoginEvent,
    RiskAlert,
    StaffNotification,
)


@admin.register(AuditLog)
class AuditLogAdmin(admin.ModelAdmin):
    list_display = ("created_at", "action", "entity_type", "entity_id", "channel", "actor_email", "ip")
    list_filter = ("channel", "entity_type")
    search_fields = ("action", "entity_id", "actor_email")
    readonly_fields = ("created_at",)


@admin.register(LoginEvent)
class LoginEventAdmin(admin.ModelAdmin):
    list_display = ("created_at", "success", "channel", "username_attempt", "user", "ip", "suspicious")
    list_filter = ("success", "channel", "suspicious")
    search_fields = ("username_attempt", "ip", "user__email")


@admin.register(ClientRiskProfile)
class ClientRiskProfileAdmin(admin.ModelAdmin):
    list_display = ("user", "risk_score", "booking", "exposure_limit_usd", "exposure_current_usd")
    search_fields = ("user__email",)


@admin.register(RiskAlert)
class RiskAlertAdmin(admin.ModelAdmin):
    list_display = ("created_at", "user", "level", "acknowledged", "message")
    list_filter = ("level", "acknowledged")


@admin.register(StaffNotification)
class StaffNotificationAdmin(admin.ModelAdmin):
    list_display = ("created_at", "recipient", "title", "read_at", "action_url")
    search_fields = ("title", "body", "recipient__email", "action_url")
