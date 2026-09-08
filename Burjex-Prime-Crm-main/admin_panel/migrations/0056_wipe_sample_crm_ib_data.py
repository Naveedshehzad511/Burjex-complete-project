# Removes legacy seeded/sample CRM and IB data so the system starts clean (admin-created only).

from django.db import migrations


def wipe_sample_crm_and_ib(apps, schema_editor):
    IBCommissionMatrixRule = apps.get_model("ib", "IBCommissionMatrixRule")
    IBCommissionMatrixRule.objects.all().delete()

    IBLevelAccountTypeDefault = apps.get_model("ib", "IBLevelAccountTypeDefault")
    IBLevelAccountTypeDefault.objects.all().delete()

    IBCommissionRule = apps.get_model("ib", "IBCommissionRule")
    IBCommissionRule.objects.all().delete()

    CommissionGroup = apps.get_model("ib", "CommissionGroup")
    CommissionGroup.objects.all().delete()

    TradingSymbol = apps.get_model("admin_panel", "TradingSymbol")
    TradingSymbol.objects.all().delete()

    SymbolGroup = apps.get_model("admin_panel", "SymbolGroup")
    SymbolGroup.objects.all().delete()

    IBLevelReward = apps.get_model("ib", "IBLevelReward")
    IBLevelReward.objects.all().delete()

    IBLevelUpgradeRequest = apps.get_model("ib", "IBLevelUpgradeRequest")
    IBLevelUpgradeRequest.objects.all().delete()

    IBLevel = apps.get_model("ib", "IBLevel")
    IBLevel.objects.all().delete()

    BonusTemplate = apps.get_model("admin_panel", "BonusTemplate")
    for tpl in BonusTemplate.objects.all():
        tpl.account_types.clear()

    SimulatedIBTrade = apps.get_model("admin_panel", "SimulatedIBTrade")
    SimulatedIBTrade.objects.all().update(account_type_id=None)

    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    TradingAccountType.objects.all().delete()

    DemoAccountSettings = apps.get_model("admin_panel", "DemoAccountSettings")
    for row in DemoAccountSettings.objects.all():
        row.default_account_type_id = None
        row.default_group_id = None
        row.save(update_fields=["default_account_type_id", "default_group_id"])


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0055_match_trader_broker_group_and_mapping"),
        ("ib", "0007_ib_levels_extended"),
    ]

    operations = [
        migrations.RunPython(wipe_sample_crm_and_ib, noop_reverse),
    ]
