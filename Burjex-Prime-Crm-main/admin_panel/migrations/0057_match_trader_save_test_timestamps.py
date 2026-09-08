# Generated manually for Match-Trader activation flow (save → test → activate).

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0056_wipe_sample_crm_ib_data"),
    ]

    operations = [
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_save_at",
            field=models.DateTimeField(
                blank=True,
                help_text="Last explicit Save Configuration (activation requires a successful test after this).",
                null=True,
            ),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_test_success_at",
            field=models.DateTimeField(
                blank=True,
                help_text="Last successful GET /health check.",
                null=True,
            ),
        ),
    ]
