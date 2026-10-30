"""Location rule for the iPhone / iPad app (App Store guideline 3.2.2(viii)): sign-in and registration only from the
countries set in the admin panel (``MobileAppAccessPolicy``), decided here on the server.

The app sends ``X-Client-Platform: ios`` on every CRM request. Before signing in or registering it posts the device's
position to ``/auth/geo-check/`` and gets back a signed, short-lived ticket with the outcome, which it sends with the
sign-in / registration (``X-Geo-Ticket``). The outcome combines:

* the country of the GPS position (an offline map of country borders, ``api/data/country_borders.json``),
* the country of the network (Cloudflare's ``CF-IPCountry``): a VPN or proxy elsewhere is refused,
* iOS's "simulated by software" flag.

A signed-in iPhone / iPad session confirms its location again every ``recheck_hours`` (``enforce_session``).
Requests without the iOS header (Android, the website) are never affected.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from datetime import timedelta
from functools import lru_cache
from pathlib import Path

from django.core import signing
from django.utils import timezone
from rest_framework.exceptions import PermissionDenied

from admin_panel.models import MobileAppAccessPolicy, MobileGeoVerification
from api.responses import error_response

logger = logging.getLogger(__name__)

PLATFORM_HEADER = "HTTP_X_CLIENT_PLATFORM"
TICKET_HEADER = "HTTP_X_GEO_TICKET"
_TICKET_SALT = "bx.mobile-geo.v1"
_BORDERS = Path(__file__).resolve().parent.parent / "data" / "country_borders.json"

# Reasons (also the codes the app reads from ``data.geo``).
ALLOWED = "allowed"
EXEMPT = "exempt"
DISABLED = "disabled"
LOCATION_REQUIRED = "location_required"
COUNTRY_BLOCKED = "country_blocked"
NETWORK_MISMATCH = "network_mismatch"
SIMULATED = "simulated_location"
CHECK_REQUIRED = "check_required"


def is_ios_app(request) -> bool:
    return (request.META.get(PLATFORM_HEADER) or "").strip().lower() == "ios"


_policy_cache: tuple[float, MobileAppAccessPolicy] | None = None


def policy() -> MobileAppAccessPolicy:
    """The admin's policy, re-read at most every 30 s (it is consulted on every iPhone / iPad request)."""
    global _policy_cache
    now = time.monotonic()
    if _policy_cache is None or now - _policy_cache[0] > 30:
        _policy_cache = (now, MobileAppAccessPolicy.get_solo())
    return _policy_cache[1]


def forget_policy() -> None:
    """Called when the admin saves the policy (and by tests)."""
    global _policy_cache
    _policy_cache = None


def is_exempt(p: MobileAppAccessPolicy, *identities) -> bool:
    exempt = p.exempt_set()
    return bool(exempt) and any((i or "").strip().lower() in exempt for i in identities if i)


def _user_identities(user) -> tuple:
    return (getattr(user, "email", ""), getattr(user, "username", ""))


# ---- countries -------------------------------------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _borders() -> list[tuple[str, tuple[float, float, float, float], list[list[list[float]]]]]:
    """[(ISO2, (min lon, min lat, max lon, max lat), polygon rings)] from Natural Earth 1:50m (public domain)."""
    raw = json.loads(_BORDERS.read_text(encoding="utf-8"))
    out = []
    for iso, polygons in raw.items():
        for rings in polygons:
            outer = rings[0]
            xs, ys = outer[0::2], outer[1::2]
            out.append((iso, (min(xs), min(ys), max(xs), max(ys)), rings))
    return out


def _in_ring(lon: float, lat: float, ring: list[float]) -> bool:
    inside = False
    n = len(ring) // 2
    j = n - 1
    for i in range(n):
        xi, yi = ring[2 * i], ring[2 * i + 1]
        xj, yj = ring[2 * j], ring[2 * j + 1]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def country_at(lat: float, lon: float) -> str | None:
    """ISO 3166-1 alpha-2 code of the country at this position, or None (sea, or no data)."""
    for iso, (x0, y0, x1, y1), rings in _borders():
        if not (x0 <= lon <= x1 and y0 <= lat <= y1):
            continue
        if _in_ring(lon, lat, rings[0]) and not any(_in_ring(lon, lat, hole) for hole in rings[1:]):
            return iso
    return None


def ip_country(request) -> str | None:
    """The network's country from Cloudflare (``XX`` unknown and ``T1`` Tor count as unknown)."""
    c = (request.META.get("HTTP_CF_IPCOUNTRY") or "").strip().upper()
    if len(c) != 2 or not c.isalpha() or c in {"XX", "T1"}:
        return None
    return c


# ---- the decision ----------------------------------------------------------------------------------------------------


@dataclass
class Decision:
    allowed: bool
    reason: str
    gps_country: str = ""
    ip_country: str = ""

    def message(self, p: MobileAppAccessPolicy) -> str:
        if self.allowed:
            return ""
        if self.reason == NETWORK_MISMATCH:
            return p.network_mismatch_message
        if self.reason in (LOCATION_REQUIRED, CHECK_REQUIRED):
            return p.location_required_message
        return p.blocked_message


