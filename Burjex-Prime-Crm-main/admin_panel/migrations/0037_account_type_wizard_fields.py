from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0019_mt5group_remove_legacy_fields"),
        ("admin_panel", "0036_client_tagging_system"),
    ]

    operations = [
        migrations.AddField(
            model_name="tradingaccounttype",
            name="account_mode",
            field=models.CharField(default="REGULAR_ONLY", max_length=30),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="demo_enabled",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="demo_expiry_days",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="geographic_countries",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="geographic_mode",
            field=models.CharField(default="ALLOW", max_length=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="geographic_restrictions_enabled",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="headline",
            field=models.CharField(blank=True, default="", max_length=180),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="inactivity_fee_after_days",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="inactivity_fee_amount",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="kyc_requirement",
            field=models.CharField(default="NONE", max_length=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="leverage_options",
            field=models.JSONField(blank=True, default=list),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="maintenance_fee_amount",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="manual_group_name",
            field=models.CharField(blank=True, default="", max_length=180),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_demo_accounts",
            field=models.PositiveIntegerField(default=1),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_live_accounts",
            field=models.PositiveIntegerField(default=1),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_single_deposit",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_total_balance",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_withdrawal_per_day",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_withdrawal_per_request",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="max_withdrawal_requests_per_day",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="min_first_deposit",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="min_spread",
            field=models.DecimalField(decimal_places=4, default=0, max_digits=12),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="require_email_verified",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="require_id_document",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="require_phone_verified",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="require_proof_of_address",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="server_name",
            field=models.CharField(blank=True, default="", max_length=180),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="user_type",
            field=models.CharField(default="INDIVIDUAL", max_length=20),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="demo_group",
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="demo_account_types", to="accounts.mt5group"),
        ),
        migrations.AlterField(
            model_name="tradingaccounttype",
            name="currency",
            field=models.CharField(choices=[("USD", "USD"), ("EUR", "EUR"), ("GBP", "GBP"), ("AUD", "AUD")], default="USD", max_length=10),
        ),
    ]
