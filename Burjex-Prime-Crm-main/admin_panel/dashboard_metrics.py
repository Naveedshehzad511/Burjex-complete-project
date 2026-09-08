"""
Live metrics for admin dashboard stat cards (ORM — same data the CRM already stores).
"""
from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.db.models import Q, Sum
from django.utils import timezone

from accounts.models import MT5Account, User
from transactions.models import Transaction


def _approved_money_qs(tx_types: list):
    return Transaction.objects.filter(
        tx_type__in=tx_types,
        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        is_demo_ledger=False,
    )


def get_admin_dashboard_live_metrics() -> dict:
    now = timezone.now()
    cutoff_30 = now - timedelta(days=30)
    today = timezone.localdate()
    week_from = today - timedelta(days=6)

    dep_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    wdr_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]

    total_users = User.objects.count()
    active_users_30d = User.objects.filter(last_login__isnull=False, last_login__gte=cutoff_30).count()
    inactive_users_30d = User.objects.filter(Q(last_login__isnull=True) | Q(last_login__lt=cutoff_30)).count()
    total_ib = User.objects.filter(role=User.Roles.IB).count()

    dep_base = _approved_money_qs(dep_types)
    wdr_base = _approved_money_qs(wdr_types)

    def _fdec(x) -> Decimal:
        return Decimal(str(x or 0))

    total_deposits = _fdec(dep_base.aggregate(t=Sum("amount"))["t"])
    total_withdrawals = _fdec(wdr_base.aggregate(t=Sum("amount"))["t"])
    net_revenue = total_deposits - total_withdrawals

    total_real = MT5Account.objects.filter(account_type=MT5Account.AccountType.LIVE).count()
    total_demo = MT5Account.objects.filter(account_type=MT5Account.AccountType.DEMO).count()

    today_dep = _fdec(
        dep_base.filter(created_at__date=today).aggregate(t=Sum("amount"))["t"]
    )
    today_wdr = _fdec(
        wdr_base.filter(created_at__date=today).aggregate(t=Sum("amount"))["t"]
    )
    week_dep = _fdec(
        dep_base.filter(created_at__date__gte=week_from, created_at__date__lte=today).aggregate(t=Sum("amount"))["t"]
    )
    week_wdr = _fdec(
        wdr_base.filter(created_at__date__gte=week_from, created_at__date__lte=today).aggregate(t=Sum("amount"))["t"]
    )

    return {
        "total_users": total_users,
        "active_users_30d": active_users_30d,
        "inactive_users_30d": inactive_users_30d,
        "total_ib": total_ib,
        "total_deposits": float(total_deposits),
        "total_withdrawals": float(total_withdrawals),
        "net_revenue": float(net_revenue),
        "total_real_accounts": total_real,
        "total_demo_accounts": total_demo,
        "today_deposits": float(today_dep),
        "today_withdrawals": float(today_wdr),
        "weekly_deposits": float(week_dep),
        "weekly_withdrawals": float(week_wdr),
        "week_from": week_from.isoformat(),
        "today": today.isoformat(),
    }
