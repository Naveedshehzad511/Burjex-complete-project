from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0092_social_login_settings"),
    ]

    operations = [
        migrations.CreateModel(
            name="OnboardingSlide",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("title", models.CharField(blank=True, default="", max_length=120)),
                ("description", models.CharField(blank=True, default="", max_length=300)),
                (
                    "image",
                    models.ImageField(
                        help_text="Portrait artwork, ideally 1080x1440 or smaller (keep it under ~300 KB).",
                        upload_to="branding/onboarding",
                    ),
                ),
                ("sort_order", models.PositiveSmallIntegerField(default=0, help_text="Lower numbers show first.")),
                ("is_active", models.BooleanField(default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name": "Onboarding slide",
                "verbose_name_plural": "Onboarding slides",
                "ordering": ["sort_order", "id"],
            },
        ),
    ]
