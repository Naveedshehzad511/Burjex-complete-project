from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0028_demoaccountsettings"),
    ]

    operations = [
        migrations.AddField(
            model_name="emailsettings",
            name="event_template_map",
            field=models.JSONField(blank=True, default=dict),
        ),
    ]
