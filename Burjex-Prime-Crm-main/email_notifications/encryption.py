"""Fernet encryption helpers for SMTP credentials.

Re-uses the project's existing Fernet key derivation from SECRET_KEY
(see accounts.models._fernet_from_secret_key) so that all encrypted
fields across the CRM share the same deterministic key.
"""

from __future__ import annotations

import base64
import hashlib

from cryptography.fernet import Fernet
from django.conf import settings


def _get_fernet() -> Fernet:
    """Deterministic Fernet key derived from Django SECRET_KEY."""
    digest = hashlib.sha256(settings.SECRET_KEY.encode("utf-8")).digest()
    key = base64.urlsafe_b64encode(digest)
    return Fernet(key)


def encrypt_value(plain: str) -> str:
    """Encrypt a plaintext string and return a URL-safe base64 token."""
    if not plain:
        return ""
    return _get_fernet().encrypt(plain.encode("utf-8")).decode("utf-8")


def decrypt_value(token: str) -> str:
    """Decrypt a Fernet token back to plaintext."""
    if not token:
        return ""
    return _get_fernet().decrypt(token.encode("utf-8")).decode("utf-8")
