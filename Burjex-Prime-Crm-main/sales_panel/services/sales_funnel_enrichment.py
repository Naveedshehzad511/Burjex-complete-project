"""Batch lookups for funnel stage list views (avoid N+1 where cheap)."""

from __future__ import annotations

from collections.abc import Iterable

from accounts.models import MT5Account, User
from transactions.models import Transaction


def first_deposit_by_user_ids(user_ids: Iterable[int]) -> dict[int, Transaction]:
    ids = list(user_ids)
    if not ids:
        return {}
    qs = (
        Transaction.objects.filter(
            actor_id__in=ids,
            tx_type__in=(
                Transaction.TxType.CLIENT_DEPOSIT,
                Transaction.TxType.WALLET_DEPOSIT,
            ),
            status=Transaction.Status.COMPLETED,
        )
        .order_by("actor_id", "created_at")
        .select_related("actor")
    )
    out: dict[int, Transaction] = {}
    for t in qs:
        aid = t.actor_id
        if aid is not None and aid not in out:
            out[aid] = t
    return out


def first_live_mt5_by_user(users: Iterable[User]) -> dict[int, MT5Account]:
    out: dict[int, MT5Account] = {}
    for u in users:
        for a in u.mt5_accounts.all():
            if a.account_type == MT5Account.AccountType.LIVE:
                out[u.id] = a
                break
    return out
