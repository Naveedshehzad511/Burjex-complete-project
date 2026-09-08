# Generated manually for Match-Trader REST base URL

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0061_crm_group_symbol_sync"),
    ]

    operations = [
        migrations.AddField(
            model_name="matchtradersettings",
            name="rest_base_url",
            field=models.URLField(
                blank=True,
                default="",
                help_text="HTTPS base for Match-Trader REST (groups, catalog). If empty, Base URL is used.",
                max_length=500,
            ),
        ),
        migrations.AlterField(
            model_name="matchtradersettings",
            name="base_url",
            field=models.URLField(
                blank=True,
                default="",
                help_text="Broker HTTPS URL used for gRPC/health context (e.g. same host as REST).",
                max_length=500,
            ),
        ),
    ]
