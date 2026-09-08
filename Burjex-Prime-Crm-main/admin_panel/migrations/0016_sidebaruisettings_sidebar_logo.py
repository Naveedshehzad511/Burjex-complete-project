# Generated manually

from pathlib import Path

from django.conf import settings
from django.core.files.storage import FileSystemStorage
from django.db import migrations, models

_logo_dir = Path(settings.BASE_DIR) / "static" / "uploads" / "logo"
_logo_storage = FileSystemStorage(location=str(_logo_dir), base_url="static/uploads/logo")


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0015_trading_platform_url_charfield"),
    ]

    operations = [
        migrations.AddField(
            model_name="sidebaruisettings",
            name="sidebar_logo",
            field=models.ImageField(
                blank=True,
                null=True,
                storage=_logo_storage,
                upload_to="sidebar",
            ),
        ),
    ]
