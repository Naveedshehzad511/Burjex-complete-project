from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0048_bonus_template_system"),
    ]

    operations = [
        migrations.CreateModel(
            name="EmailTemplateSettings",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "email_logo",
                    models.FileField(
                        blank=True,
                        help_text="PNG, JPG, or SVG. Used in email headers when set.",
                        max_length=500,
                        null=True,
                        upload_to="email_template_settings/logos/",
                    ),
                ),
                (
                    "logo_position",
                    models.CharField(
                        choices=[("left", "Left"), ("center", "Center"), ("right", "Right")],
                        default="center",
                        max_length=10,
                    ),
                ),
                (
                    "logo_size",
                    models.CharField(
                        choices=[("small", "Small"), ("medium", "Medium"), ("large", "Large")],
                        default="medium",
                        max_length=10,
                    ),
                ),
                ("header_color", models.CharField(default="#0B3C5D", max_length=7)),
                (
                    "show_company_name",
                    models.BooleanField(
                        default=True,
                        help_text="When a logo is set, also show the company name under the logo.",
                    ),
                ),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "verbose_name_plural": "Email template settings",
                "db_table": "email_template_settings",
            },
        ),
    ]
