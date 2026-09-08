import django.utils.timezone
from django.db import migrations, models


def backfill_template_type_and_created(apps, schema_editor):
    EmailTemplate = apps.get_model("admin_panel", "EmailTemplate")
    mapping = {
        "forgot_password": "forgot_password",
        "password_reset": "forgot_password",
        "signup_welcome": "signup_welcome",
        "email_verification": "email_verification",
        "email_verified": "email_verification",
        "kyc_approved": "kyc_approved",
        "kyc_rejected": "kyc_rejected",
        "deposit_submitted": "deposit_confirmation",
        "deposit_approved": "deposit_confirmation",
        "withdrawal_submitted": "withdrawal_confirmation",
        "withdrawal_approved": "withdrawal_confirmation",
        "account_created": "account_created",
    }
    now = django.utils.timezone.now()
    for row in EmailTemplate.objects.all():
        if row.created_at is None:
            row.created_at = now
        key = (row.event_key or "").strip()
        row.template_type = mapping.get(key, "custom")
        row.save(update_fields=["template_type", "created_at"])


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0046_emailprovider_enable_integration_api_key_char"),
    ]

    operations = [
        migrations.CreateModel(
            name="EmailGlobalLayout",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("wrap_enabled", models.BooleanField(default=True)),
                (
                    "site_base_url",
                    models.CharField(
                        blank=True,
                        default="",
                        help_text="Public site URL (e.g. https://broker.com) for absolute image links in emails.",
                        max_length=255,
                    ),
                ),
                ("company_logo", models.ImageField(blank=True, null=True, upload_to="email_layout/logos/")),
                (
                    "header_html",
                    models.TextField(
                        blank=True,
                        default="",
                        help_text="Optional HTML below logo (supports {{variables}}).",
                    ),
                ),
                (
                    "footer_html",
                    models.TextField(
                        blank=True,
                        default="",
                        help_text="Optional HTML below the footer block.",
                    ),
                ),
                (
                    "risk_disclaimer",
                    models.TextField(
                        blank=True,
                        default="Risk disclaimer: Trading forex and CFDs involves substantial risk and is not suitable for all investors.",
                    ),
                ),
                ("company_address", models.TextField(blank=True, default="")),
                ("support_email", models.CharField(blank=True, default="", max_length=254)),
                ("website_url", models.CharField(blank=True, default="", max_length=500)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name_plural": "Email global layouts",
                "db_table": "email_global_layout",
            },
        ),
        migrations.AddField(
            model_name="emailtemplate",
            name="template_type",
            field=models.CharField(
                choices=[
                    ("forgot_password", "Forgot Password"),
                    ("signup_welcome", "Signup Welcome"),
                    ("email_verification", "Email Verification"),
                    ("otp_verification", "OTP Verification"),
                    ("kyc_approved", "KYC Approved"),
                    ("kyc_rejected", "KYC Rejected"),
                    ("deposit_confirmation", "Deposit Confirmation"),
                    ("withdrawal_confirmation", "Withdrawal Confirmation"),
                    ("account_created", "Account Created"),
                    ("custom", "Custom Template"),
                ],
                db_index=True,
                default="custom",
                max_length=40,
            ),
        ),
        migrations.AlterField(
            model_name="emailtemplate",
            name="created_at",
            field=models.DateTimeField(auto_now_add=True, null=True),
        ),
        migrations.RunPython(backfill_template_type_and_created, noop_reverse),
        migrations.AlterField(
            model_name="emailtemplate",
            name="created_at",
            field=models.DateTimeField(auto_now_add=True),
        ),
        migrations.AlterField(
            model_name="emailtemplate",
            name="event_key",
            field=models.CharField(
                blank=True,
                default="",
                help_text="Routing key used by send_event_email (e.g. forgot_password, deposit_submitted).",
                max_length=64,
                unique=True,
            ),
        ),
        migrations.AlterModelTable(
            name="emailtemplate",
            table="email_templates",
        ),
    ]
