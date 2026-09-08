from django.db import migrations, models


def sync_visibility_from_is_active(apps, schema_editor):
    PG = apps.get_model("transactions", "PaymentGateway")
    for g in PG.objects.all():
        g.visibility_status = "ACTIVE" if g.is_active else "INACTIVE"
        g.save(update_fields=["visibility_status"])


class Migration(migrations.Migration):

    dependencies = [
        ("transactions", "0005_transaction_request_uid_balanceledger"),
    ]

    operations = [
        migrations.AddField(
            model_name="paymentgateway",
            name="auto_approve_withdraw",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="category",
            field=models.CharField(blank=True, default="", max_length=80),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="cooldown_minutes",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="daily_withdraw_limit",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="display_badge",
            field=models.CharField(blank=True, default="", max_length=80),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="display_order",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="exchange_rate",
            field=models.DecimalField(decimal_places=8, default=1, max_digits=20),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="fee_type",
            field=models.CharField(
                choices=[("NONE", "None"), ("FIXED", "Fixed"), ("PERCENT", "Percentage")],
                default="NONE",
                max_length=15,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="fee_value",
            field=models.DecimalField(decimal_places=4, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="max_pending_per_user",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="processing_mode",
            field=models.CharField(
                choices=[("INSTANT", "Instant"), ("MANUAL", "Manual")],
                default="INSTANT",
                max_length=15,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="rate_markup",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="rate_mode",
            field=models.CharField(
                choices=[("FIXED", "Fixed"), ("MARKET", "Market")],
                default="FIXED",
                max_length=15,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="require_payment_proof",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="requires_2fa_for_method",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="requires_kyc_for_method",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="swift_code",
            field=models.CharField(blank=True, default="", max_length=40),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="visibility_status",
            field=models.CharField(
                choices=[("ACTIVE", "Active"), ("INACTIVE", "Inactive"), ("MAINTENANCE", "Maintenance")],
                default="ACTIVE",
                max_length=15,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="whitelist_required",
            field=models.BooleanField(default=False),
        ),
        migrations.RunPython(sync_visibility_from_is_active, migrations.RunPython.noop),
        migrations.AlterModelOptions(
            name="paymentgateway",
            options={"ordering": ["display_order", "name"]},
        ),
    ]
