from django.db import migrations, models


def seed_zoho_mail_provider(apps, schema_editor):
    EmailProvider = apps.get_model("admin_panel", "EmailProvider")
    EmailProvider.objects.get_or_create(
        provider="ZOHO_MAIL",
        defaults={
            "enabled": False,
            "is_active": False,
            "integration_name": "Zoho Mail",
            "extra_config": {},
        },
    )


def seed_compliance_providers(apps, schema_editor):
    ComplianceIntegration = apps.get_model("admin_panel", "ComplianceIntegration")
    for p, label in [
        ("IDNOW", "IDnow"),
        ("KYC_CHAIN", "KYC Chain"),
        ("VERIFF", "Veriff"),
    ]:
        ComplianceIntegration.objects.get_or_create(provider=p, defaults={"enabled": False})


def seed_ai_integrations(apps, schema_editor):
    AIIntegration = apps.get_model("admin_panel", "AIIntegration")
    for slug, name in [
        ("BROKERET_AI", "Brokeret AI"),
        ("BUILTIN_AI", "Built-in AI"),
        ("CHATGPT", "ChatGPT"),
        ("GEMINI", "Gemini"),
        ("GROK", "Grok"),
    ]:
        AIIntegration.objects.get_or_create(
            slug=slug,
            defaults={"integration_name": name, "category": "AI_ML", "status": "INACTIVE"},
        )


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0042_riskmonitorsettings"),
    ]

    operations = [
        migrations.AddField(
            model_name="emailprovider",
            name="extra_config",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddField(
            model_name="emailprovider",
            name="integration_name",
            field=models.CharField(blank=True, default="", max_length=120),
        ),
        migrations.AddField(
            model_name="emailprovider",
            name="last_test_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="emailprovider",
            name="last_test_detail",
            field=models.CharField(blank=True, default="", max_length=500),
        ),
        migrations.AddField(
            model_name="emailprovider",
            name="last_test_ok",
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AlterField(
            model_name="emailprovider",
            name="provider",
            field=models.CharField(
                choices=[
                    ("AMAZON_SES", "Amazon SES"),
                    ("MAILGUN", "Mailgun"),
                    ("POSTMARK", "Postmark"),
                    ("SENDGRID", "SendGrid"),
                    ("ZEPTOMAIL", "ZeptoMail"),
                    ("SMTP_UNIVERSAL", "SMTP Universal"),
                    ("REOON", "Reoon Email Verifier"),
                    ("ZOHO_MAIL", "Zoho Mail"),
                ],
                max_length=30,
                unique=True,
            ),
        ),
        migrations.AddField(
            model_name="complianceintegration",
            name="integration_name",
            field=models.CharField(blank=True, default="", max_length=120),
        ),
        migrations.AddField(
            model_name="complianceintegration",
            name="last_test_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="complianceintegration",
            name="last_test_detail",
            field=models.CharField(blank=True, default="", max_length=500),
        ),
        migrations.AddField(
            model_name="complianceintegration",
            name="last_test_ok",
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AlterField(
            model_name="complianceintegration",
            name="provider",
            field=models.CharField(
                choices=[
                    ("SUMSUB", "Sumsub"),
                    ("ONFIDO", "Onfido"),
                    ("SHUFTI_PRO", "Shufti Pro"),
                    ("KYC_VERIFICATION", "KYC Verification"),
                    ("CUSTOM_API", "Custom API"),
                    ("IDNOW", "IDnow"),
                    ("KYC_CHAIN", "KYC Chain"),
                    ("VERIFF", "Veriff"),
                ],
                max_length=30,
                unique=True,
            ),
        ),
        migrations.AddField(
            model_name="supportintegration",
            name="category",
            field=models.CharField(blank=True, default="CUSTOMER_SUPPORT", max_length=40),
        ),
        migrations.AddField(
            model_name="supportintegration",
            name="integration_name",
            field=models.CharField(blank=True, default="", max_length=120),
        ),
        migrations.AddField(
            model_name="supportintegration",
            name="last_test_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="supportintegration",
            name="last_test_detail",
            field=models.CharField(blank=True, default="", max_length=500),
        ),
        migrations.AddField(
            model_name="supportintegration",
            name="last_test_ok",
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="tradingplatformintegration",
            name="extended_config",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.CreateModel(
            name="IntegrationConnectionLog",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("integration_slug", models.CharField(db_index=True, max_length=80)),
                ("category", models.CharField(blank=True, default="", max_length=40)),
                ("success", models.BooleanField(default=False)),
                ("message", models.TextField(blank=True, default="")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.CreateModel(
            name="AIIntegration",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "slug",
                    models.CharField(
                        choices=[
                            ("BROKERET_AI", "Brokeret AI"),
                            ("BUILTIN_AI", "Built-in AI"),
                            ("CHATGPT", "ChatGPT"),
                            ("GEMINI", "Gemini"),
                            ("GROK", "Grok"),
                        ],
                        db_index=True,
                        max_length=32,
                        unique=True,
                    ),
                ),
                ("enabled", models.BooleanField(default=False)),
                ("integration_name", models.CharField(blank=True, default="", max_length=120)),
                ("category", models.CharField(default="AI_ML", max_length=40)),
                ("status", models.CharField(default="INACTIVE", max_length=12)),
                ("api_key", models.TextField(blank=True, default="")),
                ("api_secret", models.TextField(blank=True, default="")),
                ("base_url", models.CharField(blank=True, default="", max_length=500)),
                ("model_name", models.CharField(blank=True, default="", max_length=120)),
                ("extra_config", models.JSONField(blank=True, default=dict)),
                ("last_test_ok", models.BooleanField(blank=True, null=True)),
                ("last_test_at", models.DateTimeField(blank=True, null=True)),
                ("last_test_detail", models.CharField(blank=True, default="", max_length=500)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"ordering": ["slug"]},
        ),
        migrations.CreateModel(
            name="ReCaptchaIntegrationSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("enabled", models.BooleanField(default=False)),
                ("site_key", models.CharField(blank=True, default="", max_length=255)),
                ("secret_key", models.TextField(blank=True, default="")),
                ("version", models.CharField(default="v2_checkbox", max_length=20)),
                ("apply_login", models.BooleanField(default=False)),
                ("apply_signup", models.BooleanField(default=True)),
                ("apply_withdrawal", models.BooleanField(default=False)),
                ("score_threshold", models.DecimalField(decimal_places=2, default=0.5, max_digits=3)),
                ("enable_logging", models.BooleanField(default=False)),
                ("last_test_ok", models.BooleanField(blank=True, null=True)),
                ("last_test_at", models.DateTimeField(blank=True, null=True)),
                ("last_test_detail", models.CharField(blank=True, default="", max_length=500)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.CreateModel(
            name="Google2FAIntegrationSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("enabled", models.BooleanField(default=False)),
                ("method_google_auth", models.BooleanField(default=True)),
                ("method_microsoft_auth", models.BooleanField(default=True)),
                ("method_authy", models.BooleanField(default=False)),
                ("apply_client_login", models.BooleanField(default=False)),
                ("apply_admin_login", models.BooleanField(default=False)),
                ("apply_withdrawal", models.BooleanField(default=False)),
                ("apply_password_change", models.BooleanField(default=False)),
                ("apply_wallet_access", models.BooleanField(default=False)),
                ("apply_profile_changes", models.BooleanField(default=False)),
                ("backup_codes_enabled", models.BooleanField(default=True)),
                ("remember_device_days", models.PositiveIntegerField(default=30)),
                ("force_2fa_admin", models.BooleanField(default=False)),
                ("force_2fa_clients", models.BooleanField(default=False)),
                ("otp_expiry_seconds", models.PositiveIntegerField(default=30)),
                ("max_attempts", models.PositiveIntegerField(default=5)),
                ("lockout_seconds", models.PositiveIntegerField(default=900)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.CreateModel(
            name="Match2PayIntegrationSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("enabled", models.BooleanField(default=False)),
                ("api_token", models.TextField(blank=True, default="")),
                ("api_secret", models.TextField(blank=True, default="")),
                ("merchant_id", models.CharField(blank=True, default="", max_length=120)),
                ("api_url", models.CharField(blank=True, default="", max_length=500)),
                ("webhook_url", models.CharField(blank=True, default="", max_length=500)),
                ("currencies_config", models.JSONField(blank=True, default=dict)),
                ("deposit_auto_credit", models.BooleanField(default=False)),
                ("deposit_manual_approval", models.BooleanField(default=True)),
                ("deposit_confirmations", models.PositiveIntegerField(default=3)),
                ("withdrawal_enabled", models.BooleanField(default=False)),
                ("withdrawal_manual_approval", models.BooleanField(default=True)),
                ("withdrawal_fee_percent", models.DecimalField(decimal_places=2, default=0, max_digits=6)),
                ("last_test_ok", models.BooleanField(blank=True, null=True)),
                ("last_test_at", models.DateTimeField(blank=True, null=True)),
                ("last_test_detail", models.CharField(blank=True, default="", max_length=500)),
                ("last_webhook_test_ok", models.BooleanField(blank=True, null=True)),
                ("last_webhook_test_at", models.DateTimeField(blank=True, null=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.RunPython(seed_zoho_mail_provider, migrations.RunPython.noop),
        migrations.RunPython(seed_compliance_providers, migrations.RunPython.noop),
        migrations.RunPython(seed_ai_integrations, migrations.RunPython.noop),
    ]
