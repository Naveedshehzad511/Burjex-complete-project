"""
Sales manager KPI progress: deposits and volume (lots) for assigned clients only.
Volume uses CRM SimulatedIBTrade rows in the period; extend here when deal sync exists.
"""
from __future__ import annotations

import calendar
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any

from django.db.models import Sum
from django.utils import timezone

from accounts.models import User
from admin_panel.models import ManagerTarget, MatchTraderUserSnapshot, SimulatedIBTrade
from sales_panel.services.crm_scoping import clients_qs_for_sales_user
from transactions.models import Transaction


def get_active_manager_target(manager: User) -> ManagerTarget | None:
    if not (manager.is_sales_manager() or manager.is_account_manager()):
        return None
    return (
        ManagerTarget.objects.filter(manager=manager, is_active=True)
        .order_by("-created_at")
        .first()
    )


def period_datetime_bounds(mt: ManagerTarget, ref: datetime | None = None) -> tuple[datetime, datetime]:
    """Inclusive window in the active timezone for aggregations."""
    ref = ref or timezone.now()
    local = timezone.localtime(ref)
    tz = timezone.get_current_timezone()
    if mt.start_date and mt.end_date:
        start = timezone.make_aware(datetime.combine(mt.start_date, time.min), tz)
        end = timezone.make_aware(datetime.combine(mt.end_date, time.max.replace(microsecond=0)), tz)
        return start, end

    d = local.date()
    if mt.period == ManagerTarget.Period.DAILY:
        start_d = end_d = d
    elif mt.period == ManagerTarget.Period.WEEKLY:
        start_d = d - timedelta(days=d.weekday())
        end_d = start_d + timedelta(days=6)
    else:
        start_d = date(d.year, d.month, 1)
        end_d = date(d.year, d.month, calendar.monthrange(d.year, d.month)[1])

    start = timezone.make_aware(datetime.combine(start_d, time.min), tz)
    end = timezone.make_aware(datetime.combine(end_d, time.max.replace(microsecond=0)), tz)
    return start, end


def period_label(mt: ManagerTarget) -> str:
    if mt.period == ManagerTarget.Period.DAILY:
        return "Daily"
    if mt.period == ManagerTarget.Period.WEEKLY:
        return "Weekly"
    return "Monthly"


def _sum_deposits(client_ids: list[int], start: datetime, end: datetime) -> Decimal:
    if not client_ids:
        return Decimal("0")
    q = Transaction.objects.filter(
        actor_id__in=client_ids,
        tx_type__in=(
            Transaction.TxType.CLIENT_DEPOSIT,
            Transaction.TxType.WALLET_DEPOSIT,
        ),
        status__in=(Transaction.Status.COMPLETED, Transaction.Status.APPROVED),
        created_at__gte=start,
        created_at__lte=end,
    ).aggregate(s=Sum("amount"))
    return q["s"] if q["s"] is not None else Decimal("0")


def _lots_from_trade_history_item(item: dict) -> Decimal:
    if not isinstance(item, dict):
        return Decimal("0")
    for key in ("lots", "volume", "lot", "Volume", "Lots"):
        v = item.get(key)
        if v is None:
            continue
        try:
            return Decimal(str(v))
        except Exception:
            continue
    return Decimal("0")


def _sum_volume_from_snapshots(client_ids: list[int], start: datetime, end: datetime) -> Decimal:
    """Best-effort: sum lots-like fields in MatchTraderUserSnapshot.trade_history_json in window."""
    if not client_ids:
        return Decimal("0")
    total = Decimal("0")
    snaps = MatchTraderUserSnapshot.objects.filter(user_id__in=client_ids)
    for snap in snaps:
        hist = snap.trade_history_json or []
        if not isinstance(hist, list):
            continue
        for row in hist:
            if not isinstance(row, dict):
                continue
            ts_raw = row.get("time") or row.get("closeTime") or row.get("openTime") or row.get("timestamp")
            if ts_raw:
                try:
                    if isinstance(ts_raw, (int, float)):
                        tdt = datetime.utcfromtimestamp(float(ts_raw))
                        tdt = timezone.make_aware(tdt, timezone.utc)
                    else:
                        from django.utils.dateparse import parse_datetime

                        tdt = parse_datetime(str(ts_raw))
                        if tdt is None:
                            continue
                        if timezone.is_naive(tdt):
                            tdt = timezone.make_aware(tdt, timezone.utc)
                    if not (start <= tdt <= end):
                        continue
                except Exception:
                    continue
            total += _lots_from_trade_history_item(row)
    return total


