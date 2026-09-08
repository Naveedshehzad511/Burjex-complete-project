from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0036_alter_mt5account_group"),
    ]

    operations = [
        migrations.AlterField(
            model_name="mt5group",
            name="platform",
            field=models.CharField(
                choices=[
                    ("MT5", "MT5"),
                    ("MATCH_TRADER", "Match-Trader"),
                    ("X9_TRADER", "X9 Trader"),
                    ("BTRADER", "BTrader"),
                ],
                db_index=True,
                default="MT5",
                help_text="Trading platform this row maps to.",
                max_length=32,
            ),
        ),
    ]
