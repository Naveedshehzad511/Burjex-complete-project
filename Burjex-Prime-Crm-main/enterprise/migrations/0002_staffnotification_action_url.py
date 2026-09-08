from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("enterprise", "0001_enterprise_and_user_totp"),
    ]

    operations = [
        migrations.AddField(
            model_name="staffnotification",
            name="action_url",
            field=models.CharField(
                blank=True,
                default="",
                help_text="Optional path or URL to open when the notification is clicked (e.g. /admin-panel/tickets/).",
                max_length=512,
            ),
        ),
    ]
