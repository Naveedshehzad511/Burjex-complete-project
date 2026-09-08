from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from django.conf import settings
from django.db import connections
from django.db.utils import OperationalError


PROTECTED_DATASETS: tuple[tuple[str, str], ...] = (
    ("clients", "accounts.User"),
    ("ibs", "ib.IBProfile"),
    ("transactions", "transactions.Transaction"),
    ("wallets", "transactions.Wallet"),
    ("emails", "accounts.EmailVerificationCode"),
    ("verification", "accounts.KycVerification"),
)


@dataclass
class BackupResult:
    ok: bool
    backup_type: str
    stamp: str
    backup_dir: str
    database_file: str = ""
    manifest_file: str = ""
    error: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "backup_type": self.backup_type,
            "stamp": self.stamp,
            "backup_dir": self.backup_dir,
            "database_file": self.database_file,
            "manifest_file": self.manifest_file,
            "error": self.error,
        }


def backups_root() -> Path:
    raw = (os.environ.get("CRM_BACKUP_DIR") or "").strip()
    if raw:
        p = Path(raw)
    else:
        p = Path(settings.BASE_DIR) / "storage" / "backups"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _dataset_counts() -> dict[str, int]:
    from django.apps import apps

    out: dict[str, int] = {}
    for label, model_path in PROTECTED_DATASETS:
        try:
            model = apps.get_model(model_path)
            out[label] = int(model.objects.count())
        except Exception:
            out[label] = -1
    return out


def _backup_postgres(backup_file: Path, db: dict[str, Any]) -> str:
    host = str(db.get("HOST") or "").strip()
    port = str(db.get("PORT") or "").strip()
    name = str(db.get("NAME") or "").strip()
    user = str(db.get("USER") or "").strip()
    password = str(db.get("PASSWORD") or "").strip()
    cmd = [
        os.environ.get("PG_DUMP_PATH", "pg_dump"),
        "--format=custom",
        "--no-owner",
        "--no-privileges",
        f"--file={str(backup_file)}",
    ]
    if host:
        cmd.append(f"--host={host}")
    if port:
        cmd.append(f"--port={port}")
    if user:
        cmd.append(f"--username={user}")
    cmd.append(name)
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = password
    subprocess.run(cmd, env=env, check=True, capture_output=True, text=True)
    return str(backup_file)


def create_database_backup(*, backup_type: str) -> BackupResult:
    b_type = (backup_type or "manual").strip().lower()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    root = backups_root()
    target_dir = root / b_type / stamp
    target_dir.mkdir(parents=True, exist_ok=True)
    db = settings.DATABASES.get("default", {})
    engine = str(db.get("ENGINE") or "").lower()

    try:
        database_file = ""
        if "sqlite" in engine:
            src = Path(str(db.get("NAME") or "")).resolve()
            if not src.exists():
                return BackupResult(
                    ok=False,
                    backup_type=b_type,
                    stamp=stamp,
                    backup_dir=str(target_dir),
                    error=f"SQLite database not found: {src}",
                )
            dst = target_dir / f"database_{stamp}.sqlite3"
            shutil.copy2(src, dst)
            database_file = str(dst)
        elif "postgresql" in engine:
            database_file = _backup_postgres(target_dir / f"database_{stamp}.dump", db)
        else:
            return BackupResult(
                ok=False,
                backup_type=b_type,
                stamp=stamp,
                backup_dir=str(target_dir),
                error=f"Unsupported database engine for automated backup: {engine}",
            )

        manifest = {
            "backup_type": b_type,
            "created_at_utc": stamp,
            "database_engine": engine,
            "database_file": database_file,
            "protected_data_counts": _dataset_counts(),
            "service_name": getattr(settings, "SERVICE_NAME", "crm"),
        }
        manifest_file = target_dir / "manifest.json"
        manifest_file.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        _cleanup_old_backups(root / b_type, keep=max(1, int(os.environ.get("CRM_BACKUP_KEEP", "30") or "30")))
        return BackupResult(
            ok=True,
            backup_type=b_type,
            stamp=stamp,
            backup_dir=str(target_dir),
            database_file=database_file,
            manifest_file=str(manifest_file),
        )
    except (OperationalError, subprocess.SubprocessError, OSError) as exc:
        return BackupResult(
            ok=False,
            backup_type=b_type,
            stamp=stamp,
            backup_dir=str(target_dir),
            error=str(exc)[:2000],
        )


def _cleanup_old_backups(folder: Path, *, keep: int) -> None:
    if not folder.exists():
        return
    entries = sorted([p for p in folder.iterdir() if p.is_dir()], key=lambda p: p.name, reverse=True)
    for old in entries[keep:]:
        shutil.rmtree(old, ignore_errors=True)


def ensure_backup_before_update() -> BackupResult:
    return create_database_backup(backup_type="pre_update")


def restore_sqlite_backup(backup_file: str) -> dict[str, Any]:
    db = settings.DATABASES.get("default", {})
    engine = str(db.get("ENGINE") or "").lower()
    if "sqlite" not in engine:
        return {
            "ok": False,
            "error": "Automatic restore currently supports sqlite only.",
        }
    source = Path((backup_file or "").strip()).resolve()
    if not source.exists() or not source.is_file():
        return {"ok": False, "error": f"Backup file not found: {source}"}
    target = Path(str(db.get("NAME") or "")).resolve()
    if not target.parent.exists():
        return {"ok": False, "error": f"Database parent directory missing: {target.parent}"}

    pre = create_database_backup(backup_type="pre_restore")
    if not pre.ok:
        return {"ok": False, "error": f"Could not create safety backup before restore: {pre.error}"}
    try:
        connections["default"].close()
        shutil.copy2(source, target)
        return {"ok": True, "restored_to": str(target), "safety_backup": pre.as_dict()}
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
