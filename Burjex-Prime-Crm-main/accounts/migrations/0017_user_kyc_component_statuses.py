from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0016_alter_mt5group_commission_per_lot"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="kyc_address_status",
            field=models.CharField(
                choices=[("pending", "Pending"), ("approved", "Approved"), ("rejected", "Rejected")],
                default="pending",
                max_length=10,
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="kyc_final_status",
            field=models.CharField(
                choices=[("pending", "Pending"), ("approved", "Approved"), ("rejected", "Rejected")],
                default="pending",
                max_length=10,
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="kyc_identity_back_status",
            field=models.CharField(
                choices=[("pending", "Pending"), ("approved", "Approved"), ("rejected", "Rejected")],
                default="pending",
                max_length=10,
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="kyc_identity_front_status",
            field=models.CharField(
                choices=[("pending", "Pending"), ("approved", "Approved"), ("rejected", "Rejected")],
                default="pending",
                max_length=10,
            ),
        ),
    ]
