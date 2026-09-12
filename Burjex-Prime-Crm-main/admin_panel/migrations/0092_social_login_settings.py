from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0091_organization_branding_asset_slots"),
    ]

    operations = [
        migrations.CreateModel(
            name="SocialLoginSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("google_enabled", models.BooleanField(default=True)),
                ("google_client_id", models.CharField(blank=True, default="", max_length=255)),
                ("google_client_secret", models.TextField(blank=True, default="")),
                ("apple_enabled", models.BooleanField(default=True)),
                (
                    "apple_client_id",
                    models.CharField(
                        blank=True,
                        default="",
                        help_text="Apple Services ID (web) / Bundle ID (native).",
                        max_length=255,
                    ),
                ),
                ("apple_team_id", models.CharField(blank=True, default="", max_length=32)),
                ("apple_key_id", models.CharField(blank=True, default="", max_length=32)),
                (
                    "apple_private_key",
                    models.TextField(blank=True, default="", help_text="Apple Sign In .p8 private key (PEM)."),
                ),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
    ]
