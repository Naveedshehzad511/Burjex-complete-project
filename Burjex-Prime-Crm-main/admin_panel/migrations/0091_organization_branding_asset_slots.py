from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0090_tradingplatformintegration_btrader"),
    ]

    operations = [
        migrations.AddField(
            model_name="organizationprofilesettings",
            name="app_icon",
            field=models.ImageField(
                blank=True,
                help_text="App launcher icon. Recommended 1024x1024 px PNG.",
                null=True,
                upload_to="organization/icons/",
            ),
        ),
        migrations.AddField(
            model_name="organizationprofilesettings",
            name="login_logo",
            field=models.ImageField(
                blank=True,
                help_text="Sign-in / splash logo. Recommended 600x200 px (or square mark).",
                null=True,
                upload_to="organization/login/",
            ),
        ),
        migrations.AddField(
            model_name="organizationprofilesettings",
            name="sidebar_logo",
            field=models.ImageField(
                blank=True,
                help_text="Sidebar / drawer logo. Recommended 200x200 px.",
                null=True,
                upload_to="organization/sidebar/",
            ),
        ),
    ]
