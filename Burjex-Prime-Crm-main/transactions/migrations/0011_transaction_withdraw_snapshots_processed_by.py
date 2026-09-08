import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("transactions", "0010_balance_ledger_deposit_entry_types"),
    ]

    operations = [
        migrations.AddField(
            model_name="transaction",
            name="balance_snapshot_wallet",
            field=models.DecimalField(
                blank=True,
                decimal_places=2,
                help_text="User wallet_balance immediately after this withdrawal hold was placed (client withdrawals).",
                max_digits=20,
                null=True,
            ),
        ),
        migrations.AddField(
            model_name="transaction",
            name="balance_snapshot_pending",
            field=models.DecimalField(
                blank=True,
                decimal_places=2,
                help_text="User pending_withdraw total immediately after this withdrawal hold was placed.",
                max_digits=20,
                null=True,
            ),
        ),
        migrations.AddField(
            model_name="transaction",
            name="processed_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="processed_transactions",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
    ]
