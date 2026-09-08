# Generated manually for user list / portal controls

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0011_document_review_comment_document_reviewed_at_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="account_status",
            field=models.CharField(
                choices=[
                    ("APPROVED", "Approve"),
                    ("PENDING", "Pending"),
                    ("SUSPENDED", "Suspended"),
                    ("BLOCKED", "Blocked"),
                ],
                default="APPROVED",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="force_password_change",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="user",
            name="ib_linked_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="user",
            name="ib_linked_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="ib_links_recorded",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="marketing_name",
            field=models.CharField(blank=True, default="", max_length=120),
        ),
        migrations.AddField(
            model_name="user",
            name="phone_verified",
            field=models.BooleanField(default=False),
        ),
        migrations.CreateModel(
            name="UserRestriction",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("disable_deposit", models.BooleanField(default=False)),
                ("disable_withdraw", models.BooleanField(default=False)),
                ("disable_transfer", models.BooleanField(default=False)),
                ("disable_internal_transfer", models.BooleanField(default=False)),
                ("disable_wallet_to_mt5", models.BooleanField(default=False)),
                ("disable_mt5_to_wallet", models.BooleanField(default=False)),
                ("disable_ib_withdraw", models.BooleanField(default=False)),
                ("disable_trading", models.BooleanField(default=False)),
                ("disable_create_mt5", models.BooleanField(default=False)),
                ("disable_profile_access", models.BooleanField(default=False)),
                ("disable_client_area", models.BooleanField(default=False)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "user",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="restriction",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
        ),
    ]
