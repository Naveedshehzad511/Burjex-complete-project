# Move Match-Trader mapping from TradingAccountType → MT5Group (Group Management).

from django.db import migrations


def copy_match_trader_mapping_to_mt5group(apps, schema_editor):
    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    MT5Group = apps.get_model("accounts", "MT5Group")
    for at in TradingAccountType.objects.exclude(match_trader_group_id__isnull=True).iterator():
        if at.crm_group_id:
            MT5Group.objects.filter(pk=at.crm_group_id).update(
                match_trader_broker_group_id=at.match_trader_group_id
            )


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0025_mt5group_match_trader_broker_group"),
        ("admin_panel", "0059_match_trader_broker_group_category_crm"),
    ]

    operations = [
        migrations.RunPython(copy_match_trader_mapping_to_mt5group, migrations.RunPython.noop),
        migrations.RemoveField(
            model_name="tradingaccounttype",
            name="match_trader_group",
        ),
    ]
