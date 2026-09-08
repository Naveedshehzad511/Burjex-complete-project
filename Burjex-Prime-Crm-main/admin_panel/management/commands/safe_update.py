from __future__ import annotations

from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError

from enterprise.services.data_protection import ensure_backup_before_update


class Command(BaseCommand):
    help = "Run pre-update backup, then migrate safely (no forced downtime switch)."

    def add_arguments(self, parser):
        parser.add_argument("--skip-migrate", action="store_true", help="Only take pre-update backup.")
        parser.add_argument(
            "--collectstatic",
            action="store_true",
            help="Run collectstatic --noinput after migrations.",
        )

    def handle(self, *args, **options):
        backup = ensure_backup_before_update()
        if not backup.ok:
            raise CommandError(f"Pre-update backup failed: {backup.error}")
        self.stdout.write(self.style.SUCCESS(f"Pre-update backup created: {backup.backup_dir}"))

        if options.get("skip_migrate"):
            self.stdout.write(self.style.WARNING("Migrations skipped by flag."))
            return

        call_command("migrate", interactive=False)
        self.stdout.write(self.style.SUCCESS("Database migrations completed."))
        if options.get("collectstatic"):
            call_command("collectstatic", interactive=False, verbosity=0)
            self.stdout.write(self.style.SUCCESS("Collectstatic completed."))
