"""Shared helpers (import-safe; used by middleware and other apps)."""

from django.http import HttpRequest

from .audit import get_client_ip  # re-export

__all__ = ["get_client_ip", "login_paths_match"]


def login_paths_match(path: str) -> bool:
    p = (path or "").rstrip("/") or "/"
    return p in {"/admin/login", "/user/login", "/login"}
