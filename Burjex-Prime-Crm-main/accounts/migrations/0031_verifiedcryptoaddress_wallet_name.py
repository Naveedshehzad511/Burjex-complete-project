from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0030_crm_roles_and_permissions"),
    ]

    operations = [
        migrations.AddField(
            model_name="verifiedcryptoaddress",
            name="wallet_name",
            field=models.CharField(
                blank=True,
                default="",
                help_text="Optional label shown to the user (e.g. Main wallet).",
                max_length=120,
            ),
        ),
    ]
