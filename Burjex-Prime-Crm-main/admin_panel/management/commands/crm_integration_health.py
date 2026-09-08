"""
Smoke checks for broker integration wiring (no live MT5 / Match-Trader calls).

Run: python manage.py crm_integration_health
"""

from django.core.management.base import BaseCommand
from django.utils import timezone

from accounts.models import MT5Account, User


class Command(BaseCommand):
    help = "Print CRM integration health summary (DB + optional connectivity probes)."

    def handle(self, *args, **options):
        self.stdout.write(self.style.NOTICE("Forex CRM - integration health"))
        self.stdout.write(f"  Time (server): {timezone.now().isoformat()}")

        ib_n = User.objects.filter(role=User.Roles.IB).count()
        self.stdout.write(f"  IB users (DB): {ib_n}")

        mt5_n = MT5Account.objects.count()
        self.stdout.write(f"  MT5Account rows (local CRM): {mt5_n}")

        try:
            from admin_panel.models import MatchTraderSettings

            mt = MatchTraderSettings.get_solo()
            self.stdout.write(
                f"  Match-Trader settings: active={mt.is_active} status={mt.connection_status} "
                f"base_url_set={bool(mt.base_url)} rest_base_url_set={bool(mt.rest_base_url)}"
            )
        except Exception as exc:
            self.stdout.write(self.style.WARNING(f"  Match-Trader settings: error {exc}"))

        try:
            from admin_panel.models import Match2PayIntegrationSettings

            m2 = Match2PayIntegrationSettings.get_solo()
            self.stdout.write(
                f"  Match2Pay: enabled={m2.enabled} url_set={bool(m2.api_url)} secret_set={bool(m2.api_secret)}"
            )
        except Exception as exc:
            self.stdout.write(self.style.WARNING(f"  Match2Pay: error {exc}"))

        try:
            import config.celery  # noqa: F401

            self.stdout.write("  Celery: app import OK")
        except Exception as exc:
            self.stdout.write(self.style.WARNING(f"  Celery: import failed {exc}"))

        self.stdout.write(
            self.style.SUCCESS(
                "Done. Note: MT5 Manager API and full Match-Trader account sync require broker-side services outside this repo."
            )
        )
