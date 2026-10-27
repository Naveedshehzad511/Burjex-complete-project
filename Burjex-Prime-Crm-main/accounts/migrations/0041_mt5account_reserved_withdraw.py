from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0040_pushdevice_pushdelivery"),
    ]

    operations = [
        migrations.AddField(
            model_name="mt5account",
            name="reserved_withdraw",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=20),
        ),
    ]
