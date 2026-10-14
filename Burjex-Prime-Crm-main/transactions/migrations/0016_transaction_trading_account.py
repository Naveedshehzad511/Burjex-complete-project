import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0093_onboarding_slide"),
        ("transactions", "0015_processedaction"),
    ]

    operations = [
        migrations.AddField(
            model_name="transaction",
            name="trading_account",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="withdraw_transactions",
                to="admin_panel.tradingaccount",
            ),
        ),
    ]
