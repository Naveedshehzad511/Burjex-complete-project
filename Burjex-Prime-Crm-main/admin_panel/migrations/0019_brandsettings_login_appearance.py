# Generated manually — client login panel appearance on BrandSettings.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0018_loginbrandingsettings"),
    ]

    operations = [
        migrations.AddField(
            model_name="brandsettings",
            name="login_background_logo",
            field=models.FileField(blank=True, null=True, upload_to="branding/login"),
        ),
        migrations.AddField(
            model_name="brandsettings",
            name="login_bg_color",
            field=models.CharField(default="#0f172a", max_length=32),
        ),
        migrations.AddField(
            model_name="brandsettings",
            name="login_watermark_opacity",
            field=models.FloatField(default=0.10),
        ),
    ]
