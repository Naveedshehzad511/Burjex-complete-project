from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0044_tradingsymbol_digits_account_suffix"),
    ]

    operations = [
        migrations.AddField(
            model_name="smsprovider",
            name="sender_email",
            field=models.EmailField(blank=True, default="", max_length=254),
        ),
    ]
