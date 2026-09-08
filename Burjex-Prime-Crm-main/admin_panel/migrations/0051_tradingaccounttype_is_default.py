# Generated manually for seeded account type deletion UX.

from django.db import migrations, models


def mark_seed_account_types(apps, schema_editor):
    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    TradingAccountType.objects.filter(account_code__in=["STANDARD", "PRO", "RAW", "VIP"]).update(is_default=True)


def noop_reverse(apps, schema_editor):
    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    TradingAccountType.objects.filter(account_code__in=["STANDARD", "PRO", "RAW", "VIP"]).update(is_default=False)


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0050_email_header_text_color_logo_validators"),
    ]

    operations = [
        migrations.AddField(
            model_name="tradingaccounttype",
            name="is_default",
            field=models.BooleanField(
                default=False,
                help_text="True for CRM-seeded templates (STANDARD/PRO/RAW/VIP). Deleting them is permanent; requests no longer recreate removed types.",
            ),
        ),
        migrations.RunPython(mark_seed_account_types, noop_reverse),
    ]
