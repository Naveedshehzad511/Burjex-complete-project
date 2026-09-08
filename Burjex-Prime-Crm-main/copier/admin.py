from django.contrib import admin

from .models import CopyTradingAccount, CopierFollower


@admin.register(CopyTradingAccount)
class CopyTradingAccountAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "master_trader", "status", "created_at")
    list_filter = ("status",)
    search_fields = ("name", "master_trader__email")
    raw_id_fields = ("master_trader",)


@admin.register(CopierFollower)
class CopierFollowerAdmin(admin.ModelAdmin):
    list_display = ("id", "copy_account", "follower", "follower_risk_multiplier", "status", "created_at")
    list_filter = ("status", "copy_account")
    search_fields = ("follower__email",)
    raw_id_fields = ("copy_account", "follower")
