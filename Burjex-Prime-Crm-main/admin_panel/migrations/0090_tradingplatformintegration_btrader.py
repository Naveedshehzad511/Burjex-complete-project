from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0089_tradingaccounttype_account_category_and_more"),
    ]

    operations = [
        migrations.AlterField(
            model_name="tradingplatformintegration",
            name="platform",
            field=models.CharField(
                choices=[
                    ("MT4", "MetaTrader 4"),
                    ("MT5", "MetaTrader 5"),
                    ("CTRADER", "cTrader"),
                    ("MATCH_TRADER", "Match Trader"),
                    ("TRADELOCKER", "TradeLocker"),
                    ("VERTEX_TRADER", "Vertex Trader"),
                    ("X9_TRADER", "X9 Trader"),
                    ("BTRADER", "BTrader"),
                ],
                db_index=True,
                max_length=32,
                unique=True,
            ),
        ),
    ]
