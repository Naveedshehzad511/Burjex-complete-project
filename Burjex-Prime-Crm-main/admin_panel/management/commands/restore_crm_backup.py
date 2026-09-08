from __future__ import annotations

from django.core.management.base import BaseCommand, CommandError

from enterprise.services.data_protection import restore_sqlite_backup


class Command(BaseCommand):
    help = "Restore SQLite database from backup file (creates pre-restore safety backup first)."

    def add_arguments(self, parser):
        parser.add_argument("--file", required=True, help="Absolute path to backup sqlite file.")

    def handle(self, *args, **options):
        file_path = (options.get("file") or "").strip()
        if not file_path:
            raise CommandError("--file is required")
        result = restore_sqlite_backup(file_path)
        if not result.get("ok"):
            raise CommandError(str(result.get("error") or "restore failed"))
        self.stdout.write(self.style.SUCCESS(f"Restore completed: {result.get('restored_to')}"))
        self.stdout.write(str(result))
