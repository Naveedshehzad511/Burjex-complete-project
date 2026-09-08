"""Django admin configuration for email_notifications.

Provides:
- Singleton admin for EmailNotificationSettings (password field masked)
- NotificationTemplate admin with CKEditor 5 rich editor and "Send Test Email" action
- Read-only NotificationLog admin with filters for analytics
"""

from __future__ import annotations

from django.contrib import admin, messages
from django.db import models as db_models

from solo.admin import SingletonModelAdmin

from .models import EmailNotificationSettings, NotificationLog, NotificationTemplate

# Try to import CKEditor 5 widget; fall back gracefully
try:
    from django_ckeditor_5.widgets import CKEditor5Widget

    _CKEDITOR_AVAILABLE = True
except ImportError:
    _CKEDITOR_AVAILABLE = False


# ---------------------------------------------------------------------------
# 1. EmailNotificationSettings (Singleton)
# ---------------------------------------------------------------------------

@admin.register(EmailNotificationSettings)
class EmailNotificationSettingsAdmin(SingletonModelAdmin):
    fieldsets = (
        ("SMTP Server", {
            "fields": ("smtp_host", "smtp_port", "smtp_username", "smtp_password_display", "encryption_type"),
        }),
        ("Sender Identity", {
            "fields": ("from_email", "from_name"),
        }),
        ("Master Switch", {
            "fields": ("is_active",),
        }),
    )
    readonly_fields = ("smtp_password_display",)

    def smtp_password_display(self, obj):
        """Show masked password indicator."""
        if obj.smtp_password_encrypted:
            return "••••••••  (encrypted — save a new value to change)"
        return "— not set —"
    smtp_password_display.short_description = "SMTP password"

    def get_form(self, request, obj=None, **kwargs):
        """Add a plaintext password field for input (never stored in plain)."""
        form = super().get_form(request, obj, **kwargs)

        # Dynamically inject a password input field
        from django import forms

        class PatchedForm(form):
            smtp_password_plain = forms.CharField(
                label="Set SMTP password",
                required=False,
                widget=forms.PasswordInput(attrs={"autocomplete": "new-password"}),
                help_text="Enter a new password to update. Leave blank to keep the current one.",
            )

            class Meta(form.Meta):
                pass

        return PatchedForm

    def save_model(self, request, obj, form, change):
        plain = form.cleaned_data.get("smtp_password_plain", "").strip()
        if plain:
            obj.set_password(plain)
        super().save_model(request, obj, form, change)


# ---------------------------------------------------------------------------
# 2. NotificationTemplate
# ---------------------------------------------------------------------------

@admin.register(NotificationTemplate)
class NotificationTemplateAdmin(admin.ModelAdmin):
    list_display = ("name", "event_key", "category", "is_active", "updated_at")
    list_filter = ("category", "is_active")
    search_fields = ("name", "event_key", "subject")
    prepopulated_fields = {"event_key": ("name",)}
    actions = ["send_test_email"]

    if _CKEDITOR_AVAILABLE:
        formfield_overrides = {
            db_models.TextField: {"widget": CKEditor5Widget(config_name="extends")},
        }

    fieldsets = (
        (None, {
            "fields": ("name", "event_key", "category", "is_active"),
        }),
        ("Content", {
            "fields": ("subject", "html_content"),
            "description": (
                "Use {{variable}} placeholders: {{user_name}}, {{user_email}}, "
                "{{otp}}, {{amount}}, {{company_name}}, {{reason}}, {{date}}, "
                "{{verify_url}}, {{upload_url}}"
            ),
        }),
    )

    @admin.action(description="📧 Send test email to first admin user")
    def send_test_email(self, request, queryset):
        """Custom action: send a test email using the selected template(s)."""
        from accounts.models import User

        admin_user = User.objects.filter(
            role__in=[User.Roles.ADMIN, User.Roles.BANKER],
            is_active=True,
        ).exclude(email="").first()

        if not admin_user:
            self.message_user(request, "No admin user with email found.", messages.ERROR)
            return

        sent = 0
        for tpl in queryset:
            try:
                from .utils import send_notification

                success = send_notification(
                    user_id=admin_user.pk,
                    event_key=tpl.event_key,
                    context_data={
                        "to_email": admin_user.email,
                        "user_name": admin_user.display_name(),
                        "otp": "482910",
                        "amount": "1,250.00 USD",
                        "reason": "Sample test reason",
                        "date": "2026-01-01 12:00",
                        "account_number": "200012345",
                    },
                )
                if success:
                    sent += 1
            except Exception as exc:
                self.message_user(
                    request,
                    f"Failed to send test for '{tpl.name}': {exc}",
                    messages.WARNING,
                )

        self.message_user(
            request,
            f"Test email(s) sent: {sent}/{queryset.count()} to {admin_user.email}",
            messages.SUCCESS if sent else messages.WARNING,
        )


# ---------------------------------------------------------------------------
# 3. NotificationLog (read-only)
# ---------------------------------------------------------------------------

@admin.register(NotificationLog)
class NotificationLogAdmin(admin.ModelAdmin):
    list_display = ("recipient", "event_key", "subject", "status", "sent_at", "opened_at", "created_at")
    list_filter = ("status", "event_key", "created_at")
    search_fields = ("recipient", "event_key", "subject")
    readonly_fields = (
        "id", "recipient", "user", "template", "event_key", "subject",
        "status", "error_details", "opened_at", "sent_at", "created_at",
    )
    date_hierarchy = "created_at"
    ordering = ("-created_at",)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        # Allow superuser cleanup only
        return request.user.is_superuser
