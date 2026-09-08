from django.db import migrations, models


def sync_enable_integration_from_enabled(apps, schema_editor):
    EmailProvider = apps.get_model("admin_panel", "EmailProvider")
    for row in EmailProvider.objects.all():
        row.enable_integration = bool(row.enabled)
        row.save(update_fields=["enable_integration"])


def truncate_long_api_keys(apps, schema_editor):
    EmailProvider = apps.get_model("admin_panel", "EmailProvider")
    for row in EmailProvider.objects.all():
        v = row.api_key or ""
        if len(v) > 2048:
            row.api_key = v[:2048]
            row.save(update_fields=["api_key"])


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0045_smsprovider_sender_email"),
    ]

    operations = [
        migrations.AddField(
            model_name="emailprovider",
            name="enable_integration",
            field=models.BooleanField(
                default=False,
                help_text="Reoon and other providers: master toggle for the integration UI.",
            ),
        ),
        migrations.RunPython(sync_enable_integration_from_enabled, migrations.RunPython.noop),
        migrations.RunPython(truncate_long_api_keys, migrations.RunPython.noop),
        migrations.AlterField(
            model_name="emailprovider",
            name="api_key",
            field=models.CharField(blank=True, default="", max_length=2048),
        ),
    ]
