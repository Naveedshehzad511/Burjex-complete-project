from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("ib", "0011_remove_ibprofile_assigned_rebate_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="ibcommissionmatrixrule",
            name="platform",
            field=models.CharField(
                choices=[("MT5", "MT5"), ("BTRADER", "BTrader")],
                db_index=True,
                default="MT5",
                help_text="MT5 = existing MetaTrader rebate path. BTrader = engine close rebate ($ / 1.00 lot).",
                max_length=16,
            ),
        ),
        migrations.CreateModel(
            name="ProcessedBTraderDeal",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("deal_id", models.CharField(db_index=True, max_length=64, unique=True)),
                ("position_id", models.CharField(blank=True, db_index=True, default="", max_length=64)),
                ("login_id", models.CharField(db_index=True, max_length=64)),
                ("symbol", models.CharField(max_length=64)),
                ("volume_lots", models.DecimalField(decimal_places=4, max_digits=12)),
                ("rebate_per_lot", models.DecimalField(decimal_places=4, max_digits=12)),
                ("rebate_amount", models.DecimalField(decimal_places=4, max_digits=20)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                (
                    "ib_user",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="processed_btrader_deals",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "ordering": ["-created_at"],
            },
        ),
    ]
