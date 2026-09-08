"""
Celery tasks for admin_panel (Match-Trader enterprise sync).
"""

from __future__ import annotations

import logging
from decimal import Decimal

try:
    from celery import shared_task
except ImportError:  # pragma: no cover

    def shared_task(*args, **kwargs):
        def decorator(f):
            def delay(*a, **kw):
                return f(*a, **kw)

            f.delay = delay
            return f

        if args and callable(args[0]):
            return decorator(args[0])
        return decorator


logger = logging.getLogger(__name__)


@shared_task
def matchtrader_enterprise_sync_task() -> None:
    """
    When Match-Trader is active: roll up MT5 snapshot fields into per-user snapshots,
    then refresh admin monitor counters. Replace internals with broker REST/gRPC when wired.
    """
    from collections import defaultdict

    from django.db.models import Sum
    from django.utils import timezone

    from accounts.models import MT5Account

    from admin_panel.models import MatchTraderSettings, MatchTraderUserSnapshot

    s = MatchTraderSettings.get_solo()
    if not s.is_active:
        return

    now = timezone.now()
    all_rows = list(MT5Account.objects.filter(status=MT5Account.Status.ACTIVE))
    by_user: dict[int, list] = defaultdict(list)
    for r in all_rows:
        by_user[r.user_id].append(r)

    for uid, rows in list(by_user.items())[:3000]:
        if not rows:
            continue
        bal = sum((Decimal(str(r.balance or 0)) for r in rows), Decimal("0"))
        eq = sum((Decimal(str(r.equity or 0)) for r in rows), Decimal("0"))
        margin = sum(
            (Decimal(str(r.equity or 0)) - Decimal(str(r.free_margin or 0)) for r in rows),
            Decimal("0"),
        )
        if margin < 0:
            margin = Decimal("0")
        open_n = sum(1 for r in rows if Decimal(str(r.unrealized_pnl or 0)) != 0)
        snap, _ = MatchTraderUserSnapshot.objects.get_or_create(user_id=uid)
        snap.balance = bal
        snap.equity = eq
        snap.margin = margin
        snap.open_trades_count = open_n
        snap.pending_orders_count = 0
        snap.open_trades_json = [
            {
                "login": r.login_id,
                "pnl": str(r.unrealized_pnl or 0),
                "balance": str(r.balance or 0),
            }
            for r in rows[:24]
        ]
        snap.pending_orders_json = []
        snap.trade_history_json = []
        snap.save()

    cnt = MatchTraderUserSnapshot.objects.count()
    open_sum = MatchTraderUserSnapshot.objects.aggregate(t=Sum("open_trades_count"))["t"] or 0
    pend_sum = MatchTraderUserSnapshot.objects.aggregate(t=Sum("pending_orders_count"))["t"] or 0

    s.last_sync_at = now
    s.accounts_connected_count = cnt
    s.open_trades_running_count = int(open_sum)
    s.pending_orders_display_count = int(pend_sum)
    s.save(
        update_fields=[
            "last_sync_at",
            "accounts_connected_count",
            "open_trades_running_count",
            "pending_orders_display_count",
            "updated_at",
        ]
    )


# Legacy task names kept importable for workers that still reference them.
@shared_task
def matchtrader_sync_users_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def matchtrader_sync_accounts_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def matchtrader_sync_trades_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def matchtrader_sync_balance_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def matchtrader_sync_deposits_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def matchtrader_sync_withdrawals_task() -> None:
    matchtrader_enterprise_sync_task()


@shared_task
def crm_group_symbols_sync_beat_task() -> None:
    """Periodic pull of instruments from connected platforms into CrmGroupSymbol (per active CRM group)."""
    from admin_panel.services.crm_group_symbol_sync import sync_all_crm_groups

    sync_all_crm_groups()