def sum_volume_lots(client_ids: list[int], start: datetime, end: datetime) -> Decimal:
    if not client_ids:
        return Decimal("0")
    sim = (
        SimulatedIBTrade.objects.filter(
            client_id__in=client_ids,
            created_at__gte=start,
            created_at__lte=end,
        ).aggregate(s=Sum("lots"))
    )
    base = sim["s"] if sim["s"] is not None else Decimal("0")
    return base + _sum_volume_from_snapshots(client_ids, start, end)


def compute_manager_target_progress(
    manager: User,
    mt: ManagerTarget | None = None,
    ref: datetime | None = None,
    client_ids: list[int] | None = None,
) -> dict[str, Any]:
    """Serializable payload for templates and JSON API."""
    mt = mt or get_active_manager_target(manager)
    if not mt:
        return {
            "has_target": False,
            "ok": True,
        }

    if client_ids is None:
        if manager.is_account_manager():
            from admin_panel.models import ManagerAssignedClient

            client_ids = list(
                ManagerAssignedClient.objects.filter(manager_id=manager.pk).values_list("client_id", flat=True)
            )
        else:
            client_ids = list(clients_qs_for_sales_user(manager).values_list("id", flat=True))
    start, end = period_datetime_bounds(mt, ref)

    if mt.target_type == ManagerTarget.TargetType.DEPOSIT:
        current = _sum_deposits(client_ids, start, end)
        unit_label = "USD"
        display_current = f"${current:,.2f}"
        display_target = f"${mt.target_value:,.2f}"
    else:
        current = sum_volume_lots(client_ids, start, end)
        unit_label = "Lots"
        display_current = f"{current:,.4f}".rstrip("0").rstrip(".")
        display_target = f"{mt.target_value:,.4f}".rstrip("0").rstrip(".")

    target = mt.target_value
    if target <= 0:
        pct = Decimal("0")
    else:
        pct = min(Decimal("100"), (current / target) * Decimal("100"))
    pct_f = float(pct)
    achieved = current >= target if target > 0 else False
    remaining = max(Decimal("0"), target - current) if target > 0 else Decimal("0")

    if achieved or pct_f >= 100:
        bar_tier = "green"
    elif pct_f >= 70:
        bar_tier = "green"
    elif pct_f >= 40:
        bar_tier = "orange"
    else:
        bar_tier = "red"

    ls = timezone.localtime(start)
    le = timezone.localtime(end)
    range_str = f"{ls.strftime('%b %d, %Y')} – {le.strftime('%b %d, %Y')}"

    return {
        "ok": True,
        "has_target": True,
        "period_label": period_label(mt),
        "period_range": range_str,
        "target_type": mt.target_type,
        "target_type_display": "Volume" if mt.target_type == ManagerTarget.TargetType.VOLUME else "Deposit",
        "current": float(current),
        "target": float(target),
        "current_decimal": str(current),
        "target_decimal": str(target),
        "percent": round(pct_f, 2),
        "achieved": achieved,
        "remaining": float(remaining),
        "remaining_display": f"{remaining:,.2f}" if mt.target_type == ManagerTarget.TargetType.DEPOSIT else f"{remaining:,.4f}".rstrip("0").rstrip("."),
        "unit_label": unit_label,
        "display_current": display_current,
        "display_target": display_target,
        "bar_tier": bar_tier,
        "line_summary": (
            f"Deposit: {display_current} / {display_target}"
            if mt.target_type == ManagerTarget.TargetType.DEPOSIT
            else f"Volume: {display_current} / {display_target} Lots"
        ),
    }


def build_manager_target_dashboard_payload(manager: User) -> dict[str, Any]:
    return compute_manager_target_progress(manager)
