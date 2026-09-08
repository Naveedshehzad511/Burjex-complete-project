from __future__ import annotations

from copy import deepcopy
from typing import Any


def default_badge_data() -> dict[str, dict[str, Any]]:
    return {
        "email_verified": {"enabled": True, "label": "Verified", "bg": "#22c55e", "fg": "#ffffff"},
        "email_unverified": {"enabled": True, "label": "Not Verified", "bg": "#ef4444", "fg": "#ffffff"},
        "kyc_verified": {"enabled": True, "label": "Verified", "bg": "#22c55e", "fg": "#ffffff"},
        "kyc_pending": {"enabled": True, "label": "Pending", "bg": "#f59e0b", "fg": "#ffffff"},
        "kyc_rejected": {"enabled": True, "label": "Not Verified", "bg": "#ef4444", "fg": "#ffffff"},
        "kyc_expired": {"enabled": True, "label": "Expired", "bg": "#f59e0b", "fg": "#ffffff"},
        "acct_active": {"enabled": True, "label": "Active", "bg": "#22c55e", "fg": "#ffffff"},
        "acct_disabled": {"enabled": True, "label": "Disabled", "bg": "#ef4444", "fg": "#ffffff"},
        "acct_pending": {"enabled": True, "label": "Pending", "bg": "#f59e0b", "fg": "#ffffff"},
    }


def merge_badge_data(stored: dict | None) -> dict[str, dict[str, Any]]:
    out = deepcopy(default_badge_data())
    if not stored:
        return out
    for key, val in stored.items():
        if key in out and isinstance(val, dict):
            out[key].update(val)
    return out
