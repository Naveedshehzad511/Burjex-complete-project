from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


def forwards_min_referrals(apps, schema_editor):
    IBLevel = apps.get_model("ib", "IBLevel")
    for row in IBLevel.objects.all():
        if getattr(row, "min_referrals", 0) == 0 and row.target_active_clients:
            row.min_referrals = row.target_active_clients
            row.save(update_fields=["min_referrals"])


class Migration(migrations.Migration):

    dependencies = [
        ("ib", "0006_kyc_email_symbols_ib_matrix"),
        ("admin_panel", "0043_integrations_expansion"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("accounts", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="ibcommissionsettings",
            name="use_matrix_commission_first",
            field=models.BooleanField(
                default=True,
                help_text="If True, resolve IB payout via IBCommissionMatrixRule (symbol > group > level %). "
                "If False, use legacy IBPairCommission / IBGroupCommission chain first.",
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="cap_daily",
            field=models.DecimalField(decimal_places=2, default=0, help_text="0 = no cap", max_digits=20),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="cap_monthly",
            field=models.DecimalField(decimal_places=2, default=0, help_text="0 = no cap", max_digits=20),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="cap_per_trade",
            field=models.DecimalField(decimal_places=2, default=0, help_text="0 = no cap", max_digits=20),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="cap_weekly",
            field=models.DecimalField(decimal_places=2, default=0, help_text="0 = no cap", max_digits=20),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="downgrade_grace_days",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="downgrade_review_days",
            field=models.PositiveIntegerField(default=0, help_text="0 = auto-downgrade disabled"),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="downgrade_to_level",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="downgrade_sources",
                to="ib.iblevel",
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="level_type",
            field=models.CharField(
                choices=[("DIRECT", "Direct Level"), ("PROGRESSION", "Progression Level")],
                default="PROGRESSION",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="metric_window",
            field=models.CharField(
                choices=[
                    ("ALL_TIME", "All Time"),
                    ("DAILY", "Daily"),
                    ("WEEKLY", "Weekly"),
                    ("MONTHLY", "Monthly"),
                ],
                default="ALL_TIME",
                help_text="Which rolling window to use when comparing volume/deposit/referrals for this level.",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="min_holding_period_seconds",
            field=models.PositiveIntegerField(
                default=0,
                help_text="Minimum position hold time for commission (0 = disabled). Requires hold_seconds on trade event.",
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="min_referrals",
            field=models.PositiveIntegerField(
                default=0,
                help_text="Minimum referrals for this tier (0 = ignore). Synced from target_active_clients if unset.",
            ),
        ),
        migrations.AddField(
            model_name="iblevel",
            name="primary_progress_metric",
            field=models.CharField(
                choices=[("VOLUME", "Volume"), ("DEPOSIT", "Deposit"), ("REFERRALS", "Referrals")],
                default="VOLUME",
                max_length=20,
            ),
        ),
        migrations.CreateModel(
            name="IBLevelReward",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("reward_kind", models.CharField(
                    choices=[
                        ("CASH", "Cash Reward"),
                        ("TRIP", "Trip Reward"),
                        ("MOBILE", "Mobile Reward"),
                        ("CAR", "Car Reward"),
                        ("BONUS", "Bonus Reward"),
                    ],
                    max_length=20,
                )),
                ("title", models.CharField(max_length=200)),
                ("value_text", models.CharField(blank=True, default="", max_length=500)),
                ("sort_order", models.PositiveIntegerField(default=0)),
                ("ib_level", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="rewards", to="ib.iblevel")),
            ],
            options={"ordering": ["ib_level_id", "sort_order", "id"]},
        ),
        migrations.CreateModel(
            name="IBLevelAccountTypeDefault",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("account_type", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="ib_level_defaults", to="admin_panel.tradingaccounttype")),
                ("demo_mt5_group", models.ForeignKey(
                    blank=True,
                    null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="ib_level_demo_defaults",
                    to="accounts.mt5group",
                )),
                ("ib_level", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="account_type_defaults", to="ib.iblevel")),
                ("live_mt5_group", models.ForeignKey(
                    blank=True,
                    null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="ib_level_live_defaults",
                    to="accounts.mt5group",
                )),
            ],
            options={"unique_together": {("ib_level", "account_type")}},
        ),
        migrations.CreateModel(
            name="IBProgressMetrics",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("all_time_volume", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("all_time_lots", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("all_time_team_deposit", models.DecimalField(decimal_places=2, default=0, max_digits=22)),
                ("referral_count", models.PositiveIntegerField(default=0)),
                ("daily_volume", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("daily_lots", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("daily_team_deposit", models.DecimalField(decimal_places=2, default=0, max_digits=22)),
                ("daily_referrals", models.PositiveIntegerField(default=0)),
                ("daily_period", models.DateField(blank=True, null=True)),
                ("weekly_volume", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("weekly_lots", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("weekly_team_deposit", models.DecimalField(decimal_places=2, default=0, max_digits=22)),
                ("weekly_referrals", models.PositiveIntegerField(default=0)),
                ("week_start", models.DateField(blank=True, null=True)),
                ("monthly_volume", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("monthly_lots", models.DecimalField(decimal_places=4, default=0, max_digits=22)),
                ("monthly_team_deposit", models.DecimalField(decimal_places=2, default=0, max_digits=22)),
                ("monthly_referrals", models.PositiveIntegerField(default=0)),
                ("month_start", models.DateField(blank=True, null=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("ib_user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="ib_progress_metrics", to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name="IBLevelUpgradeRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("status", models.CharField(
                    choices=[("PENDING", "Pending"), ("APPROVED", "Approved"), ("REJECTED", "Rejected")],
                    default="PENDING",
                    max_length=15,
                )),
                ("notes", models.TextField(blank=True, default="")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("processed_at", models.DateTimeField(blank=True, null=True)),
                ("from_level", models.ForeignKey(
                    blank=True,
                    null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="upgrade_requests_from",
                    to="ib.iblevel",
                )),
                ("ib_user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="ib_level_upgrade_requests",
                    to=settings.AUTH_USER_MODEL,
                )),
                ("processed_by", models.ForeignKey(
                    blank=True,
                    null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="ib_level_upgrades_processed",
                    to=settings.AUTH_USER_MODEL,
                )),
                ("to_level", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="upgrade_requests_to",
                    to="ib.iblevel",
                )),
            ],
            options={"ordering": ["-created_at", "-id"]},
        ),
        migrations.RunPython(forwards_min_referrals, migrations.RunPython.noop),
    ]
