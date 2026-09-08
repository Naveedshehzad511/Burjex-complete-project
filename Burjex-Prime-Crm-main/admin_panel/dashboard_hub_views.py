"""Dashboard 'View more' hub pages: tabs, filters, and live aggregates."""
from __future__ import annotations

import csv
from datetime import timedelta
from urllib.parse import urlencode

from django.contrib.auth.decorators import login_required
from django.core.paginator import Paginator
from django.db.models import Q, Sum
from django.http import HttpResponse
from django.shortcuts import render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import MT5Account, User
from accounts.permissions import role_required

from transactions.models import Transaction

from .dashboard_metrics import get_admin_dashboard_live_metrics


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def hub_users_activity(request):
    """Tabs: Active (30d login) vs Inactive — deep-link to user list with filters."""
    m = get_admin_dashboard_live_metrics()
    active_url = f"{reverse('admin-user-list')}?engagement=active_30d&list_scope=all"
    inactive_url = f"{reverse('admin-user-list')}?engagement=inactive_30d&list_scope=all"
    return render(
        request,
        "admin_panel/dashboard_hub/users_activity.html",
        {
            "title": "User activity",
            "active_count": m["active_users_30d"],
            "inactive_count": m["inactive_users_30d"],
            "active_url": active_url,
            "inactive_url": inactive_url,
            "all_users_url": f"{reverse('admin-user-list')}?list_scope=all",
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def hub_deposits(request):
    period = (request.GET.get("period") or "all").strip().lower()
    if period not in {"all", "today", "week"}:
        period = "all"
    today = timezone.localdate()
    week_from = today - timedelta(days=6)

    def _u(tab: str) -> str:
        q = f"type=deposit&status_group={tab}&period={period}"
        if period == "today":
            q += f"&from={today.isoformat()}&to={today.isoformat()}"
        elif period == "week":
            q += f"&from={week_from.isoformat()}&to={today.isoformat()}"
        return f"{reverse('admin-payment-requests')}?{q}"

    return render(
        request,
        "admin_panel/dashboard_hub/deposits_hub.html",
        {
            "title": "Deposits",
            "period": period,
            "approved_url": _u("approved"),
            "rejected_url": _u("rejected"),
            "today": today,
            "week_from": week_from,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def hub_withdrawals(request):
    period = (request.GET.get("period") or "all").strip().lower()
    if period not in {"all", "today", "week"}:
        period = "all"
    today = timezone.localdate()
    week_from = today - timedelta(days=6)

    def _u(tab: str) -> str:
        q = f"type=withdraw&status_group={tab}&period={period}"
        if period == "today":
            q += f"&from={today.isoformat()}&to={today.isoformat()}"
        elif period == "week":
            q += f"&from={week_from.isoformat()}&to={today.isoformat()}"
        return f"{reverse('admin-payment-requests')}?{q}"

    return render(
        request,
        "admin_panel/dashboard_hub/withdrawals_hub.html",
        {
            "title": "Withdrawals",
            "period": period,
            "approved_url": _u("approved"),
            "rejected_url": _u("rejected"),
            "today": today,
            "week_from": week_from,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def hub_net_revenue(request):
    from_str = (request.GET.get("from") or "").strip()
    to_str = (request.GET.get("to") or "").strip()
    export = (request.GET.get("export") or "").strip().lower()

    dep_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    wdr_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
    ok = [Transaction.Status.APPROVED, Transaction.Status.COMPLETED]

    dep_qs = Transaction.objects.filter(tx_type__in=dep_types, status__in=ok, is_demo_ledger=False)
    wdr_qs = Transaction.objects.filter(tx_type__in=wdr_types, status__in=ok, is_demo_ledger=False)

    if from_str:
        dep_qs = dep_qs.filter(created_at__date__gte=from_str)
        wdr_qs = wdr_qs.filter(created_at__date__gte=from_str)
    if to_str:
        dep_qs = dep_qs.filter(created_at__date__lte=to_str)
        wdr_qs = wdr_qs.filter(created_at__date__lte=to_str)

    total_dep = float(dep_qs.aggregate(t=Sum("amount"))["t"] or 0)
    total_wdr = float(wdr_qs.aggregate(t=Sum("amount"))["t"] or 0)
    net = total_dep - total_wdr

    if export == "csv":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="net_revenue_summary.csv"'
        w = csv.writer(response)
        w.writerow(["Metric", "Amount"])
        w.writerow(["Total deposits (approved)", f"{total_dep:.2f}"])
        w.writerow(["Total withdrawals (approved)", f"{total_wdr:.2f}"])
        w.writerow(["Net revenue", f"{net:.2f}"])
        return response

    combined = (
        Transaction.objects.filter(
            Q(tx_type__in=dep_types) | Q(tx_type__in=wdr_types),
            status__in=ok,
            is_demo_ledger=False,
        )
        .select_related("actor", "payment_gateway")
        .order_by("-created_at")
    )
    if from_str:
        combined = combined.filter(created_at__date__gte=from_str)
    if to_str:
        combined = combined.filter(created_at__date__lte=to_str)

    paginator = Paginator(combined, 25)
    page_obj = paginator.get_page(request.GET.get("page"))

    export_params = {k: v for k, v in (("from", from_str), ("to", to_str), ("export", "csv")) if v}
    export_csv_url = f"{reverse('admin-hub-net-revenue')}?{urlencode(export_params)}"

    return render(
        request,
        "admin_panel/dashboard_hub/net_revenue.html",
        {
            "title": "Net revenue",
            "total_dep": total_dep,
            "total_wdr": total_wdr,
            "net": net,
            "from_str": from_str,
            "to_str": to_str,
            "page_obj": page_obj,
            "export_csv_url": export_csv_url,
            "report_transactions_url": reverse("admin-report-transactions"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def hub_mt5_accounts(request):
    acct = (request.GET.get("account_type") or "live").strip().lower()
    if acct not in {"live", "demo"}:
        acct = "live"
    q = (request.GET.get("q") or "").strip()
    export = (request.GET.get("export") or "").strip().lower()

    # Best-effort live pull so admin balance/equity match BTrader engine.
    try:
        from btrader_integration.services import is_btrader_configured, sync_all_btrader_accounts

        if is_btrader_configured():
            sync_all_btrader_accounts()
    except Exception:
        pass

    qs = MT5Account.objects.select_related("user", "group").order_by("-updated_at")
    if acct == "live":
        qs = qs.filter(account_type=MT5Account.AccountType.LIVE)
    else:
        qs = qs.filter(account_type=MT5Account.AccountType.DEMO)
    if q:
        qs = qs.filter(Q(login_id__icontains=q) | Q(user__email__icontains=q) | Q(user__username__icontains=q))

    if export == "csv":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = f'attachment; filename="mt5_{acct}_accounts.csv"'
        w = csv.writer(response)
        w.writerow(["Login", "User", "Email", "Server", "Balance", "Equity", "Free Margin", "Type", "Status", "Updated"])
        for row in qs[:5000]:
            w.writerow(
                [
                    row.login_id,
                    row.user.display_name() if row.user_id else "",
                    row.user.email if row.user_id else "",
                    row.server or "",
                    float(row.balance or 0),
                    float(row.equity or 0),
                    float(row.free_margin or 0),
                    row.get_account_type_display(),
                    row.get_status_display(),
                    timezone.localtime(row.updated_at).strftime("%Y-%m-%d %H:%M") if row.updated_at else "",
                ]
            )
        return response

    paginator = Paginator(qs, 25)
    page_obj = paginator.get_page(request.GET.get("page"))

    return render(
        request,
        "admin_panel/dashboard_hub/mt5_accounts.html",
        {
            "title": "MT5 accounts" if acct == "live" else "Demo MT5 accounts",
            "account_type": acct,
            "q": q,
            "page_obj": page_obj,
        },
    )
