from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0071_email_branding_button_and_name_override"),
    ]

    operations = [
        migrations.AddField(
            model_name="match2payintegrationsettings",
            name="documentation_url",
            field=models.URLField(blank=True, default="", max_length=500),
        ),
    ]
