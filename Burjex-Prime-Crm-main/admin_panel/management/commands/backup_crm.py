"""Run production backup snapshots into /storage/backups."""

from django.core.management.base import BaseCommand

from enterprise.services.data_protection import create_database_backup


class Command(BaseCommand):
    help = "Create data-protection backup snapshot (daily|weekly|pre_update|manual)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--type",
            default="manual",
            choices=["manual", "daily", "weekly", "pre_update", "pre_restore"],
            help="Backup type namespace under /storage/backups.",
        )

    def handle(self, *args, **options):
        backup_type = (options.get("type") or "manual").strip().lower()
        result = create_database_backup(backup_type=backup_type).as_dict()
        self.stdout.write(str(result))
