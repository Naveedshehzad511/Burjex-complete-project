from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0021_bonus_template_system"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="avatar",
            field=models.ImageField(
                blank=True,
                help_text="Optional profile photo shown in the client portal header.",
                null=True,
                upload_to="user_avatars/",
            ),
        ),
    ]
