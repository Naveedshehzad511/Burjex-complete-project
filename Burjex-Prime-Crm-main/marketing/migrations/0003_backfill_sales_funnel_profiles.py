from django.conf import settings
from django.db import migrations


def forwards(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    SalesFunnelProfile = apps.get_model("marketing", "SalesFunnelProfile")
    for uid in User.objects.filter(role="CLIENT").values_list("id", flat=True).iterator(chunk_size=500):
        SalesFunnelProfile.objects.get_or_create(user_id=uid)


def backwards(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("marketing", "0002_sales_funnel_models"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.RunPython(forwards, backwards),
    ]
