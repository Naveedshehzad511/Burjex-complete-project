"""IB referral links: /register?ref={ib_code} and signup assignment."""

from __future__ import annotations

import secrets
import string
from urllib.parse import quote

from django.utils import timezone


def generate_unique_ib_code() -> str:
    """Public referral code stored on IBProfile (unique)."""
    from .models import IBProfile

    alphabet = string.ascii_uppercase + string.digits
    for _ in range(80):
        code = "IB" + "".join(secrets.choice(alphabet) for _ in range(8))
        if not IBProfile.objects.filter(ib_code=code).exists():
            return code
    tail = "IB" + secrets.token_hex(10).upper()[:24]
    while IBProfile.objects.filter(ib_code=tail).exists():
        tail = "IB" + secrets.token_hex(10).upper()[:24]
    return tail


def build_register_referral_url(request, ib_code: str) -> str:
    """Absolute URL: https://host/register?ref={ib_code}"""
    from django.urls import reverse

    path = reverse("client-register")
    safe_code = quote(str(ib_code).strip(), safe="")
    return request.build_absolute_uri(f"{path}?ref={safe_code}")


def ensure_profile_referral_url(request, profile) -> str:
    """Ensure profile has ib_code and referral_link; return referral URL."""
    from .models import IBProfile

    if not profile.ib_code or not str(profile.ib_code).strip():
        profile.ib_code = generate_unique_ib_code()
        while IBProfile.objects.filter(ib_code=profile.ib_code).exclude(pk=profile.pk).exists():
            profile.ib_code = generate_unique_ib_code()
    url = build_register_referral_url(request, profile.ib_code)
    profile.referral_link = url
    return url


def assign_ib_from_signup_referral(request, user) -> None:
    """
    If signup used ?ref=ib_code or legacy ?ib=user_id, link client to IB and create approved IBRequest.
    """
    from accounts.models import User
    from .models import IBPlan, IBProfile, IBRequest

    ref = (request.POST.get("signup_ref", "") or "").strip()
    legacy = (request.POST.get("signup_ib_legacy", "") or "").strip()
    if hasattr(request, "session"):
        if not ref:
            ref = (request.session.get("signup_ib_ref") or "").strip()
        if not legacy:
            legacy = (request.session.get("signup_ib_user_id") or "").strip()

    inviter_user = None
    if ref:
        prof = IBProfile.objects.select_related("user").filter(ib_code__iexact=ref).first()
        if prof and prof.user_id:
            inviter_user = prof.user
    if inviter_user is None and legacy.isdigit():
        u = User.objects.filter(pk=int(legacy), role=User.Roles.IB).first()
        if u:
            inviter_user = u

    if not inviter_user or inviter_user.pk == user.pk:
        if hasattr(request, "session"):
            request.session.pop("signup_ib_ref", None)
            request.session.pop("signup_ib_user_id", None)
        return
    if inviter_user.role != User.Roles.IB:
        if hasattr(request, "session"):
            request.session.pop("signup_ib_ref", None)
            request.session.pop("signup_ib_user_id", None)
        return

    user.referred_by_id = inviter_user.pk
    user.ib_linked_at = timezone.now()
    user.save(update_fields=["referred_by_id", "ib_linked_at"])

    plan = IBPlan.objects.filter(is_active=True).order_by("id").first()
    row = IBRequest.objects.filter(ib_user=inviter_user, client_user=user).order_by("-id").first()
    if not row:
        IBRequest.objects.create(
            ib_user=inviter_user,
            client_user=user,
            plan=plan,
            status=IBRequest.Status.APPROVED,
            notes="Referral signup",
            processed_at=timezone.now(),
        )
    elif row.status != IBRequest.Status.APPROVED:
        row.status = IBRequest.Status.APPROVED
        row.processed_at = timezone.now()
        row.save(update_fields=["status", "processed_at"])

    try:
        from .level_progress import refresh_referral_count
        refresh_referral_count(inviter_user, increment_period=True)
    except Exception:
        pass

    if hasattr(request, "session"):
        request.session.pop("signup_ib_ref", None)
        request.session.pop("signup_ib_user_id", None)
