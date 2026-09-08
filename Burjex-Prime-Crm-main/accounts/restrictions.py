from __future__ import annotations

from accounts.models import UserRestriction


def get_or_create_restriction(user):
    r, _ = UserRestriction.objects.get_or_create(user=user)
    return r


def restriction_for_user(user):
    """Return UserRestriction row if it exists, else None."""
    return UserRestriction.objects.filter(user=user).first()
