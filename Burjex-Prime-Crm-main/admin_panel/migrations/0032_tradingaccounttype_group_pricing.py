import decimal

from django.db import migrations, models
import django.db.models.deletion


def forwards_link_and_pricing(apps, schema_editor):
    MT5Group = apps.get_model("accounts", "MT5Group")
    TradingAccountType = apps.get_model("admin_panel", "TradingAccountType")
    for g in MT5Group.objects.all():
        aid = getattr(g, "account_type_id", None)
        if aid:
            TradingAccountType.objects.filter(pk=aid).update(crm_group_id=g.id)
    for t in TradingAccountType.objects.all():
        comm = decimal.Decimal(t.commission or 0)
        if comm > 0:
            t.pricing_type = "COMMISSION"
        else:
            t.pricing_type = "SPREAD"
        if t.spread_value is None and (t.spread or "").strip():
            raw = (t.spread or "").strip().replace(",", ".")
            try:
                t.spread_value = decimal.Decimal(raw.split()[0])
            except Exception:
                pass
        t.save(
            update_fields=[
                "pricing_type",
                "spread_value",
            ]
        )


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0031_kyc_email_template_keys"),
        ("accounts", "0018_kyc_component_status_v2_and_id_doc_types"),
    ]

    operations = [
        migrations.AddField(
            model_name="tradingaccounttype",
            name="description",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="crm_group",
            field=models.ForeignKey(
                blank=True,
                help_text="MT5 group used when opening accounts of this type.",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="account_types",
                to="accounts.mt5group",
            ),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="display_order",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="pricing_type",
            field=models.CharField(
                choices=[("SPREAD", "Spread"), ("COMMISSION", "Commission")],
                default="SPREAD",
                help_text="Client portal shows spread or commission only, per selection.",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="tradingaccounttype",
            name="spread_value",
            field=models.DecimalField(
                blank=True,
                decimal_places=4,
                help_text="Used when pricing type is Spread (e.g. pips/points).",
                max_digits=12,
                null=True,
            ),
        ),
        migrations.AlterModelOptions(
            name="tradingaccounttype",
            options={"ordering": ["display_order", "account_name", "-created_at"]},
        ),
        migrations.AlterField(
            model_name="tradingaccounttype",
            name="commission",
            field=models.DecimalField(
                decimal_places=2,
                default=0,
                help_text="Commission per lot when pricing type is Commission.",
                max_digits=16,
            ),
        ),
        migrations.RunPython(forwards_link_and_pricing, migrations.RunPython.noop),
    ]
