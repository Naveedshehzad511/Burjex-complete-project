from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0018_kyc_component_status_v2_and_id_doc_types"),
        ("admin_panel", "0032_tradingaccounttype_group_pricing"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="mt5group",
            name="account_type",
        ),
        migrations.RemoveField(
            model_name="mt5group",
            name="commission_per_lot",
        ),
        migrations.RemoveField(
            model_name="mt5group",
            name="enable_crm_commission_testing",
        ),
    ]
