from django.contrib import admin

from .models import EmailInboxMessage, EmailLog, EmailTemplateSettings, WhiteLabelProfile


@admin.register(WhiteLabelProfile)
class WhiteLabelProfileAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "slug", "is_active_for_portal", "updated_at")
    list_filter = ("is_active_for_portal",)
    search_fields = ("name", "slug")

@admin.register(EmailLog)
class EmailLogAdmin(admin.ModelAdmin):
    list_display = ("id", "email", "subject", "status", "created_at")
    search_fields = ("email", "subject")
    list_filter = ("status",)


@admin.register(EmailInboxMessage)
class EmailInboxMessageAdmin(admin.ModelAdmin):
    list_display = ("id", "sender", "subject", "received_at", "replied")
    search_fields = ("sender", "subject")
    list_filter = ("replied",)


@admin.register(EmailTemplateSettings)
class EmailTemplateSettingsAdmin(admin.ModelAdmin):
    list_display = ("id", "header_color", "text_color", "logo_position", "logo_size", "updated_at")
