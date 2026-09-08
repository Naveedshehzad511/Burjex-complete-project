"""Account deletion: what a client still owes or is owed, and the policy text.

Kept out of the view so the same numbers back the API, the staff screen and any
future scheduled purge. A client who is told "nothing outstanding" by one and
"balance remaining" by another has been told nothing at all.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from accounts.models import AccountDeletionRequest, MT5Account


def _decimal(value: Any) -> Decimal:
    try:
        return Decimal(str(value or 0))
    except Exception:
        return Decimal("0")


def collect_obligations(user) -> dict:
    """Money and positions that must be settled before anything is erased.

    Never raises. A deletion request must remain submittable even when MT5 is
    unreachable - if the feed being down could block the request, the store
    requirement that a user can always initiate deletion would depend on a
    third-party service being up. Where a figure cannot be read it is reported
    as unknown and left for a human, rather than silently treated as zero.
    """
    items: list[dict] = []
    unknown: list[str] = []

    user.refresh_from_db(fields=["wallet_balance", "pending_withdraw"])
    wallet = _decimal(getattr(user, "wallet_balance", 0))
    pending = _decimal(getattr(user, "pending_withdraw", 0))

    if wallet > 0:
        items.append({
            "kind": "wallet_balance",
            "label": "Wallet balance",
            "value": str(wallet),
            "detail": "Withdraw your balance before your account is closed.",
        })
    if pending > 0:
        items.append({
            "kind": "pending_withdrawal",
            "label": "Withdrawal in progress",
            "value": str(pending),
            "detail": "Your withdrawal must complete before your account is closed.",
        })

    # Trading accounts: equity sitting with the broker, and anything still open.
    try:
        accounts = MT5Account.objects.filter(user=user, status=MT5Account.Status.ACTIVE)
        live_logins = [a.login_id for a in accounts]
    except Exception:
        live_logins = []
        unknown.append("trading_accounts")

    open_positions = 0
    if live_logins:
        try:
            from mt5_integration.services import _mt5_client, is_mt5_configured

            if is_mt5_configured():
                with _mt5_client() as client:
                    for login in live_logins:
                        try:
                            open_positions += int(client.position_get_total(int(login)) or 0)
                        except Exception:
                            unknown.append(f"positions:{login}")
            else:
                unknown.append("positions")
        except Exception:
            unknown.append("positions")

    if open_positions > 0:
        items.append({
            "kind": "open_positions",
            "label": "Open positions",
            "value": str(open_positions),
            "detail": "Close your open trades before your account is closed.",
        })

    return {
        "items": items,
        "has_obligations": bool(items),
        # Named so the client can say "we could not check X" rather than
        # implying a clean bill of health it did not actually verify.
        "unverified": unknown,
        "trading_accounts": len(live_logins),
    }


def policy_text() -> dict:
    """What is erased, what is kept, and why - shown before the user confirms.

    The retention wording is deliberately non-numeric. The actual period is set
    by the licence the broker trades under, and quoting a specific number here
    that contradicts the licence would be worse than quoting none.
    """
    return {
        "grace_days": AccountDeletionRequest.GRACE_DAYS,
        "erased": [
            "Your profile: name, email, phone, address and date of birth",
            "Identity and address documents you uploaded for verification",
            "Saved bank accounts and crypto withdrawal addresses",
            "Your sign-in credentials and two-factor settings",
            "Support conversations and notification history",
        ],
        "retained": [
            "Records of deposits, withdrawals and completed trades",
            "Identity-verification records required by anti-money-laundering law",
            "Any records subject to an ongoing legal or regulatory matter",
        ],
        "retained_reason": (
            "As a regulated broker we are required by law to keep certain "
            "financial and identity records for a set period after an account "
            "closes. These are locked to compliance use only and are not used "
            "to contact you or for any other purpose."
        ),
    }


def request_payload(req: AccountDeletionRequest | None, user) -> dict:
    """The shape the app renders, for both 'no request' and 'request live'."""
    payload: dict[str, Any] = {
        "policy": policy_text(),
        "obligations": collect_obligations(user),
        "request": None,
    }
    if req is not None:
        payload["request"] = {
            "id": req.id,
            "status": req.status,
            "reason": req.reason,
            "details": req.details,
            "requested_at": req.requested_at.isoformat(),
            "grace_until": req.grace_until.isoformat(),
            "days_remaining": req.days_remaining,
            "is_cancellable": req.is_cancellable,
            "staff_note": req.staff_note,
        }
    return payload
