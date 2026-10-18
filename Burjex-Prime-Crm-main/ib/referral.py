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


PORTAL_REGISTER_URL = "https://portal.burjexprime.net/register"


def build_register_referral_url(request, ib_code: str) -> str:
    """App/portal signup URL with the IB ID: https://portal.burjexprime.net/register?ref={ib_code}."""
    safe_code = quote(str(ib_code).strip(), safe="")
    return f"{PORTAL_REGISTER_URL}?ref={safe_code}"


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


def resolve_signup_inviter(ref: str = "", legacy: str = ""):
    """
    The approved IB a signup refers to: a Partner Code (IBProfile.ib_code, matched case-insensitively - the same
    code whether it came from the referral link or was typed) or a legacy ?ib=user_id. None when nothing matches.
    """
    from accounts.models import User
    from .models import IBProfile

    ref = (ref or "").strip()
    legacy = (legacy or "").strip()
    if ref:
        prof = IBProfile.objects.select_related("user").filter(ib_code__iexact=ref).first()
        if prof and prof.user_id and prof.user.role == User.Roles.IB:
            return prof.user
    if legacy.isdigit():
        return User.objects.filter(pk=int(legacy), role=User.Roles.IB).first()
    return None


def signup_referral_from_request(request) -> tuple[str, str]:
    """The (partner code, legacy IB id) a signup request carries: the form value first, else the link's session value."""
    ref = (request.POST.get("signup_ref", "") or "").strip()
    legacy = (request.POST.get("signup_ib_legacy", "") or "").strip()
    if hasattr(request, "session"):
        if not ref:
            ref = (request.session.get("signup_ib_ref") or "").strip()
        if not legacy:
            legacy = (request.session.get("signup_ib_user_id") or "").strip()
    return ref, legacy


INVALID_PARTNER_CODE_MESSAGE = "This Partner Code is not valid. Check it and try again, or clear the field to register without one."


def signup_partner_code_error(request) -> str:
    """Non-empty when the signup names a Partner Code / IB that does not exist: registration must stop, not go on unattributed."""
    ref, legacy = signup_referral_from_request(request)
    if not ref and not legacy:
        return ""
    return "" if resolve_signup_inviter(ref, legacy) else INVALID_PARTNER_CODE_MESSAGE


def assign_ib_from_signup_referral(request, user) -> None:
    """
    If signup used ?ref=ib_code or legacy ?ib=user_id, link client to IB and create approved IBRequest.
    """
    from .models import IBPlan, IBRequest

    ref, legacy = signup_referral_from_request(request)
    inviter_user = resolve_signup_inviter(ref, legacy)

    if not inviter_user or inviter_user.pk == user.pk:
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
