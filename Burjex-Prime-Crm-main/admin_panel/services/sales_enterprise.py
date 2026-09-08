"""Sales portal enterprise metrics (IB, revenue hub, team rollups)."""

from __future__ import annotations

from datetime import datetime

from django.http import HttpResponse

from accounts.models import User
from admin_panel.services.metrics import get_admin_dashboard_metrics
from ib.models import IBProfile


def _parse_range(request):
    f = (request.GET.get("from") or "").strip()
    t = (request.GET.get("to") or "").strip()
    fd = td = None
    try:
        if f:
            fd = datetime.strptime(f, "%Y-%m-%d").date()
        if t:
            td = datetime.strptime(t, "%Y-%m-%d").date()
    except ValueError:
        fd = td = None
    return fd, td


def get_sales_main_context(request) -> dict:
    fd, td = _parse_range(request)
    m = get_admin_dashboard_metrics(fd, td)
    dep = m.get("deposits_vs_withdrawals_toggle_data", {}).get("daily") or {}
    labels = dep.get("labels") or ["—"]
    deposits = dep.get("deposits") or [0] * len(labels)
    withdrawals = dep.get("withdrawals") or [0] * len(labels)
    netdaily = (m.get("net_revenue_toggle_data") or {}).get("daily", {}).get("values") or [0] * len(labels)
    if len(netdaily) < len(labels):
        netdaily = list(netdaily) + [0] * (len(labels) - len(netdaily))
    vol = [round(float(d) + float(w), 2) for d, w in zip(deposits, withdrawals)]
    ib_wd = m.get("ib_withdraw_period_values") or [0, 0, 0]
    ib_xfer = m.get("ib_transfer_request_period_values") or [0, 0, 0]
    ib_labels = ["Daily", "Weekly", "Monthly"]
    return {
        "sales_date_from": fd.isoformat() if fd else "",
        "sales_date_to": td.isoformat() if td else "",
        "kpi_total_revenue": float(m.get("main_real_total_deposit") or 0),
        "kpi_total_loss": float(m.get("main_real_total_withdrawal") or 0),
        "kpi_net_profit": float(m.get("main_real_net_revenue") or 0),
        "kpi_net_positive": float(m.get("main_real_net_revenue") or 0) >= 0,
        "kpi_trading_volume": float(m.get("trading_volume") or 0),
        "kpi_active_ibs": int(m.get("dashboard_total_ib") or 0),
        "kpi_total_clients": int(m.get("headline_total_clients") or m.get("total_clients") or 0),
        "pending_orange": {
            "deposits": int(m.get("pending_deposit_global") or 0),
            "withdrawals": int(m.get("pending_withdraw_global") or 0),
            "ib_requests": int(m.get("pending_ib_requests_queue") or 0),
        },
        "chart_revenue_dw": {
            "labels": labels,
            "deposits": [float(x) for x in deposits],
            "withdrawals": [float(x) for x in withdrawals],
        },
        "chart_volume": {"labels": labels, "values": vol},
        "chart_net": {"labels": labels, "values": [float(x) for x in netdaily[: len(labels)]]},
        "chart_ib": {
            "labels": ib_labels,
            "withdrawals": [float(ib_wd[i]) for i in range(min(3, len(ib_wd)))],
            "transfers": [float(ib_xfer[i]) for i in range(min(3, len(ib_xfer)))],
        },
    }


def get_ib_analytics_context(request) -> dict:
    rows = []
    for p in IBProfile.objects.select_related("user").order_by("-created_at")[:200]:
        u = p.user
        rows.append({"ib": p, "user": u, "email": u.email, "code": p.ib_code})
    return {"ib_rows": rows, "rows": rows}


def get_ib_detail_context(ib_id: int, request) -> dict | None:
    p = IBProfile.objects.filter(user_id=ib_id).select_related("user").first()
    if not p:
        return None
    return {"ib_profile": p, "user": p.user, "ib_user": p.user}


def export_ib_detail_csv(ib_id: int, request):
    ctx = get_ib_detail_context(ib_id, request)
    if not ctx:
        return None
    resp = HttpResponse("email,ib_code\n", content_type="text/csv; charset=utf-8")
    resp["Content-Disposition"] = f'attachment; filename="ib_sales_{ib_id}.csv"'
    u = ctx["user"]
    resp.write(f"{u.email},{ctx['ib_profile'].ib_code}\n")
    return resp


def get_sales_team_context(request) -> dict:
    m = get_admin_dashboard_metrics()
    return {
        "manager_performance": m.get("manager_performance") or [],
        "metrics": m,
    }
