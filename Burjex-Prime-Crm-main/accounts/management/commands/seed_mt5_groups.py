from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Deprecated: MT5/CRM broker groups are no longer auto-seeded. Add groups in Admin → Group Management."

    def handle(self, *args, **options):
        self.stdout.write(
            self.style.WARNING(
                "seed_mt5_groups is disabled. Create broker groups under Admin → CRM → Group Management."
            )
        )
