from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0017_user_kyc_component_statuses"),
        ("admin_panel", "0027_complianceintegration_emailprovider_kycstatus_and_more"),
    ]

    operations = [
        migrations.CreateModel(
            name="DemoAccountSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("auto_create_on_signup", models.BooleanField(default=False)),
                ("default_balance", models.DecimalField(decimal_places=2, default=10000, max_digits=20)),
                ("default_leverage", models.PositiveIntegerField(default=500)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "default_account_type",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="default_demo_settings",
                        to="admin_panel.tradingaccounttype",
                    ),
                ),
                (
                    "default_group",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="demo_settings_defaults",
                        to="accounts.mt5group",
                    ),
                ),
            ],
        ),
    ]
