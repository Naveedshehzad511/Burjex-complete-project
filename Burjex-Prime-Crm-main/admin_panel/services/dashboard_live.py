"""
All-time and intraday KPIs for the admin dashboard (not scoped by the page date filter).
Used for live-sync cards and the JSON poll endpoint.

Sources: User, MT5Account, Transaction (wallet + client flows; ``is_demo_ledger=False`` only),
PaymentGateway (``visibility_status=ACTIVE`` and ``is_active``). Trading lines use admin
``SimulatedIBTrade`` aggregates: net adds company profit plus non-negative (gross commission − profit),
i.e. simulator gross client commission when data is consistent.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.db.models import (
    Count,
    DecimalField,
    ExpressionWrapper,
    F,
    Q,
    Sum,
)
from django.db.utils import OperationalError
from django.utils import timezone

from accounts.models import MT5Account, User
from transactions.models import PaymentGateway, Transaction


def _money(val) -> Decimal:
    if val is None:
        return Decimal("0")
    return Decimal(str(val))


def _real_money_tx_qs() -> Transaction:
    """Completed / approved movements; exclude virtual demo ledger rows."""
    settled = [Transaction.Status.COMPLETED, Transaction.Status.APPROVED]
    return Transaction.objects.filter(status__in=settled, is_demo_ledger=False)


def get_live_dashboard_kpis() -> dict:
    """
    Returns numeric stats and payment-method metadata for live dashboard widgets.

    Aligns headline figures with the admin dashboard cards: total users = all registered
    users; active users = last login within 30 days (any role). Net revenue = approved
    and completed real-money deposits minus withdrawals (no demo ledger). Optional
    simulated-trade lines are still exposed for analytics consumers.
    """
    today = timezone.localtime(timezone.now()).date()
    login_cutoff_30d = timezone.now() - timedelta(days=30)

    deposit_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    withdraw_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]

    total_users = 0
    active_users = 0
    total_live_accounts = 0
    total_demo_accounts = 0
    total_deposit = Decimal("0")
    total_withdrawal = Decimal("0")
    today_deposit = Decimal("0")
    today_withdrawal = Decimal("0")
    trading_commission = Decimal("0")
    spread_revenue = Decimal("0")
    active_payment_methods_count = 0
    active_payment_methods: list[dict] = []

    try:
        total_users = User.objects.count()
        active_users = User.objects.filter(last_login__isnull=False, last_login__gte=login_cutoff_30d).count()

        acct_agg = MT5Account.objects.aggregate(
            live=Count("id", filter=Q(account_type=MT5Account.AccountType.LIVE)),
            demo=Count("id", filter=Q(account_type=MT5Account.AccountType.DEMO)),
        )
        total_live_accounts = int(acct_agg.get("live") or 0)
        total_demo_accounts = int(acct_agg.get("demo") or 0)

        tx = _real_money_tx_qs()
        fin = tx.aggregate(
            total_dep=Sum("amount", filter=Q(tx_type__in=deposit_types)),
            total_wd=Sum("amount", filter=Q(tx_type__in=withdraw_types)),
            today_dep=Sum(
                "amount",
                filter=Q(tx_type__in=deposit_types, created_at__date=today),
            ),
            today_wd=Sum(
                "amount",
                filter=Q(tx_type__in=withdraw_types, created_at__date=today),
            ),
        )
        total_deposit = _money(fin.get("total_dep"))
        total_withdrawal = _money(fin.get("total_wd"))
        today_deposit = _money(fin.get("today_dep"))
        today_withdrawal = _money(fin.get("today_wd"))
    except OperationalError:
        pass
    except Exception:
        pass

    try:
        from admin_panel.models import SimulatedIBTrade

        sim = SimulatedIBTrade.objects.aggregate(
            gross_comm=Sum(
                ExpressionWrapper(
                    F("commission_per_lot_client") * F("lots"),
                    output_field=DecimalField(max_digits=28, decimal_places=8),
                )
            ),
            company_profit=Sum("company_profit_estimate"),
        )
        gross_comm = _money(sim.get("gross_comm"))
        company_profit = _money(sim.get("company_profit"))
        trading_commission = company_profit
        spread_revenue = gross_comm - company_profit
        if spread_revenue < 0:
            spread_revenue = Decimal("0")
    except OperationalError:
        pass
    except Exception:
        pass

    net_revenue_simple = total_deposit - total_withdrawal
    net_revenue = net_revenue_simple + trading_commission + spread_revenue

    try:
        pm_base = PaymentGateway.objects.filter(
            visibility_status=PaymentGateway.VisibilityStatus.ACTIVE,
            is_active=True,
        ).order_by("display_order", "name")
        active_payment_methods_count = pm_base.count()
        active_payment_methods = [
            {
                "name": (g.name or "").strip() or g.code or "Method",
                "method": g.get_payment_method_display(),
                "code": g.code or "",
                "category": (g.category or "").strip(),
            }
            for g in pm_base[:50]
        ]
    except OperationalError:
        pass
    except Exception:
        pass

    return {
        "total_users": int(total_users),
        "active_users": int(active_users),
        "total_live_accounts": int(total_live_accounts),
        "total_demo_accounts": int(total_demo_accounts),
        "total_deposit": float(total_deposit),
        "total_withdrawal": float(total_withdrawal),
        "today_deposit": float(today_deposit),
        "today_withdrawal": float(today_withdrawal),
        "trading_commission": float(trading_commission),
        "spread_revenue": float(spread_revenue),
        "net_revenue": float(net_revenue_simple.quantize(Decimal("0.01"))),
        "net_revenue_with_trading": float(net_revenue.quantize(Decimal("0.01"))),
        "active_payment_methods_count": int(active_payment_methods_count),
        "active_payment_methods": active_payment_methods,
        "updated_at": timezone.now().isoformat(),
    }
