"""
Central validation for user-uploaded documents (KYC, deposit proofs, admin uploads).

Blocks common executable / script extensions and enforces size + allow-list.
"""

from __future__ import annotations

# Extensions that must never be stored or served as user documents.
BLOCKED_EXTENSIONS = frozenset(
    {
        "exe",
        "bat",
        "cmd",
        "com",
        "pif",
        "scr",
        "msi",
        "dll",
        "sys",
        "drv",
        "vbs",
        "vbe",
        "js",
        "jse",
        "wsf",
        "wsh",
        "ps1",
        "psm1",
        "psc1",
        "sh",
        "bash",
        "zsh",
        "php",
        "phtml",
        "asp",
        "aspx",
        "ashx",
        "jsp",
        "jspx",
        "jar",
        "war",
        "hta",
        "cpl",
        "msc",
        "reg",
        "lnk",
        "iso",
        "dmg",
        "app",
        "deb",
        "rpm",
    }
)

# Typical KYC / payment-proof uploads.
KYC_ALLOWED_EXTENSIONS = frozenset({"pdf", "jpg", "jpeg", "png"})
DEFAULT_MAX_BYTES = 5 * 1024 * 1024


def _extension(filename: str) -> str:
    name = (filename or "").strip().lower()
    if not name or "." not in name:
        return ""
    return name.rsplit(".", 1)[-1]


def validate_document_upload(
    uploaded,
    *,
    required: bool = True,
    allowed_extensions: frozenset[str] | None = None,
    max_bytes: int = DEFAULT_MAX_BYTES,
) -> str | None:
    """
    Return an error message if invalid, else None.

    `uploaded` is a Django UploadedFile-like object or None.
    """
    if not uploaded or not getattr(uploaded, "name", None):
        if required:
            return "Document file is required."
        return None

    name = (uploaded.name or "").strip()
    ext = _extension(name)
    if not ext:
        return "Invalid file name."
    if ext in BLOCKED_EXTENSIONS:
        return "This file type is not allowed for security reasons."
    allow = allowed_extensions or KYC_ALLOWED_EXTENSIONS
    if ext not in allow:
        return "Only PDF, JPG, and PNG files are allowed."

    # Reject names like "file.pdf.exe" (last segment is blocked).
    lower = name.lower()
    for part in lower.split("."):
        if part in BLOCKED_EXTENSIONS:
            return "This file type is not allowed for security reasons."

    size = int(getattr(uploaded, "size", 0) or 0)
    if size <= 0:
        return "Empty file is not allowed."
    if size > max_bytes:
        mb = max_bytes // (1024 * 1024)
        return f"Maximum file size is {mb}MB."

    return _optional_image_sanity_check(uploaded, ext)


def _optional_image_sanity_check(uploaded, ext: str) -> str | None:
    """Verify image magic bytes when Pillow is available (reduces polyglot uploads)."""
    if ext == "pdf":
        return None
    try:
        from PIL import Image  # type: ignore[import-untyped]
    except ImportError:
        return None

    try:
        if hasattr(uploaded, "seek"):
            uploaded.seek(0)
        with Image.open(uploaded) as im:
            im.verify()
    except Exception:
        return "File content does not match a valid image."
    finally:
        try:
            if hasattr(uploaded, "seek"):
                uploaded.seek(0)
        except (OSError, AttributeError, ValueError):
            pass
    return None
