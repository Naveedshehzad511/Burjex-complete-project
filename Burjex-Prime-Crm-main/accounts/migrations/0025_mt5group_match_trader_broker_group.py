# MT5Group: optional Match-Trader mapping (Group Management).

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0055_match_trader_broker_group_and_mapping"),
        ("accounts", "0024_alter_mt5account_group_cascade"),
    ]

    operations = [
        migrations.AddField(
            model_name="mt5group",
            name="match_trader_broker_group",
            field=models.ForeignKey(
                blank=True,
                help_text="Match-Trader trading group for this CRM group (Group Management).",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="crm_mt5_groups",
                to="admin_panel.matchtraderbrokergroup",
            ),
        ),
    ]
