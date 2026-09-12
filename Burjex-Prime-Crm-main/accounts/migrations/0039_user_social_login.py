from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0038_accountdeletionrequest"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="apple_sub",
            field=models.CharField(blank=True, db_index=True, default="", max_length=64),
        ),
        migrations.AddField(
            model_name="user",
            name="google_sub",
            field=models.CharField(blank=True, db_index=True, default="", max_length=64),
        ),
    ]
