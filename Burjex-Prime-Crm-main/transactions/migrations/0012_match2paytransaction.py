import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("transactions", "0011_transaction_withdraw_snapshots_processed_by"),
    ]

    operations = [
        migrations.CreateModel(
            name="Match2PayTransaction",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("amount", models.DecimalField(decimal_places=2, max_digits=20)),
                ("currency", models.CharField(default="USD", max_length=10)),
                ("network", models.CharField(db_index=True, max_length=20)),
                ("payment_id", models.CharField(db_index=True, max_length=120, unique=True)),
                ("txid", models.CharField(blank=True, db_index=True, default="", max_length=200)),
                ("address", models.CharField(blank=True, default="", max_length=255)),
                (
                    "qr_code_data",
                    models.TextField(
                        blank=True,
                        default="",
                        help_text="Base64 image data or absolute URL for QR display.",
                    ),
                ),
                (
                    "status",
                    models.CharField(
                        choices=[("PENDING", "Pending"), ("COMPLETED", "Completed"), ("FAILED", "Failed")],
                        db_index=True,
                        default="PENDING",
                        max_length=15,
                    ),
                ),
                ("raw_create_response", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(default=django.utils.timezone.now)),
                ("completed_at", models.DateTimeField(blank=True, null=True)),
                (
                    "payment_gateway",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="match2pay_transactions",
                        to="transactions.paymentgateway",
                    ),
                ),
                (
                    "user",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="match2pay_transactions",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "ordering": ["-created_at"],
            },
        ),
    ]
