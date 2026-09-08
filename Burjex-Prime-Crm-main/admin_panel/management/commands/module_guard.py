from __future__ import annotations

from django.core.management.base import BaseCommand, CommandError

from admin_panel.models import StabilityProfile
from admin_panel.services.module_protection import freeze_module, restore_module_version, unfreeze_module


class Command(BaseCommand):
    help = "Freeze/unfreeze modules, switch stability mode, and restore module backups."

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["freeze", "unfreeze", "mode", "restore"])
        parser.add_argument("--module", default="", help="Module name (for freeze/unfreeze).")
        parser.add_argument("--mode", default="", choices=["development", "stable"], help="Global stability mode.")
        parser.add_argument("--version-id", type=int, default=0, help="ModuleVersion id to restore.")

    def handle(self, *args, **opts):
        action = opts["action"]
        if action in {"freeze", "unfreeze"}:
            mod = (opts.get("module") or "").strip().lower()
            if not mod:
                raise CommandError("--module is required for freeze/unfreeze")
            obj = freeze_module(mod) if action == "freeze" else unfreeze_module(mod)
            self.stdout.write(self.style.SUCCESS(f"{action} OK: {obj.module_name} locked={obj.is_locked}"))
            return

        if action == "mode":
            mode = (opts.get("mode") or "").strip().lower()
            if not mode:
                raise CommandError("--mode is required for action=mode")
            prof = StabilityProfile.get_solo()
            prof.mode = mode
            prof.save(update_fields=["mode", "updated_at"])
            self.stdout.write(self.style.SUCCESS(f"Global stability mode set to: {mode}"))
            return

        if action == "restore":
            version_id = int(opts.get("version_id") or 0)
            if version_id <= 0:
                raise CommandError("--version-id is required for action=restore")
            path = restore_module_version(version_id)
            self.stdout.write(self.style.SUCCESS(f"Restore completed from backup: {path}"))
