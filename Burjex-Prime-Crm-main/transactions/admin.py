from django.contrib import admin

from .models import PaymentGateway, Transaction


@admin.register(PaymentGateway)
class PaymentGatewayAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "code", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name", "code")


@admin.register(Transaction)
class TransactionAdmin(admin.ModelAdmin):
    list_display = ("id", "tx_type", "status", "actor", "amount", "currency", "payment_gateway", "created_at")
    list_filter = ("status", "tx_type", "payment_gateway", "currency")
    search_fields = ("actor__email", "reference", "notes")
    raw_id_fields = ("actor", "from_user", "to_user")
