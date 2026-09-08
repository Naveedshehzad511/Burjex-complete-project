from django.db import migrations, models


def copy_legacy_platform_settings(apps, schema_editor):
    TradingPlatform = apps.get_model("admin_panel", "TradingPlatform")
    LegacySettings = apps.get_model("admin_panel", "TradingPlatformSettings")

    if TradingPlatform.objects.exists():
        return

    legacy = LegacySettings.objects.first()
    if not legacy:
        return

    has_any_data = any(
        [
            (legacy.platform_name or "").strip(),
            (legacy.tagline or "").strip(),
            (legacy.web_terminal_link or "").strip(),
            (legacy.ios_download_link or "").strip(),
            (legacy.android_download_link or "").strip(),
            (legacy.windows_download_link or "").strip(),
            (legacy.macos_download_link or "").strip(),
            bool(legacy.platform_icon),
        ]
    )
    if not has_any_data:
        return

    TradingPlatform.objects.create(
        name=(legacy.platform_name or "").strip() or "Trading Platform",
        tagline=(legacy.tagline or "").strip(),
        icon=legacy.platform_icon,
        web_terminal_link=(legacy.web_terminal_link or "").strip(),
        ios_link=(legacy.ios_download_link or "").strip(),
        android_link=(legacy.android_download_link or "").strip(),
        windows_link=(legacy.windows_download_link or "").strip(),
        mac_link=(legacy.macos_download_link or "").strip(),
        is_active=True,
    )


class Migration(migrations.Migration):
    dependencies = [
        ("admin_panel", "0037_account_type_wizard_fields"),
    ]

    operations = [
        migrations.CreateModel(
            name="TradingPlatform",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=140)),
                ("tagline", models.CharField(blank=True, default="", max_length=255)),
                ("icon", models.FileField(blank=True, null=True, upload_to="platforms/")),
                ("web_terminal_link", models.URLField(blank=True, default="")),
                ("ios_link", models.URLField(blank=True, default="")),
                ("android_link", models.URLField(blank=True, default="")),
                ("windows_link", models.URLField(blank=True, default="")),
                ("mac_link", models.URLField(blank=True, default="")),
                ("is_active", models.BooleanField(db_index=True, default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "ordering": ["-is_active", "name", "-updated_at"],
            },
        ),
        migrations.RunPython(copy_legacy_platform_settings, migrations.RunPython.noop),
    ]
