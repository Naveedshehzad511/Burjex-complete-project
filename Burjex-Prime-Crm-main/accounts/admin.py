from django.contrib import admin
from django.utils import timezone

from .models import (
    AccountDeletionRequest,
    BankDetails,
    Bonus,
    Document,
    MT5Account,
    MT5Group,
    User,
)


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ("id", "email", "role", "kyc_status", "email_verified", "ftd_user", "is_active")
    list_filter = ("role", "kyc_status", "email_verified", "ftd_user", "is_active")
    search_fields = ("email", "first_name", "last_name", "username")
    actions = ("action_verify_email",)

    @admin.action(description="Verify email and activate selected users")
    def action_verify_email(self, request, queryset):
        from django.utils import timezone

        n = 0
        for u in queryset:
            u.email_verified = True
            u.email_verified_at = timezone.now()
            u.is_active = True
            u.email_token = ""
            u.save(update_fields=["email_verified", "email_verified_at", "is_active", "email_token"])
            n += 1
        self.message_user(request, f"Verified and activated {n} user(s).")


admin.site.register(MT5Group)
admin.site.register(MT5Account)
admin.site.register(Document)
admin.site.register(BankDetails)
admin.site.register(Bonus)


@admin.register(AccountDeletionRequest)
class AccountDeletionRequestAdmin(admin.ModelAdmin):
    """Staff queue for erasures. Read-mostly: the client owns the request, the
    reviewer owns the outcome, and the request's own timestamps are evidence of
    when consent was given - so they are not editable here."""

    list_display = ("id", "user", "status", "reason", "requested_at", "grace_until", "processed_by")
    list_filter = ("status", "reason", "requested_at")
    search_fields = ("user__email", "user__username", "user__first_name", "user__last_name", "details")
    readonly_fields = ("user", "reason", "details", "requested_at", "grace_until", "obligations_snapshot")
    date_hierarchy = "requested_at"

    def save_model(self, request, obj, form, change):
        # Stamp who actioned it, so an erasure is always attributable.
        if change and obj.status != AccountDeletionRequest.Status.PENDING and obj.processed_by is None:
            obj.processed_by = request.user
            obj.processed_at = timezone.now()
        super().save_model(request, obj, form, change)
