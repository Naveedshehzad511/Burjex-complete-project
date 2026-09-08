# Generated manually

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0011_emailinboxmessage_smtpsettings_imap_host_and_more"),
    ]

    operations = [
        migrations.CreateModel(
            name="StatusBadgeSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("data", models.JSONField(blank=True, default=dict)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name_plural": "Status badge settings",
            },
        ),
    ]
