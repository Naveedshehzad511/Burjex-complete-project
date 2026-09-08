# Generated manually for Match-Trader catalog sync + CRM mapping.

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0024_alter_mt5account_group_cascade"),
        ("admin_panel", "0058_match_trader_enterprise"),
    ]

    operations = [
        migrations.AlterField(
            model_name="matchtraderbrokergroup",
            name="name",
            field=models.CharField(
                help_text="Exact name on Match-Trader (e.g. standard).",
                max_length=120,
            ),
        ),
        migrations.AddField(
            model_name="matchtraderbrokergroup",
            name="sync_category",
            field=models.CharField(
                choices=[
                    ("TRADING", "Trading group"),
                    ("ACCOUNT", "Account group"),
                    ("SERVER", "Server"),
                ],
                db_index=True,
                default="TRADING",
                help_text="Source list from broker API sync (trading / account / server).",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="matchtraderbrokergroup",
            name="crm_group",
            field=models.ForeignKey(
                blank=True,
                help_text="Optional CRM (MT5) group mapping for this Match-Trader row.",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="match_trader_broker_groups",
                to="accounts.mt5group",
            ),
        ),
        migrations.AlterModelOptions(
            name="matchtraderbrokergroup",
            options={
                "ordering": ["sync_category", "name", "id"],
                "verbose_name": "Match-Trader broker group",
                "verbose_name_plural": "Match-Trader broker groups",
            },
        ),
        migrations.AddConstraint(
            model_name="matchtraderbrokergroup",
            constraint=models.UniqueConstraint(
                fields=("sync_category", "name"),
                name="uniq_match_trader_broker_cat_name",
            ),
        ),
    ]
