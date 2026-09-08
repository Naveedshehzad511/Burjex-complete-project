# Generated manually for login page branding.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0017_portalbrandingsettings"),
    ]

    operations = [
        migrations.CreateModel(
            name="LoginBrandingSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("admin_login_logo", models.FileField(blank=True, null=True, upload_to="branding/login")),
                ("admin_login_background", models.FileField(blank=True, null=True, upload_to="branding/login")),
                ("admin_login_title", models.CharField(blank=True, default="", max_length=120)),
                ("admin_login_subtitle", models.CharField(blank=True, default="", max_length=255)),
                ("admin_button_color", models.CharField(default="#0B3C5D", max_length=32)),
                ("admin_background_overlay", models.CharField(default="rgba(15, 23, 42, 0.55)", max_length=80)),
                ("user_login_logo", models.FileField(blank=True, null=True, upload_to="branding/login")),
                ("user_login_background", models.FileField(blank=True, null=True, upload_to="branding/login")),
                ("user_login_title", models.CharField(blank=True, default="", max_length=120)),
                ("user_login_subtitle", models.CharField(blank=True, default="", max_length=255)),
                ("user_button_color", models.CharField(default="#0B3C5D", max_length=32)),
                ("user_background_overlay", models.CharField(default="rgba(15, 23, 42, 0.45)", max_length=80)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name": "Login branding",
                "verbose_name_plural": "Login branding",
            },
        ),
    ]
