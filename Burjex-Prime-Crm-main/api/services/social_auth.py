"""Google and Apple Sign-In for the client portal (web OAuth + native id_token)."""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from django.conf import settings
from django.contrib.auth import login
from django.core.signing import BadSignature, SignatureExpired, dumps, loads
from django.db import IntegrityError, transaction
from django.http import HttpRequest
from django.utils import timezone
from django.utils.crypto import get_random_string
from rest_framework.authtoken.models import Token

from accounts.models import User
from admin_panel.models import SocialLoginSettings

logger = logging.getLogger(__name__)

GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo"
APPLE_AUTH_URL = "https://appleid.apple.com/auth/authorize"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"

_APPLE_KEYS_CACHE: dict[str, Any] = {"at": 0.0, "keys": []}


def _b64url_decode(raw: str) -> bytes:
    pad = "=" * ((4 - len(raw) % 4) % 4)
    return base64.urlsafe_b64decode((raw + pad).encode("ascii"))


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _http_json(url: str, *, data: dict | None = None, timeout: int = 20) -> dict:
    body = None
    headers = {"Accept": "application/json", "User-Agent": "BurjexPrime/1.0"}
    if data is not None:
        body = urllib.parse.urlencode(data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        raise ValueError(f"Provider HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ValueError(f"Provider unreachable: {exc.reason}") from exc
    try:
        parsed = json.loads(payload) if payload else {}
    except json.JSONDecodeError as exc:
        raise ValueError("Provider returned invalid JSON.") from exc
    if not isinstance(parsed, dict):
        raise ValueError("Provider returned unexpected JSON.")
    return parsed


def get_settings() -> SocialLoginSettings:
    return SocialLoginSettings.get_solo()


def _google_client_id(cfg: SocialLoginSettings | None = None) -> str:
    cfg = cfg or get_settings()
    return (cfg.google_client_id or "").strip() or (os.environ.get("GOOGLE_OAUTH_CLIENT_ID") or "").strip()


def _google_client_secret(cfg: SocialLoginSettings | None = None) -> str:
    cfg = cfg or get_settings()
    return (cfg.google_client_secret or "").strip() or (os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET") or "").strip()


def google_is_ready(cfg: SocialLoginSettings | None = None) -> bool:
    cfg = cfg or get_settings()
    return bool(cfg.google_enabled) and bool(_google_client_id(cfg)) and bool(_google_client_secret(cfg))


def public_options() -> dict:
    cfg = get_settings()
    google_id = _google_client_id(cfg) if cfg.google_enabled else ""
    apple_id = cfg.apple_client_id.strip() if cfg.apple_enabled else ""
    return {
        "google": bool(cfg.google_enabled),
        "apple": bool(cfg.apple_enabled),
        "google_ready": google_is_ready(cfg),
        "apple_ready": cfg.apple_ready(),
        "google_client_id": google_id,
        "apple_client_id": apple_id,
    }


def oauth_public_base(request: HttpRequest) -> str:
    env_base = (os.environ.get("SOCIAL_OAUTH_BASE_URL") or "").strip().rstrip("/")
    if env_base:
        return env_base
    site = (getattr(settings, "SITE_BASE_URL", "") or "").strip().rstrip("/")
    host = (request.get_host() or "").split(":")[0].lower()
    blob = f"{site} {host}"
    if "burjexprime.net" in blob:
        return "https://crm.burjexprime.net"
    if site:
        return site
    return request.build_absolute_uri("/").rstrip("/")


def callback_url(request: HttpRequest, provider: str) -> str:
    return f"{oauth_public_base(request)}/api/v1/auth/{provider}/callback/"


def google_authorize_url(request: HttpRequest, state: str) -> str:
    cfg = get_settings()
    if not google_is_ready(cfg):
        raise ValueError("Google Sign-In is not configured yet. Add Client ID and Secret under Integrations.")
    params = {
        "client_id": _google_client_id(cfg),
        "redirect_uri": callback_url(request, "google"),
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "access_type": "online",
        "prompt": "select_account",
    }
    return f"{GOOGLE_AUTH_URL}?{urllib.parse.urlencode(params)}"


def apple_authorize_url(request: HttpRequest, state: str) -> str:
    cfg = get_settings()
    if not cfg.apple_ready():
        raise ValueError("Apple Sign-In is not configured yet. Add Services ID and key under Integrations.")
    params = {
        "client_id": cfg.apple_client_id.strip(),
        "redirect_uri": callback_url(request, "apple"),
        "response_type": "code id_token",
        "response_mode": "form_post",
        "scope": "name email",
        "state": state,
    }
    return f"{APPLE_AUTH_URL}?{urllib.parse.urlencode(params)}"


def _apple_client_secret() -> str:
    cfg = get_settings()
    pem = (cfg.apple_private_key or "").strip()
    if "BEGIN" not in pem:
        pem = "-----BEGIN PRIVATE KEY-----\n" + pem + "\n-----END PRIVATE KEY-----"
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key = serialization.load_pem_private_key(pem.encode("utf-8"), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": cfg.apple_key_id.strip(), "typ": "JWT"}
    payload = {
        "iss": cfg.apple_team_id.strip(),
        "iat": now,
        "exp": now + 86400 * 150,
        "aud": "https://appleid.apple.com",
        "sub": cfg.apple_client_id.strip(),
    }
    signing_input = (
        f"{_b64url_encode(json.dumps(header, separators=(',', ':')).encode())}."
        f"{_b64url_encode(json.dumps(payload, separators=(',', ':')).encode())}"
    )
    der = key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{_b64url_encode(raw_sig)}"


def _apple_public_keys() -> list[dict]:
    now = time.time()
    if _APPLE_KEYS_CACHE["keys"] and now - float(_APPLE_KEYS_CACHE["at"]) < 3600:
        return list(_APPLE_KEYS_CACHE["keys"])
    data = _http_json(APPLE_KEYS_URL)
    keys = data.get("keys") or []
    if not isinstance(keys, list):
        keys = []
    _APPLE_KEYS_CACHE["at"] = now
    _APPLE_KEYS_CACHE["keys"] = keys
    return keys


def _verify_apple_id_token(id_token: str) -> dict:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers

    parts = (id_token or "").split(".")
    if len(parts) != 3:
        raise ValueError("Invalid Apple identity token.")
    header = json.loads(_b64url_decode(parts[0]).decode("utf-8"))
    kid = str(header.get("kid") or "")
    keys = _apple_public_keys()
    jwk = next((k for k in keys if isinstance(k, dict) and k.get("kid") == kid), None)
    if not jwk:
        raise ValueError("Apple signing key was not found.")
    n = int.from_bytes(_b64url_decode(str(jwk.get("n") or "")), "big")
    e = int.from_bytes(_b64url_decode(str(jwk.get("e") or "")), "big")
    pub = RSAPublicNumbers(e, n).public_key()
    signing_input = f"{parts[0]}.{parts[1]}".encode("ascii")
    pub.verify(_b64url_decode(parts[2]), signing_input, padding.PKCS1v15(), hashes.SHA256())
    claims = json.loads(_b64url_decode(parts[1]).decode("utf-8"))
    cfg = get_settings()
    aud = claims.get("aud")
    expected = cfg.apple_client_id.strip()
    if expected and aud not in (expected, [expected]):
        if isinstance(aud, list) and expected not in aud:
            raise ValueError("Apple token audience mismatch.")
        if isinstance(aud, str) and aud != expected:
            raise ValueError("Apple token audience mismatch.")
    if int(claims.get("exp") or 0) < int(time.time()) - 30:
        raise ValueError("Apple token has expired.")
    return claims


def exchange_google_code(request: HttpRequest, code: str) -> dict:
    cfg = get_settings()
    data = _http_json(
        GOOGLE_TOKEN_URL,
        data={
            "code": code,
            "client_id": _google_client_id(cfg),
            "client_secret": _google_client_secret(cfg),
            "redirect_uri": callback_url(request, "google"),
            "grant_type": "authorization_code",
        },
    )
    id_token = (data.get("id_token") or "").strip()
    if not id_token:
        raise ValueError("Google did not return an ID token.")
    return verify_google_id_token(id_token)


def verify_google_id_token(id_token: str) -> dict:
    cfg = get_settings()
    info = _http_json(f"{GOOGLE_TOKENINFO_URL}?{urllib.parse.urlencode({'id_token': id_token})}")
    aud = str(info.get("aud") or "")
    expected_aud = _google_client_id(cfg)
    if expected_aud and aud != expected_aud:
        raise ValueError("Google token audience mismatch.")
    if str(info.get("email_verified") or "").lower() not in {"true", "1"}:
        raise ValueError("Google email is not verified.")
    email = str(info.get("email") or "").strip().lower()
    sub = str(info.get("sub") or "").strip()
    if not email or not sub:
        raise ValueError("Google did not return an email.")
    first_name = str(info.get("given_name") or "").strip()
    last_name = str(info.get("family_name") or "").strip()
    name = str(info.get("name") or "").strip()
    if not first_name and name:
        parts = name.split(None, 1)
        first_name = parts[0]
        if len(parts) > 1 and not last_name:
            last_name = parts[1]
    return {
        "provider": "google",
        "sub": sub,
        "email": email,
        "first_name": first_name[:150],
        "last_name": last_name[:150],
    }


def exchange_apple_code(request: HttpRequest, code: str, id_token: str = "") -> dict:
    cfg = get_settings()
    token = (id_token or "").strip()
    if not token and code:
        data = _http_json(
            APPLE_TOKEN_URL,
            data={
                "client_id": cfg.apple_client_id.strip(),
                "client_secret": _apple_client_secret(),
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": callback_url(request, "apple"),
            },
        )
        token = str(data.get("id_token") or "").strip()
    if not token:
        raise ValueError("Apple did not return an identity token.")
    return verify_apple_identity(token)


def verify_apple_identity(id_token: str, *, first_name: str = "", last_name: str = "") -> dict:
    claims = _verify_apple_id_token(id_token)
    email = str(claims.get("email") or "").strip().lower()
    sub = str(claims.get("sub") or "").strip()
    if not sub:
        raise ValueError("Apple did not return a user id.")
    return {
        "provider": "apple",
        "sub": sub,
        "email": email,
        "first_name": (first_name or "").strip()[:150],
        "last_name": (last_name or "").strip()[:150],
    }


def _unique_username(seed: str) -> str:
    base = re.sub(r"[^a-zA-Z0-9._-]", "", (seed or "user").split("@")[0])[:18] or "user"
    candidate = base
    n = 0
    while User.objects.filter(username__iexact=candidate).exists():
        n += 1
        candidate = f"{base}{n}"[:30]
    return candidate


def _after_social_user_created(user: User) -> None:
    try:
        from api.services.signup_demo import ensure_signup_demo_for_new_client

        ensure_signup_demo_for_new_client(user, force=True)
    except Exception:
        logger.exception("social signup demo failed user_id=%s", user.pk)
    try:
        from django.urls import reverse
        from enterprise.staff_notify import broadcast_staff_notification

        source = "Google" if (user.google_sub or "").strip() else "Apple"
        reg_token = f"[reg_user:{user.pk}]"
        broadcast_staff_notification(
            "New client registration",
            f"{reg_token} {user.display_name()} ({user.email}) registered via {source}.",
            action_url=reverse("admin-user-list"),
            dedupe_body_contains=reg_token,
        )
    except Exception:
        logger.exception("social signup staff notify failed user_id=%s", user.pk)


def get_or_create_social_user(profile: dict) -> User:
    provider = profile["provider"]
    sub = profile["sub"]
    email = (profile.get("email") or "").strip().lower()
    first_name = (profile.get("first_name") or "").strip()[:150]
    last_name = (profile.get("last_name") or "").strip()[:150]
    if not first_name:
        name = (profile.get("name") or "").strip()
        if name:
            parts = name.split(None, 1)
            first_name = parts[0][:150]
            if len(parts) > 1 and not last_name:
                last_name = parts[1][:150]

    qs = User.objects.all()
    user = None
    if provider == "google" and sub:
        user = qs.filter(google_sub=sub).first()
    elif provider == "apple" and sub:
        user = qs.filter(apple_sub=sub).first()
    if user is None and email:
        user = qs.filter(email__iexact=email).first()
    if user is None and not email:
        raise ValueError("This Apple ID did not share an email. Use an Apple ID with email, or sign up with Google.")

    if user is not None:
        if not user.is_user():
            raise ValueError("This email belongs to a staff account. Use staff login.")
        r = getattr(user, "restriction", None)
        if r and r.disable_client_area:
            raise ValueError("Your account has been disabled. Please contact support.")
        changed = []
        if provider == "google" and user.google_sub != sub:
            user.google_sub = sub
            changed.append("google_sub")
        if provider == "apple" and user.apple_sub != sub:
            user.apple_sub = sub
            changed.append("apple_sub")
        if not user.email_verified:
            user.email_verified = True
            user.email_verified_at = timezone.now()
            changed.extend(["email_verified", "email_verified_at"])
        if first_name and not user.first_name:
            user.first_name = first_name
            changed.append("first_name")
        if last_name and not user.last_name:
            user.last_name = last_name
            changed.append("last_name")
        if changed:
            user.save(update_fields=changed)
        return user

    username = _unique_username(email)
    with transaction.atomic():
        user = User(
            username=username,
            email=email,
            first_name=first_name,
            last_name=last_name,
            role=User.Roles.CLIENT,
            account_status=User.AccountStatus.APPROVED,
            email_verified=True,
            email_verified_at=timezone.now(),
            google_sub=sub if provider == "google" else "",
            apple_sub=sub if provider == "apple" else "",
        )
        user.set_unusable_password()
        user._skip_auth_emails = True
        try:
            user.save()
        except IntegrityError as exc:
            raise ValueError("Unable to create this account. That email may already be registered.") from exc
    _after_social_user_created(user)
    return user


def issue_client_token(user: User) -> str:
    token, _ = Token.objects.get_or_create(user=user)
    return token.key


def complete_html_login(request: HttpRequest, user: User) -> str:
    """Session login for Django CRM. Returns redirect path or totp URL name."""
    if user.totp_enabled and user.totp_secret:
        request.session["pending_user_totp"] = user.pk
        request.session["pending_user_totp_next"] = "/user/dashboard/"
        return "totp"
    login(request, user)
    return "/user/dashboard/"


def complete_api_login(request: HttpRequest, user: User) -> dict:
    if user.totp_enabled and user.totp_secret:
        pending = f"api_pending_totp:{user.pk}:{get_random_string(32)}"
        request.session["pending_user_totp"] = user.pk
        request.session["api_pending_user_totp_token"] = pending
        return {
            "totp_required": True,
            "pending_token": pending,
            "user_id": user.pk,
            "token": "",
        }
    login(request, user)
    return {
        "totp_required": False,
        "token": issue_client_token(user),
        "user_id": user.pk,
    }


def new_oauth_state(request: HttpRequest, *, mode: str, next_url: str) -> str:
    payload = {
        "m": "token" if mode == "token" else "html",
        "n": (next_url or "")[:2000],
        "t": int(time.time()),
    }
    return dumps(payload, salt="bx-social-oauth", compress=True)


def pop_oauth_state(request: HttpRequest, state: str) -> tuple[str, str]:
    try:
        payload = loads(state or "", salt="bx-social-oauth", max_age=900)
    except (BadSignature, SignatureExpired, TypeError, ValueError) as exc:
        raise ValueError("Social login session expired. Please try again.") from exc
    if not isinstance(payload, dict):
        raise ValueError("Social login session expired. Please try again.")
    mode = "token" if payload.get("m") == "token" else "html"
    next_url = str(payload.get("n") or "")
    return mode, next_url
