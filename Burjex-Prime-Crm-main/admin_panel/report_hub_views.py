from django.contrib.auth.decorators import login_required
from django.shortcuts import render

from accounts.models import User
from accounts.permissions import role_required


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def reports_dashboard(request):
    cards = [
        {
            "title": "Deposit Report",
            "description": "Review deposit requests and deposit activity.",
            "icon": "fa-money-bill-trend-up",
            "url_name": "admin-report-deposit",
            "query": "type=deposit",
            "color": "#10b981",
        },
        {
            "title": "Withdrawal Report",
            "description": "Review withdrawal requests and withdrawal activity.",
            "icon": "fa-money-bill-transfer",
            "url_name": "admin-report-withdrawal",
            "query": "type=withdraw",
            "color": "#f43f5e",
        },
        {
            "title": "IB Commission Report",
            "description": "Open settled and pending IB commission records.",
            "icon": "fa-sack-dollar",
            "url_name": "admin-report-ib-commission",
            "color": "#f59e0b",
        },
        {
            "title": "Transaction Report",
            "description": "Track all wallet and transaction history.",
            "icon": "fa-receipt",
            "url_name": "admin-report-transactions",
            "color": "#3b82f6",
        },
        {
            "title": "Client Report",
            "description": "Open the client list with reporting filters.",
            "icon": "fa-users",
            "url_name": "admin-report-clients",
            "color": "#6366f1",
        },
        {
            "title": "Active Traders Report",
            "description": "Review currently active trading clients.",
            "icon": "fa-user-check",
            "url_name": "admin-report-active-traders",
            "color": "#8b5cf6",
        },
        {
            "title": "IB Performance Report",
            "description": "Analyze IB referral and performance activity.",
            "icon": "fa-chart-line",
            "url_name": "admin-report-ib-performance",
            "color": "#14b8a6",
        },
        {
            "title": "IB Withdrawal Report",
            "description": "Review IB withdrawal activity.",
            "icon": "fa-hand-holding-dollar",
            "url_name": "admin-report-ib-withdrawal",
            "color": "#ec4899",
        },
        {
            "title": "IB Clients Report",
            "description": "Open IB client relationships and referral data.",
            "icon": "fa-people-group",
            "url_name": "admin-report-ib-clients",
            "color": "#0ea5e9",
        },
        {
            "title": "Trading Volume Report",
            "description": "Review trading volume reporting.",
            "icon": "fa-chart-simple",
            "url_name": "admin-report-trading-volume",
            "color": "#eab308",
        },
        {
            "title": "Account Report",
            "description": "Open trading account report details.",
            "icon": "fa-id-card",
            "url_name": "admin-report-account",
            "color": "#f97316",
        },
        {
            "title": "MT5 Trading Report",
            "description": "Review MT5 open positions and trading records.",
            "icon": "fa-chart-area",
            "url_name": "admin-report-mt5-trading",
            "color": "#0B3C5D",
        },
    ]
    return render(request, "admin_panel/reports_dashboard.html", {"cards": cards})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def analytics_dashboard(request):
    cards = [
        {
            "title": "Client Analytics",
            "description": "Open client growth and engagement analytics.",
            "icon": "fa-users",
            "url_name": "admin-analytics-clients",
        },
        {
            "title": "Deposit Analytics",
            "description": "Review deposit trends and volume insights.",
            "icon": "fa-arrow-trend-up",
            "url_name": "admin-analytics-deposits",
        },
        {
            "title": "Withdrawal Analytics",
            "description": "Review withdrawal trends and outflow insights.",
            "icon": "fa-arrow-trend-down",
            "url_name": "admin-analytics-withdrawals",
        },
        {
            "title": "IB Analytics",
            "description": "Analyze IB network performance and referrals.",
            "icon": "fa-handshake",
            "url_name": "admin-analytics-ib",
        },
        {
            "title": "Revenue Analytics",
            "description": "Open revenue trends and transaction analysis.",
            "icon": "fa-chart-pie",
            "url_name": "admin-analytics-revenue",
        },
    ]
    return render(request, "admin_panel/analytics_dashboard.html", {"cards": cards})

