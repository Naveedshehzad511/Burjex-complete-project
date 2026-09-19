from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("admin_panel", "0092_social_login_settings"),
    ]

    operations = [
        migrations.CreateModel(
            name="CashbackRate",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "alias",
                    models.CharField(
                        db_index=True,
                        help_text="Client alias from symbol groups (XAUUSD.s), never the LP feed name.",
                        max_length=64,
                        unique=True,
                    ),
                ),
                ("amount_usd", models.DecimalField(decimal_places=2, default=0, max_digits=20)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "updated_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="cashback_rates_updated",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "db_table": "cashback_rates",
                "ordering": ["alias"],
            },
        ),
        migrations.CreateModel(
            name="CashbackPayout",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("engine_trade_id", models.CharField(db_index=True, max_length=64, unique=True)),
                ("deal_id", models.CharField(blank=True, default="", max_length=64)),
                ("login_id", models.CharField(db_index=True, max_length=64)),
                ("alias", models.CharField(db_index=True, max_length=64)),
                ("amount", models.DecimalField(decimal_places=2, max_digits=20)),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                (
                    "user",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="cashback_payouts",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "db_table": "cashback_payouts",
                "ordering": ["-created_at"],
            },
        ),
    ]
