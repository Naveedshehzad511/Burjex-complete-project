from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0078_remove_datacenter_module"),
    ]

    operations = [
        migrations.CreateModel(
            name="UserPortalThemeSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "light_primary_color",
                    models.CharField(
                        blank=True,
                        default="",
                        help_text="Primary colour for user portal light mode. Empty = admin panel default.",
                        max_length=32,
                    ),
                ),
                (
                    "dark_primary_color",
                    models.CharField(
                        blank=True,
                        default="",
                        help_text="Primary colour for user portal dark mode. Empty = admin panel default.",
                        max_length=32,
                    ),
                ),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name": "User portal theme",
                "verbose_name_plural": "User portal theme",
            },
        ),
    ]
