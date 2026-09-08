"""Validation for branding file uploads (max 2MB)."""

from __future__ import annotations

MAX_BRANDING_BYTES = 2 * 1024 * 1024

ALLOWED_EXTENSIONS = frozenset({"png", "jpg", "jpeg", "svg", "webp"})
LOGIN_ALLOWED_EXTENSIONS = frozenset({"png", "jpg", "jpeg", "svg", "webp"})

MSG_INVALID_FORMAT = "Invalid file format. Please upload PNG, JPG, JPEG or SVG"
MSG_FILE_TOO_LARGE = "File size must be less than 2MB"
MSG_UPLOAD_FAILED = "Upload failed. Please try again"
MSG_UPLOAD_OK = "Logo uploaded successfully"

MSG_LOGIN_INVALID_FORMAT = "Invalid file format. Allowed: PNG, JPG, SVG, WEBP"
MSG_LOGIN_FILE_TOO_LARGE = "File must be under 2MB"
MSG_BRANDING_UPDATED = "Branding Updated Successfully"


def branding_file_error(uploaded) -> str | None:
    """
    Return an error message if invalid, else None.
    `uploaded` is an UploadedFile or None.
    """
    if not uploaded or not getattr(uploaded, "name", None):
        return None
    name = (uploaded.name or "").strip()
    if not name or "." not in name:
        return MSG_INVALID_FORMAT
    ext = name.rsplit(".", 1)[-1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        return MSG_INVALID_FORMAT
    size = int(getattr(uploaded, "size", 0) or 0)
    if size > MAX_BRANDING_BYTES:
        return MSG_FILE_TOO_LARGE
    return None


def login_branding_file_error(uploaded) -> str | None:
    """Validation for login page uploads (includes WEBP)."""
    if not uploaded or not getattr(uploaded, "name", None):
        return None
    name = (uploaded.name or "").strip()
    if not name or "." not in name:
        return MSG_LOGIN_INVALID_FORMAT
    ext = name.rsplit(".", 1)[-1].lower()
    if ext not in LOGIN_ALLOWED_EXTENSIONS:
        return MSG_LOGIN_INVALID_FORMAT
    size = int(getattr(uploaded, "size", 0) or 0)
    if size > MAX_BRANDING_BYTES:
        return MSG_LOGIN_FILE_TOO_LARGE
    return None
