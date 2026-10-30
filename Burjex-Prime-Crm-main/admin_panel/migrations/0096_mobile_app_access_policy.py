import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("admin_panel", "0095_signup_no_address_no_captcha"),
    ]

    operations = [
        migrations.CreateModel(
            name="MobileAppAccessPolicy",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("ios_enabled", models.BooleanField(default=True)),
                ("allowed_countries", models.CharField(blank=True, default="PK", max_length=500)),
                ("require_ip_country", models.BooleanField(default=True)),
                ("allow_unknown_ip_country", models.BooleanField(default=False)),
                ("block_simulated_location", models.BooleanField(default=True)),
                ("max_accuracy_m", models.PositiveIntegerField(default=25000)),
                ("recheck_hours", models.PositiveIntegerField(default=12)),
                ("ticket_minutes", models.PositiveIntegerField(default=10)),
                ("exempt_accounts", models.TextField(blank=True, default="")),
                (
                    "blocked_message",
                    models.TextField(
                        default="Burjex Prime on iPhone and iPad is currently available only in Pakistan. "
                        "You can't sign in or register from your current location."
                    ),
                ),
                (
                    "location_required_message",
                    models.TextField(
                        default="Burjex Prime needs your location to confirm you are in a country where the service "
                        "is available. Allow location access for Burjex Prime in Settings and try again."
                    ),
                ),
                (
                    "network_mismatch_message",
                    models.TextField(
                        default="Your network location does not match your device location. "
                        "Turn off any VPN or proxy and try again."
                    ),
                ),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"verbose_name": "Mobile app access policy"},
        ),
        migrations.CreateModel(
            name="MobileGeoVerification",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("token_key", models.CharField(max_length=64, unique=True)),
                ("allowed", models.BooleanField(default=False)),
                ("reason", models.CharField(blank=True, default="", max_length=40)),
                ("gps_country", models.CharField(blank=True, default="", max_length=2)),
                ("ip_country", models.CharField(blank=True, default="", max_length=2)),
                ("verified_at", models.DateTimeField(default=django.utils.timezone.now)),
                (
                    "user",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="mobile_geo_checks",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={"verbose_name": "Mobile location check"},
        ),
    ]
