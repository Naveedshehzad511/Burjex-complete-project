"""
Sales funnel metrics, stage classification, and list builders for the Sales CRM.
"""
from __future__ import annotations

from decimal import Decimal
from typing import Any

from django.db.models import Prefetch

from accounts.models import MT5Account, User
from sales_panel.services.crm_scoping import (
    clients_qs_for_sales_user,
    is_sales_scope,
    visitors_qs_for_sales_user,
)
from marketing.models import SalesFunnelContactLog, SalesFunnelProfile, SalesFunnelVisitor
from transactions.models import Transaction

STAGE_ORDER = ("visitors", "registered", "verified", "trading", "deposit", "active")

STAGE_LABELS: dict[str, str] = {
    "visitors": "Visitors",
    "registered": "Registered Clients",
    "verified": "Verified (KYC)",
    "trading": "Trading Account",
    "deposit": "First Deposit",
    "active": "Active Traders",
}


def _client_has_completed_deposit(user: User) -> bool:
    if user.ftd_user:
        return True
    return Transaction.objects.filter(
        actor=user,
        tx_type__in=(
            Transaction.TxType.CLIENT_DEPOSIT,
            Transaction.TxType.WALLET_DEPOSIT,
        ),
        status=Transaction.Status.COMPLETED,
    ).exists()


def compute_client_stage(user: User) -> str | None:
    if user.role != User.Roles.CLIENT:
        return None
    live_accounts = [a for a in user.mt5_accounts.all() if a.account_type == MT5Account.AccountType.LIVE]
    has_live = bool(live_accounts)
    active_live = any(
        a.status == MT5Account.Status.ACTIVE and a.trading_enabled for a in live_accounts
    )
    has_dep = _client_has_completed_deposit(user)

    if has_dep and active_live:
        return "active"
    if has_dep:
        return "deposit"
    if has_live:
        return "trading"
    if user.kyc_status == User.KYCStatus.APPROVED:
        return "verified"
    return "registered"


def client_is_dropped(user: User) -> bool:
    profile = getattr(user, "sales_funnel_profile", None)
    return bool(profile and profile.is_dropped)


def get_or_create_funnel_profile(user: User) -> SalesFunnelProfile:
    profile, _ = SalesFunnelProfile.objects.get_or_create(user=user)
    return profile


def _prefetch_clients_qs():
    return (
        User.objects.filter(role=User.Roles.CLIENT)
        .select_related("sales_funnel_profile")
        .prefetch_related(
            Prefetch(
                "mt5_accounts",
                queryset=MT5Account.objects.all(),
            )
        )
        .order_by("-date_joined")
    )


def classify_clients_by_stage(client_qs=None) -> dict[str, list[User]]:
    buckets = {k: [] for k in STAGE_ORDER if k != "visitors"}
    qs = client_qs if client_qs is not None else _prefetch_clients_qs()
    for user in qs:
        stage = compute_client_stage(user)
        if stage and stage in buckets and not client_is_dropped(user):
            buckets[stage].append(user)
    return buckets


