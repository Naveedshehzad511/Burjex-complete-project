"""
Remove account types from the database.

  python manage.py clear_account_types              # only rows with is_default=True
  python manage.py clear_account_types --all        # every TradingAccountType (destructive)
"""

from django.core.management.base import BaseCommand
from django.db import transaction

from admin_panel.models import TradingAccountType


class Command(BaseCommand):
    help = "Delete seeded default account types (is_default=True), or all types with --all."

    def add_arguments(self, parser):
        parser.add_argument(
            "--all",
            action="store_true",
            help="Delete every trading account type (also removes dependent rows per CASCADE).",
        )

    @transaction.atomic
    def handle(self, *args, **options):
        if options["all"]:
            total, breakdown = TradingAccountType.objects.all().delete()
            self.stdout.write(self.style.WARNING(f"Deleted {total} object(s). Breakdown: {breakdown}"))
            return
        total, breakdown = TradingAccountType.objects.filter(is_default=True).delete()
        self.stdout.write(self.style.SUCCESS(f"Deleted {total} object(s). Breakdown: {breakdown}"))
