from __future__ import annotations

import shutil
from datetime import datetime
from pathlib import Path

from django.conf import settings
from django.core.exceptions import PermissionDenied
from django.db import transaction
from django.utils import timezone

from admin_panel.models import ModuleChangeLog, ModuleVersion, StabilityProfile, SystemModule

PROTECTED_PATHS: tuple[str, ...] = (
    "templates",
    "config/settings.py",
    "templates/admin_panel",
    "templates/admin_panel/integrations",
)


def current_mode() -> str:
    env_mode = (getattr(settings, "CRM_STABILITY_MODE", "") or "").strip().lower()
    if env_mode in {StabilityProfile.Mode.DEVELOPMENT, StabilityProfile.Mode.STABLE}:
        return env_mode
    return StabilityProfile.get_solo().mode


def ensure_module(module_name: str) -> SystemModule:
    name = (module_name or "").strip().lower()
    if not name:
        name = "core"
    module, _ = SystemModule.objects.get_or_create(module_name=name)
    return module


def assert_module_writable(module_name: str) -> SystemModule:
    module = ensure_module(module_name)
    mode = current_mode()
    if mode == StabilityProfile.Mode.STABLE and module.stability == SystemModule.Stability.STABLE and module.is_locked:
        raise PermissionDenied(f"Module '{module.module_name}' is frozen and cannot be modified in stable mode.")
    return module


def _copy_path(src: Path, dest_root: Path) -> None:
    if not src.exists():
        return
    if src.is_file():
        target = dest_root / src.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
        return
    target_dir = dest_root / src.name
    shutil.copytree(src, target_dir, dirs_exist_ok=True)


def create_backup_snapshot(module_name: str, changed_by=None) -> str:
    base_dir = Path(settings.BASE_DIR)
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    safe_module = (module_name or "core").strip().lower().replace(" ", "_")
    backup_root = base_dir / "templates_backup" / "module_backups" / safe_module / ts
    backup_root.mkdir(parents=True, exist_ok=True)
    for rel in PROTECTED_PATHS:
        _copy_path(base_dir / rel, backup_root)

    module = ensure_module(module_name)
    version = ModuleVersion.objects.filter(module=module).count() + 1
    ModuleVersion.objects.create(
        module=module,
        module_version=f"v{version}",
        backup_path=str(backup_root),
        created_by=changed_by if getattr(changed_by, "is_authenticated", False) else None,
        change_summary="Automatic pre-change backup snapshot.",
    )
    return str(backup_root)


def log_module_change(
    *,
    module_name: str,
    changed_by=None,
    change_type: str = "update",
    change_summary: str = "",
    changed_paths: list[str] | None = None,
    metadata: dict | None = None,
) -> None:
    module = ensure_module(module_name)
    ModuleChangeLog.objects.create(
        module=module,
        changed_by=changed_by if getattr(changed_by, "is_authenticated", False) else None,
        change_type=(change_type or "update")[:60],
        change_summary=change_summary[:4000],
        changed_paths=changed_paths or [],
        metadata=metadata or {},
    )


@transaction.atomic
def freeze_module(module_name: str, user=None) -> SystemModule:
    module = ensure_module(module_name)
    module.stability = SystemModule.Stability.STABLE
    module.is_locked = True
    module.locked_at = timezone.now()
    module.locked_by = user if getattr(user, "is_authenticated", False) else None
    module.save(update_fields=["stability", "is_locked", "locked_at", "locked_by", "updated_at"])
    return module


@transaction.atomic
def unfreeze_module(module_name: str, user=None) -> SystemModule:
    module = ensure_module(module_name)
    module.is_locked = False
    module.locked_at = None
    module.locked_by = None
    module.save(update_fields=["is_locked", "locked_at", "locked_by", "updated_at"])
    return module


def restore_module_version(version_id: int, user=None) -> str:
    version = ModuleVersion.objects.select_related("module").filter(pk=version_id).first()
    if not version or not version.backup_path:
        raise FileNotFoundError("Module version backup not found.")
    source = Path(version.backup_path)
    if not source.exists():
        raise FileNotFoundError("Backup path does not exist.")
    base_dir = Path(settings.BASE_DIR)
    for item in source.iterdir():
        target = base_dir / item.name
        if item.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)
        else:
            shutil.copytree(item, target, dirs_exist_ok=True)
    log_module_change(
        module_name=version.module.module_name,
        changed_by=user,
        change_type="restore",
        change_summary=f"Restored module from {version.module_version}",
        changed_paths=[str(source)],
        metadata={"version_id": version.pk},
    )
    return str(source)
