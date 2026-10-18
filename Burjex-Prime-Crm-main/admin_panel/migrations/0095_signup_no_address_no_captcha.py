from django.db import migrations, models


def hide_address_and_captcha(apps, schema_editor):
    """The client's requirement: no Address box and no "I am not a robot" on the sign-up (app and website).
    These are admin settings; set them once here, an admin can still change them later."""
    SignupSettings = apps.get_model("admin_panel", "SignupSettings")
    SignupSettings.objects.update_or_create(pk=1, defaults={"address_mode": "HIDDEN", "captcha_enabled": False})


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0094_wallettreasurysettings_allow_direct_trading_withdraw"),
    ]

    operations = [
        migrations.AlterField(
            model_name="signupsettings",
            name="address_mode",
            field=models.CharField(
                choices=[("REQUIRED", "Required"), ("OPTIONAL", "Optional"), ("HIDDEN", "Hidden")],
                default="HIDDEN",
                max_length=10,
            ),
        ),
        migrations.AlterField(
            model_name="signupsettings",
            name="captcha_enabled",
            field=models.BooleanField(default=False),
        ),
        migrations.RunPython(hide_address_and_captcha, migrations.RunPython.noop),
    ]
