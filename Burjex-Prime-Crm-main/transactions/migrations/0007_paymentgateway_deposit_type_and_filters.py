from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("transactions", "0006_paymentgateway_treasury_fields"),
    ]

    operations = [
        migrations.AddField(
            model_name="paymentgateway",
            name="allowed_account_types",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="country_filters",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="custom_fields",
            field=models.JSONField(blank=True, default=list),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="first_time_deposit_only",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="flag_high_value",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="flag_problem_user",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="flag_vip",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="flag_watch_list",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="instruction_steps",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="integration_mode",
            field=models.CharField(
                choices=[("SANDBOX", "Sandbox"), ("LIVE", "Live")],
                default="SANDBOX",
                max_length=10,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="kyc_level",
            field=models.CharField(blank=True, default="", max_length=80),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="require_transaction_id",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_chargeback",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_fraud",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_kyc",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_pep",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_suspicious",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_trading",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="risk_withdrawal",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="third_party_provider",
            field=models.CharField(
                choices=[
                    ("NONE", "None"),
                    ("MATCH2PAY", "Match2Pay"),
                    ("STRIPE", "Stripe"),
                    ("PAYPAL", "PayPal"),
                    ("SKRILL", "Skrill"),
                    ("NETELLER", "Neteller"),
                    ("COINBASE", "Coinbase"),
                ],
                default="NONE",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="paymentgateway",
            name="user_fields",
            field=models.JSONField(blank=True, default=list),
        ),
    ]