def funnel_counts_and_profit(sales_user: User | None = None) -> tuple[list[int], list[Decimal], int, int]:
    """
    Returns (counts per STAGE_ORDER), (profit potential per stage), dropped_visitors, dropped_clients.

    When ``sales_user`` is a sales manager, visitors and clients are limited to their book (same rules as
    ``get_stage_list``). Other roles see the full funnel (``is_sales_scope`` is false).
    """
    if sales_user and is_sales_scope(sales_user):
        visitors_base = visitors_qs_for_sales_user(sales_user)
        visitors_active = visitors_base.filter(converted_user__isnull=True, is_dropped=False)
        v_drop = visitors_base.filter(converted_user__isnull=True, is_dropped=True).count()
        client_qs = clients_qs_for_sales_user(sales_user).select_related("sales_funnel_profile").prefetch_related(
            Prefetch("mt5_accounts", queryset=MT5Account.objects.all())
        )
        buckets = classify_clients_by_stage(client_qs)
        c_drop = clients_qs_for_sales_user(sales_user).filter(sales_funnel_profile__is_dropped=True).count()
    else:
        visitors_active = SalesFunnelVisitor.objects.filter(converted_user__isnull=True, is_dropped=False)
        v_drop = SalesFunnelVisitor.objects.filter(converted_user__isnull=True, is_dropped=True).count()
        buckets = classify_clients_by_stage()
        c_drop = User.objects.filter(role=User.Roles.CLIENT, sales_funnel_profile__is_dropped=True).count()

    v_profit = sum((x.profit_potential_usd for x in visitors_active), start=Decimal("0"))

    counts = [
        visitors_active.count(),
        len(buckets["registered"]),
        len(buckets["verified"]),
        len(buckets["trading"]),
        len(buckets["deposit"]),
        len(buckets["active"]),
    ]

    profit_rows: list[Decimal] = [v_profit]
    for stage in ("registered", "verified", "trading", "deposit", "active"):
        total = Decimal("0")
        for u in buckets[stage]:
            profile = getattr(u, "sales_funnel_profile", None)
            if profile:
                total += profile.estimated_profit_potential_usd
            else:
                total += Decimal("5000")
        profit_rows.append(total)

    return counts, profit_rows, v_drop, c_drop


def build_funnel_cards(sales_user: User | None = None) -> list[dict[str, Any]]:
    counts, profits, _, _ = funnel_counts_and_profit(sales_user=sales_user)
    cards = []
    n = len(STAGE_ORDER)
    for i, key in enumerate(STAGE_ORDER):
        prev_count = counts[i - 1] if i > 0 else None
        to_next = None
        if i < n - 1 and counts[i] > 0:
            to_next = round(100.0 * counts[i + 1] / counts[i], 2)
        from_prev = None
        if prev_count is not None and prev_count > 0:
            from_prev = round(100.0 * counts[i] / prev_count, 2)
        cards.append(
            {
                "key": key,
                "title": STAGE_LABELS[key],
                "count": counts[i],
                "profit_potential": profits[i],
                "conversion_from_prev": from_prev,
                "conversion_to_next": to_next,
            }
        )
    return cards


def recent_contact_logs(limit: int = 40, sales_user: User | None = None) -> list[SalesFunnelContactLog]:
    from sales_panel.services.crm_scoping import contact_logs_qs_for_sales_user, is_sales_scope

    qs = SalesFunnelContactLog.objects.select_related("created_by", "visitor", "client").order_by("-created_at")
    if sales_user and is_sales_scope(sales_user):
        qs = contact_logs_qs_for_sales_user(sales_user).select_related("created_by", "visitor", "client").order_by(
            "-created_at"
        )
    return list(qs[:limit])


def get_stage_list(stage_key: str, sales_user: User | None = None) -> tuple[list[Any], str]:
    """Return rows for stage detail template and stage title."""
    from sales_panel.services.crm_scoping import is_sales_scope, visitors_qs_for_sales_user

    if stage_key not in STAGE_ORDER:
        return [], ""
    title = STAGE_LABELS.get(stage_key, stage_key)
    if stage_key == "visitors":
        qs = SalesFunnelVisitor.objects.filter(converted_user__isnull=True).select_related(
            "assigned_manager", "assigned_agent", "last_contacted_by"
        )
        if sales_user and is_sales_scope(sales_user):
            qs = visitors_qs_for_sales_user(sales_user).filter(converted_user__isnull=True).select_related(
                "assigned_manager", "assigned_agent", "last_contacted_by"
            )
        return list(qs.order_by("-created_at")[:500]), title

    client_qs = None
    if sales_user and is_sales_scope(sales_user):
        from sales_panel.services.crm_scoping import clients_qs_for_sales_user

        client_qs = clients_qs_for_sales_user(sales_user).select_related("sales_funnel_profile").prefetch_related(
            Prefetch("mt5_accounts", queryset=MT5Account.objects.all())
        )
    buckets = classify_clients_by_stage(client_qs)
    users = buckets.get(stage_key, [])
    return users, title


def row_tone_for_stage(stage_key: str, is_dropped: bool) -> str:
    if is_dropped:
        return "dropped"
    if stage_key in ("deposit", "active"):
        return "complete"
    return "pending"
