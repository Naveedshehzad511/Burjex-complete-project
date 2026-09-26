import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0039_user_social_login"),
    ]

    operations = [
        migrations.CreateModel(
            name="PushDevice",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("token", models.CharField(max_length=512, unique=True)),
                ("platform", models.CharField(choices=[("ios", "iOS"), ("android", "Android")], max_length=10)),
                ("is_active", models.BooleanField(db_index=True, default=True)),
                ("last_error", models.CharField(blank=True, default="", max_length=255)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("last_seen_at", models.DateTimeField(default=django.utils.timezone.now)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="push_devices", to=settings.AUTH_USER_MODEL)),
            ],
            options={"indexes": [models.Index(fields=["user", "is_active"], name="accounts_pu_user_id_4c1f0a_idx")]},
        ),
        migrations.CreateModel(
            name="PushDelivery",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("status", models.CharField(default="pending", max_length=10)),
                ("error", models.CharField(blank=True, default="", max_length=255)),
                ("attempts", models.PositiveSmallIntegerField(default=0)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("device", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="deliveries", to="accounts.pushdevice")),
                ("notification", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="push_deliveries", to="accounts.clientnotification")),
            ],
            options={"constraints": [models.UniqueConstraint(fields=("notification", "device"), name="uniq_push_per_notification_device")]},
        ),
    ]
