# Unified login branding field names + welcome / size / position.

from django.db import migrations, models


def clamp_logo_opacity(apps, schema_editor):
    BrandSettings = apps.get_model("admin_panel", "BrandSettings")
    for row in BrandSettings.objects.all():
        try:
            o = float(row.logo_opacity)
        except (TypeError, ValueError):
            o = 0.1
        row.logo_opacity = max(0.05, min(0.2, o))
        row.save(update_fields=["logo_opacity"])


class Migration(migrations.Migration):
    dependencies = [
        ("admin_panel", "0019_brandsettings_login_appearance"),
    ]

    operations = [
        migrations.RenameField(
            model_name="brandsettings",
            old_name="login_background_logo",
            new_name="login_logo",
        ),
        migrations.RenameField(
            model_name="brandsettings",
            old_name="login_watermark_opacity",
            new_name="logo_opacity",
        ),
        migrations.AddField(
            model_name="brandsettings",
            name="welcome_text",
            field=models.CharField(default="Welcome Back", max_length=120),
        ),
        migrations.AddField(
            model_name="brandsettings",
            name="logo_size",
            field=models.CharField(
                choices=[
                    ("small", "Small"),
                    ("medium", "Medium"),
                    ("large", "Large"),
                ],
                default="medium",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="brandsettings",
            name="logo_position",
            field=models.CharField(
                choices=[
                    ("center", "Center"),
                    ("left", "Left"),
                    ("right", "Right"),
                ],
                default="center",
                max_length=16,
            ),
        ),
        migrations.RunPython(clamp_logo_opacity, migrations.RunPython.noop),
    ]
