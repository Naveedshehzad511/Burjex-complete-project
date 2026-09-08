# One-time seed when the table is empty (fresh DB). Deleted types are never recreated by ensure_professional_crm_grouping.

from decimal import Decimal

from django.db import migrations


def seed_if_empty(apps, schema_editor):
    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    if TradingAccountType.objects.exists():
        return
    specs = [
        ("STANDARD", "Standard", Decimal("0"), "STANDARD", "SPREAD"),
        ("PRO", "Pro", Decimal("0"), "CUSTOM", "SPREAD"),
        ("RAW", "Raw", Decimal("7"), "RAW", "COMMISSION"),
        ("VIP", "VIP", Decimal("0"), "CUSTOM", "SPREAD"),
    ]
    for i, (code, name, commission, spread_type, pricing) in enumerate(specs):
        TradingAccountType.objects.create(
            account_name=name,
            account_code=code,
            headline=name,
            platform="MT5",
            currency="USD",
            min_deposit=Decimal("0"),
            min_spread=Decimal("0"),
            spread_value=Decimal("0"),
            max_leverage=500,
            commission=commission,
            spread_type=spread_type,
            pricing_type=pricing,
            spread="",
            display_order=i * 10,
            is_active=True,
            is_default=True,
            leverage_options=["100", "200", "300", "400", "500"],
        )


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0051_tradingaccounttype_is_default"),
    ]

    operations = [
        migrations.RunPython(seed_if_empty, migrations.RunPython.noop),
    ]