from django.db.models import Sum, Count
from transactions.models import Transaction

# Color palette for charts
CHART_COLORS = [
    "#0B3C5D", "#328CC1", "#D9B310", "#98B4D4", 
    "#1D2731", "#0B3C5D", "#4B86B4", "#2A3132",
    "#336B87", "#90AFC5", "#763626", "#C4DFE6",
]

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def analytics_clients(request):
    qs = User.objects.filter(role=User.Roles.CLIENT).values("country").annotate(total=Count("id")).order_by("-total")
    
    labels = []
    data = []
    for item in qs:
        country = item["country"] or "Unknown"
        labels.append(country)
        data.append(item["total"])
        
    return render(request, "admin_panel/analytics_chart.html", {
        "title": "Client Analytics",
        "labels": labels,
        "data": data,
        "colors": CHART_COLORS[:len(labels)],
        "chart_items": [{"label": l, "value": d, "color": c} for l, d, c in zip(labels, data, CHART_COLORS[:len(labels)])],
    })

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def analytics_deposits(request):
    qs = Transaction.objects.filter(tx_type=Transaction.TxType.CLIENT_DEPOSIT, status=Transaction.Status.APPROVED).values("actor__country").annotate(total=Sum("amount")).order_by("-total")
    
    labels = []
    data = []
    for item in qs:
        country = item["actor__country"] or "Unknown"
        labels.append(country)
        data.append(float(item["total"] or 0))
        
    return render(request, "admin_panel/analytics_chart.html", {
        "title": "Deposit Analytics",
        "labels": labels,
        "data": data,
        "colors": CHART_COLORS[:len(labels)],
        "chart_items": [{"label": l, "value": d, "color": c} for l, d, c in zip(labels, data, CHART_COLORS[:len(labels)])],
    })

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def analytics_withdrawals(request):
    qs = Transaction.objects.filter(tx_type=Transaction.TxType.CLIENT_WITHDRAW, status=Transaction.Status.APPROVED).values("actor__country").annotate(total=Sum("amount")).order_by("-total")
    
    labels = []
    data = []
    for item in qs:
        country = item["actor__country"] or "Unknown"
        labels.append(country)
        data.append(float(item["total"] or 0))
        
    return render(request, "admin_panel/analytics_chart.html", {
        "title": "Withdrawal Analytics",
        "labels": labels,
        "data": data,
        "colors": CHART_COLORS[:len(labels)],
        "chart_items": [{"label": l, "value": d, "color": c} for l, d, c in zip(labels, data, CHART_COLORS[:len(labels)])],
    })

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def analytics_revenue(request):
    deposits = Transaction.objects.filter(tx_type=Transaction.TxType.CLIENT_DEPOSIT, status=Transaction.Status.APPROVED).values("actor__country").annotate(total=Sum("amount"))
    withdrawals = Transaction.objects.filter(tx_type=Transaction.TxType.CLIENT_WITHDRAW, status=Transaction.Status.APPROVED).values("actor__country").annotate(total=Sum("amount"))
    
    revenue_dict = {}
    for item in deposits:
        country = item["actor__country"] or "Unknown"
        revenue_dict[country] = float(item["total"] or 0)
        
    for item in withdrawals:
        country = item["actor__country"] or "Unknown"
        revenue_dict[country] = revenue_dict.get(country, 0) - float(item["total"] or 0)
        
    labels = []
    data = []
    for country, total in sorted(revenue_dict.items(), key=lambda x: x[1], reverse=True):
        labels.append(country)
        data.append(total)
        
    return render(request, "admin_panel/analytics_chart.html", {
        "title": "Revenue Analytics",
        "labels": labels,
        "data": data,
        "colors": CHART_COLORS[:len(labels)],
        "chart_items": [{"label": l, "value": d, "color": c} for l, d, c in zip(labels, data, CHART_COLORS[:len(labels)])],
    })
