from django.core.management.base import BaseCommand

from ib.models import CommissionGroup, IBPlan


class Command(BaseCommand):
    help = "Seed default IB plan/commission groups (if none exist)."

    def handle(self, *args, **options):
        if not IBPlan.objects.exists():
            IBPlan.objects.create(name="Standard Plan", description="Default IB plan", commission_rate=0, is_active=True)
        if not CommissionGroup.objects.exists():
            CommissionGroup.objects.create(name="Default Group", description="Default commission group")

        self.stdout.write(self.style.SUCCESS("Seeded IB defaults (if needed)."))

