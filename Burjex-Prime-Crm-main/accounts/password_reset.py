"""Password-reset tokens and public URLs for forgot-password emails."""

from __future__ import annotations

from urllib.parse import urlparse

from django.conf import settings
from django.contrib.auth.tokens import default_token_generator
from django.utils.encoding import force_bytes, force_str
from django.utils.http import urlsafe_base64_decode, urlsafe_base64_encode

from .models import User

PUBLIC_CRM_BASE = "https://crm.duafx.com"
PUBLIC_PORTAL_BASE = "https://portal.duafx.com"


def _looks_public_https(url: str) -> bool:
    raw = (url or "").strip()
    if not raw.startswith("https://"):
        return False
    host = (urlparse(raw).hostname or "").lower()
    if not host or host in {"localhost", "127.0.0.1"}:
        return False
    if host.startswith("10.") or host.startswith("192.168.") or host.startswith("5.226."):
        return False
    return True


def public_crm_base() -> str:
    """HTTPS CRM origin for email links. Never use the internal :8000 IP."""
    candidates: list[str] = []
    try:
        from admin_panel.models import EmailGlobalLayout

        lay = EmailGlobalLayout.get_solo()
        candidates.append(getattr(lay, "site_base_url", "") or "")
        candidates.append(getattr(lay, "website_url", "") or "")
    except Exception:
        pass
    candidates.append(getattr(settings, "SITE_BASE_URL", "") or "")
    for raw in candidates:
        url = (raw or "").strip().rstrip("/")
        if not url:
            continue
        parsed = urlparse(url if "://" in url else f"https://{url}")
        host = (parsed.hostname or "").lower()
        if host in {"crm.duafx.com", "www.crm.duafx.com"}:
            return "https://crm.duafx.com"
        if _looks_public_https(url) and "duafx.com" in host and "portal." not in host:
            return f"https://{parsed.netloc}".rstrip("/")
    return PUBLIC_CRM_BASE


def make_reset_parts(user: User) -> tuple[str, str]:
    uid = urlsafe_base64_encode(force_bytes(user.pk))
    token = default_token_generator.make_token(user)
    return uid, token


def password_reset_url(user: User, *, portal: bool = False) -> str:
    uid, token = make_reset_parts(user)
    if portal:
        return f"{PUBLIC_PORTAL_BASE}/reset-password?uid={uid}&token={token}"
    return f"{public_crm_base()}/reset-password/{uid}/{token}/"


def user_from_uid_token(uidb64: str, token: str) -> User | None:
    try:
        uid = force_str(urlsafe_base64_decode((uidb64 or "").strip()))
        user = User.objects.filter(pk=uid).first()
    except Exception:
        return None
    if not user or not (token or "").strip():
        return None
    if not default_token_generator.check_token(user, token.strip()):
        return None
    return user
