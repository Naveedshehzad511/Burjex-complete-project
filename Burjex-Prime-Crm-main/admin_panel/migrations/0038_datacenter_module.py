from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("admin_panel", "0037_account_type_wizard_fields"),
    ]

    operations = [
        migrations.CreateModel(
            name="DataCenterApiKey",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120)),
                ("api_key", models.CharField(db_index=True, max_length=120, unique=True)),
                ("secret_key", models.CharField(max_length=255)),
                ("permissions", models.JSONField(blank=True, default=list)),
                ("is_active", models.BooleanField(db_index=True, default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("revoked_at", models.DateTimeField(blank=True, null=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.CreateModel(
            name="DataCenterBackup",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=160)),
                ("backup_type", models.CharField(default="FULL", max_length=30)),
                ("file", models.FileField(blank=True, null=True, upload_to="datacenter/backups/")),
                ("metadata", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.CreateModel(
            name="DataCenterEventLog",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("source", models.CharField(default="system", max_length=40)),
                ("event_type", models.CharField(db_index=True, max_length=80)),
                ("status", models.CharField(choices=[("processed", "Processed"), ("needs_review", "Needs Review")], db_index=True, default="processed", max_length=20)),
                ("provider", models.CharField(blank=True, default="", max_length=120)),
                ("notes", models.TextField(blank=True, default="")),
                ("payload", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.CreateModel(
            name="DataCenterImportJob",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(default="Import Job", max_length=120)),
                ("import_option", models.CharField(max_length=40)),
                ("file", models.FileField(blank=True, null=True, upload_to="datacenter/imports/")),
                ("file_format", models.CharField(default="CSV", max_length=10)),
                ("status", models.CharField(default="PROCESSED", max_length=20)),
                ("summary", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.CreateModel(
            name="DataCenterMcpSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("server_settings", models.JSONField(blank=True, default=dict)),
                ("queue_settings", models.JSONField(blank=True, default=dict)),
                ("sync_settings", models.JSONField(blank=True, default=dict)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.CreateModel(
            name="DataCenterWebhook",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120)),
                ("endpoint_url", models.URLField(max_length=500)),
                ("secret_key", models.CharField(max_length=255)),
                ("event_type", models.CharField(choices=[("user_created", "User Created"), ("user_updated", "User Updated"), ("kyc_submitted", "KYC Submitted"), ("kyc_approved", "KYC Approved"), ("kyc_rejected", "KYC Rejected"), ("deposit_created", "Deposit Created"), ("withdrawal_created", "Withdrawal Created"), ("account_created", "Account Created"), ("account_approved", "Account Approved")], db_index=True, max_length=40)),
                ("is_active", models.BooleanField(db_index=True, default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"ordering": ["-created_at"]},
        ),
    ]