def _number(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f == f else None  # not NaN


def evaluate(request, data, *, user=None) -> Decision:
    """The decision for a position the app sent (``latitude``, ``longitude``, ``accuracy``, ``simulated``)."""
    p = policy()
    if not p.ios_enabled:
        return Decision(True, DISABLED)
    if user is not None and is_exempt(p, *_user_identities(user)):
        return Decision(True, EXEMPT)
    net = ip_country(request) or ""
    lat, lon = _number(data.get("latitude")), _number(data.get("longitude"))
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return Decision(False, LOCATION_REQUIRED, ip_country=net)
    accuracy = _number(data.get("accuracy"))
    if accuracy is not None and p.max_accuracy_m and accuracy > p.max_accuracy_m:
        return Decision(False, LOCATION_REQUIRED, ip_country=net)
    if p.block_simulated_location and str(data.get("simulated")).lower() in {"true", "1"}:
        return Decision(False, SIMULATED, ip_country=net)
    allowed = p.allowed_set()
    gps = country_at(lat, lon) or ""
    if gps not in allowed:
        return Decision(False, COUNTRY_BLOCKED, gps, net)
    if p.require_ip_country:
        if not net:
            if not p.allow_unknown_ip_country:
                return Decision(False, NETWORK_MISMATCH, gps, net)
        elif net not in allowed:
            return Decision(False, NETWORK_MISMATCH, gps, net)
    return Decision(True, ALLOWED, gps, net)


def issue_ticket(d: Decision) -> str:
    return signing.dumps({"a": d.allowed, "r": d.reason, "g": d.gps_country, "n": d.ip_country}, salt=_TICKET_SALT)


def read_ticket(raw: str, p: MobileAppAccessPolicy) -> Decision | None:
    if not raw:
        return None
    try:
        v = signing.loads(raw, salt=_TICKET_SALT, max_age=max(1, p.ticket_minutes) * 60)
    except signing.BadSignature:  # includes an expired ticket
        return None
    return Decision(bool(v.get("a")), str(v.get("r") or ""), str(v.get("g") or ""), str(v.get("n") or ""))


def _denied(p: MobileAppAccessPolicy, d: Decision):
    return error_response(d.message(p), status=403, data={"geo": d.reason})


def gate_sign_in(request, *identities):
    """For a sign-in / registration from the iPhone / iPad app: None when it may go ahead, else the 403 to return.
    [identities] are the account's email / username (an exempt account passes without a location)."""
    if not is_ios_app(request):
        return None
    p = policy()
    if not p.ios_enabled or is_exempt(p, *identities):
        return None
    d = read_ticket(request.META.get(TICKET_HEADER) or "", p)
    if d is None:
        d = Decision(False, LOCATION_REQUIRED, ip_country=ip_country(request) or "")
    elif d.allowed and p.require_ip_country:
        # The ticket was issued on another network than this request (it was carried elsewhere): check again.
        net = ip_country(request)
        if net and net not in p.allowed_set():
            d = Decision(False, NETWORK_MISMATCH, d.gps_country, net)
    if d.allowed:
        return None
    logger.warning("mobile geo: sign-in refused reason=%s gps=%s ip=%s", d.reason, d.gps_country, d.ip_country)
    return _denied(p, d)


def record(token_key: str, user, d: Decision) -> None:
    """Remember the outcome for this session's token (what ``enforce_session`` checks)."""
    if not token_key or user is None:
        return
    MobileGeoVerification.objects.update_or_create(
        token_key=token_key,
        defaults={
            "user": user,
            "allowed": d.allowed,
            "reason": d.reason[:40],
            "gps_country": d.gps_country,
            "ip_country": d.ip_country,
            "verified_at": timezone.now(),
        },
    )


def record_sign_in(request, token_key: str, user) -> None:
    """After a successful iPhone / iPad sign-in: the session starts verified (from the ticket that let it in)."""
    if not is_ios_app(request) or not token_key:
        return
    p = policy()
    if not p.ios_enabled:
        return
    if is_exempt(p, *_user_identities(user)):
        record(token_key, user, Decision(True, EXEMPT))
        return
    d = read_ticket(request.META.get(TICKET_HEADER) or "", p)
    if d is not None and d.allowed:
        record(token_key, user, d)


class GeoCheckRequired(PermissionDenied):
    """An iPhone / iPad session whose location has not been confirmed recently (the app checks it and retries)."""

    def __init__(self, message: str, code: str = CHECK_REQUIRED):
        super().__init__(detail=message)
        self.geo_code = code


# Paths a session may call without a fresh location check (the check itself, and leaving).
_UNGATED = ("/auth/geo-check/", "/auth/logout/")


def enforce_session(request, user, token) -> None:
    """Called for every token-authenticated request: an iPhone / iPad session needs a location check younger than the
    policy's ``recheck_hours`` that allowed it."""
    if not is_ios_app(request):
        return
    path = getattr(request, "path", "") or ""
    if path.endswith(_UNGATED):
        return
    p = policy()
    if not p.ios_enabled or is_exempt(p, *_user_identities(user)):
        return
    v = MobileGeoVerification.objects.filter(token_key=getattr(token, "key", "")).first()
    fresh_after = timezone.now() - timedelta(hours=max(1, p.recheck_hours))
    if v is not None and v.allowed and v.verified_at >= fresh_after:
        return
    # Not checked yet (a session from before this rule), too long ago, or refused: the app checks again, then retries
    # or signs out.
    raise GeoCheckRequired(p.location_required_message)
