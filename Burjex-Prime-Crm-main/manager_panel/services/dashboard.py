"""Aggregates for account manager dashboard — scoped to assigned clients + portal permissions."""
from __future__ import annotations

from decimal import Decimal

from django.db.models import Sum

from accounts.models import User
from admin_panel.models import ManagerAssignedClient, ManagerPortalPermission, SimulatedIBTrade
from transactions.models import Transaction

_DEP_TYPES = (Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT)
_WDR_TYPES = (Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW)
_OK = (Transaction.Status.APPROVED, Transaction.Status.COMPLETED)


def assigned_client_ids(manager: User) -> list[int]:
    if not manager.is_account_manager():
        return []
    return list(
        ManagerAssignedClient.objects.filter(manager_id=manager.pk).values_list("client_id", flat=True)
    )


def get_portal_permissions(manager: User) -> ManagerPortalPermission | None:
    if not manager.is_account_manager():
        return None
    return ManagerPortalPermission.objects.filter(manager_id=manager.pk).first()


def _sum_deposits(client_ids: list[int]) -> Decimal:
    if not client_ids:
        return Decimal("0")
    r = (
        Transaction.objects.filter(
            actor_id__in=client_ids,
            tx_type__in=_DEP_TYPES,
            status__in=_OK,
            is_demo_ledger=False,
        ).aggregate(s=Sum("amount"))
    )
    return r["s"] if r["s"] is not None else Decimal("0")


def _sum_withdrawals(client_ids: list[int]) -> Decimal:
    if not client_ids:
        return Decimal("0")
    r = (
        Transaction.objects.filter(
            actor_id__in=client_ids,
            tx_type__in=_WDR_TYPES,
            status__in=_OK,
            is_demo_ledger=False,
        ).aggregate(s=Sum("amount"))
    )
    return r["s"] if r["s"] is not None else Decimal("0")


def _sum_volume_lots(client_ids: list[int]) -> Decimal:
    if not client_ids:
        return Decimal("0")
    r = SimulatedIBTrade.objects.filter(client_id__in=client_ids).aggregate(s=Sum("lots"))
    return r["s"] if r["s"] is not None else Decimal("0")


def _wallet_total(client_ids: list[int]) -> Decimal:
    if not client_ids:
        return Decimal("0")
    r = User.objects.filter(pk__in=client_ids).aggregate(s=Sum("wallet_balance"))
    return r["s"] if r["s"] is not None else Decimal("0")


def _per_client_deposits(client_ids: list[int]) -> dict[int, Decimal]:
    if not client_ids:
        return {}
    rows = (
        Transaction.objects.filter(
            actor_id__in=client_ids,
            tx_type__in=_DEP_TYPES,
            status__in=_OK,
            is_demo_ledger=False,
        )
        .values("actor_id")
        .annotate(s=Sum("amount"))
    )
    return {r["actor_id"]: r["s"] or Decimal("0") for r in rows}


def _per_client_withdrawals(client_ids: list[int]) -> dict[int, Decimal]:
    if not client_ids:
        return {}
    rows = (
        Transaction.objects.filter(
            actor_id__in=client_ids,
            tx_type__in=_WDR_TYPES,
            status__in=_OK,
            is_demo_ledger=False,
        )
        .values("actor_id")
        .annotate(s=Sum("amount"))
    )
    return {r["actor_id"]: r["s"] or Decimal("0") for r in rows}


def _per_client_volume(client_ids: list[int]) -> dict[int, Decimal]:
    if not client_ids:
        return {}
    rows = (
        SimulatedIBTrade.objects.filter(client_id__in=client_ids)
        .values("client_id")
        .annotate(s=Sum("lots"))
    )
    return {r["client_id"]: r["s"] or Decimal("0") for r in rows}


def build_manager_dashboard_context(manager: User) -> dict:
    """
    All sensitive figures are omitted when the matching permission flag is False
    or when the manager has no permission row (fail closed).
    """
    perms = get_portal_permissions(manager)
    cids = assigned_client_ids(manager)

    base = {
        "perm": perms,
        "assigned_client_count": len(cids),
        "total_deposit": None,
        "total_withdrawal": None,
        "total_volume_lots": None,
        "total_wallet": None,
        "client_rows": [],
        "recent_trades": [],
    }

    if not perms:
        return base

    if perms.view_deposit and cids:
        base["total_deposit"] = _sum_deposits(cids)
    if perms.view_withdrawal and cids:
        base["total_withdrawal"] = _sum_withdrawals(cids)
    if perms.view_volume and cids:
        base["total_volume_lots"] = _sum_volume_lots(cids)
    if perms.view_balance and cids:
        base["total_wallet"] = _wallet_total(cids)

    if perms.view_clients and cids:
        dep_map = _per_client_deposits(cids) if perms.view_deposit else {}
        wdr_map = _per_client_withdrawals(cids) if perms.view_withdrawal else {}
        vol_map = _per_client_volume(cids) if perms.view_volume else {}
        users = User.objects.filter(pk__in=cids).order_by("email")
        rows = []
        for u in users:
            row = {
                "user": u,
                "deposit": dep_map.get(u.pk) if perms.view_deposit else None,
                "withdrawal": wdr_map.get(u.pk) if perms.view_withdrawal else None,
                "volume": vol_map.get(u.pk) if perms.view_volume else None,
                "balance": (u.wallet_balance if perms.view_balance else None),
                "show_personal": perms.view_personal_info,
            }
            rows.append(row)
        base["client_rows"] = rows

    if perms.view_trades and cids:
        base["recent_trades"] = list(
            SimulatedIBTrade.objects.filter(client_id__in=cids)
            .select_related("client")
            .order_by("-created_at")[:50]
        )

    return base


def manager_dashboard_api_payload(manager: User) -> dict:
    """JSON-safe snapshot for polling; never includes data the manager cannot view."""
    ctx = build_manager_dashboard_context(manager)
    perms = ctx["perm"]
    out: dict = {
        "ok": True,
        "assigned_client_count": ctx["assigned_client_count"],
        "permissions": {},
    }
    if perms:
        out["permissions"] = {
            "view_clients": perms.view_clients,
            "view_deposit": perms.view_deposit,
            "view_withdrawal": perms.view_withdrawal,
            "view_volume": perms.view_volume,
            "view_balance": perms.view_balance,
            "view_trades": perms.view_trades,
            "view_personal_info": perms.view_personal_info,
        }
    if ctx["total_deposit"] is not None:
        out["total_deposit"] = float(ctx["total_deposit"])
    if ctx["total_withdrawal"] is not None:
        out["total_withdrawal"] = float(ctx["total_withdrawal"])
    if ctx["total_volume_lots"] is not None:
        out["total_volume_lots"] = float(ctx["total_volume_lots"])
    if ctx["total_wallet"] is not None:
        out["total_wallet"] = float(ctx["total_wallet"])
    return out
