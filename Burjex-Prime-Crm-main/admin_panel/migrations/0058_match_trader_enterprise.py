# Generated manually for Match-Trader enterprise module.

import decimal

from django.conf import settings
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("admin_panel", "0057_match_trader_save_test_timestamps"),
    ]

    operations = [
        migrations.AddField(
            model_name="matchtradersettings",
            name="accounts_connected_count",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="environment",
            field=models.CharField(
                choices=[("LIVE", "Live"), ("SANDBOX", "Sandbox")],
                default="LIVE",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_connection_error",
            field=models.TextField(blank=True, default=""),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_grpc_ok",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_sync_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="last_test_latency_ms",
            field=models.PositiveIntegerField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="open_trades_running_count",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="pending_orders_display_count",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="sync_orders",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="matchtradersettings",
            name="sync_positions",
            field=models.BooleanField(default=False),
        ),
        migrations.AlterModelTable(
            name="matchtradersettings",
            table="match_trader_config",
        ),
        migrations.CreateModel(
            name="MatchTraderLog",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(choices=[("connection", "Connection"), ("error", "Error"), ("api", "API")], db_index=True, max_length=32)),
                ("message", models.TextField()),
                ("success", models.BooleanField(db_index=True, default=True)),
                ("detail", models.JSONField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
            ],
            options={
                "db_table": "match_trader_logs",
                "ordering": ["-created_at"],
            },
        ),
        migrations.CreateModel(
            name="MatchTraderUserSnapshot",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("balance", models.DecimalField(decimal_places=2, default=decimal.Decimal("0"), max_digits=20)),
                ("equity", models.DecimalField(decimal_places=2, default=decimal.Decimal("0"), max_digits=20)),
                ("margin", models.DecimalField(decimal_places=2, default=decimal.Decimal("0"), max_digits=20)),
                ("open_trades_count", models.PositiveIntegerField(default=0)),
                ("pending_orders_count", models.PositiveIntegerField(default=0)),
                ("open_trades_json", models.JSONField(blank=True, default=list)),
                ("pending_orders_json", models.JSONField(blank=True, default=list)),
                ("trade_history_json", models.JSONField(blank=True, default=list)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "user",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="match_trader_snapshot",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "db_table": "match_trader_user_snapshots",
            },
        ),
    ]
