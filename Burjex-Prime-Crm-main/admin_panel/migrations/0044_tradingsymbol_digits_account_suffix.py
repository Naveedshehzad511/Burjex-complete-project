from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0043_integrations_expansion"),
    ]

    operations = [
        migrations.AddField(
            model_name="tradingaccounttype",
            name="mt5_symbol_suffix",
            field=models.CharField(
                blank=True,
                default="",
                help_text="Suffix appended to base symbols for this account type (e.g. .PRO, .ECN). Used for symbol matching.",
                max_length=32,
            ),
        ),
        migrations.AddField(
            model_name="tradingsymbol",
            name="contract_size",
            field=models.DecimalField(blank=True, decimal_places=4, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="tradingsymbol",
            name="digits",
            field=models.PositiveSmallIntegerField(blank=True, null=True),
        ),
        migrations.AlterField(
            model_name="tradingsymbol",
            name="symbol_type",
            field=models.CharField(
                choices=[
                    ("FOREX", "Forex"),
                    ("METAL", "Metal"),
                    ("CRYPTO", "Crypto"),
                    ("INDICES", "Indices"),
                    ("STOCKS", "Stocks"),
                ],
                default="FOREX",
                max_length=20,
            ),
        ),
    ]
