from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0093_onboarding_slide"),
    ]

    operations = [
        migrations.AddField(
            model_name="wallettreasurysettings",
            name="allow_direct_trading_withdraw",
            field=models.BooleanField(
                default=False,
                help_text="Let clients withdraw directly from an eligible live trading account (otherwise wallet only).",
            ),
        ),
    ]
