import django.utils.timezone
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("transactions", "0012_match2paytransaction"),
    ]

    operations = [
        migrations.AlterField(
            model_name="match2paytransaction",
            name="status",
            field=models.CharField(
                choices=[
                    ("PENDING", "Pending"),
                    ("COMPLETED", "Completed"),
                    ("FAILED", "Failed"),
                    ("EXPIRED", "Expired"),
                ],
                db_index=True,
                default="PENDING",
                max_length=15,
            ),
        ),
        migrations.AddField(
            model_name="match2paytransaction",
            name="updated_at",
            field=models.DateTimeField(default=django.utils.timezone.now),
        ),
        migrations.AlterField(
            model_name="match2paytransaction",
            name="updated_at",
            field=models.DateTimeField(auto_now=True),
        ),
    ]
