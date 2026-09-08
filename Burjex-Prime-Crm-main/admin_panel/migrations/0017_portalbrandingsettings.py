# Generated manually for portal branding assets.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0016_sidebaruisettings_sidebar_logo"),
    ]

    operations = [
        migrations.CreateModel(
            name="PortalBrandingSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("admin_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("admin_favicon", models.FileField(blank=True, null=True, upload_to="branding")),
                ("admin_login_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("admin_sidebar_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("user_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("user_favicon", models.FileField(blank=True, null=True, upload_to="branding")),
                ("user_login_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("user_dashboard_logo", models.FileField(blank=True, null=True, upload_to="branding")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name": "Portal branding",
                "verbose_name_plural": "Portal branding",
            },
        ),
    ]
