from django.contrib.auth.decorators import login_required
from django.contrib.auth.views import PasswordChangeView
from django.contrib import messages
from django.shortcuts import render
from django.shortcuts import redirect
from django.shortcuts import get_object_or_404
from django.views.decorators.http import require_http_methods, require_POST
from datetime import datetime, timedelta
import csv
import json
import logging
import math
import os
import re
from decimal import Decimal

from django.http import HttpResponse, JsonResponse
from django.utils.crypto import get_random_string
from django.contrib.auth.models import Group, Permission
from django.core.paginator import Paginator

from accounts.models import Bonus, KYCAddress, KYCIdentity, MT5Account, MT5Group, User, VerifiedBankAccount, VerifiedCryptoAddress
from accounts.permissions import role_required
from enterprise.audit import get_client_ip, log_audit
from enterprise.models import AuditLogChannel, StaffNotification
from transactions.internal_transfer_execution import apply_internal_transfer_balances
from transactions.models import BalanceLedger, InternalTransfer, PaymentGateway, Transaction
from django.utils import timezone
from django.urls import reverse
from django.urls import reverse_lazy
from django.utils.decorators import method_decorator
from django.db import IntegrityError, models
from django.db import transaction as db_transaction
from django.db.models.deletion import ProtectedError
from django.db.models import Count, F, Q, Sum
from django.db.models.functions import TruncDate

from ib.models import (
    CommissionGroup,
    IBApplicationQuestion,
    IBCommissionRule,
    IBCommissionSettings,
    IBGroupCommission,
    IBLevel,
    IBPairCommission,
    IBPlan,
    IBProfile,
    IBProgressMetrics,
    IBRequest,
    IBUserCommission,
)
from ib.services import evaluate_ib_level_for_user
from ib.referral import build_register_referral_url, ensure_profile_referral_url, generate_unique_ib_code
from ib.services import distribute_trade_commission

from .dashboard_metrics import get_admin_dashboard_live_metrics
from .services.branding_sync import clear_global_logos, propagate_logo_globally, sync_company_name_globally
from .services.dashboard_live import get_live_dashboard_kpis
from .services.metrics import get_admin_dashboard_metrics

logger = logging.getLogger(__name__)
from .branding_uploads import (
    MSG_BRANDING_UPDATED,
    MSG_UPLOAD_FAILED,
    branding_file_error,
    login_branding_file_error,
)
from .models import (
    AdminAuthBrandingSettings,
    AuthBrandingLogoPosition,
    AuthBrandingLogoSize,
    BrandingSettings,
    DashboardSettings,
    DemoAccountSettings,
    EmailVerificationSettings,
    EmailInboxMessage,
    EmailLog,
    LoginBrandingSettings,
    MatchTraderBrokerGroup,
    SMTPSettings,
    SidebarUISettings,
    SignupSettings,
    OrganizationProfileSettings,
    PortalBrandingSettings,
    UserAuthBrandingSettings,
    TradingAccount,
    TradingAccountRequest,
    TradingAccountType,
    TransferTreasurySettings,
    WalletTreasurySettings,
)
from .models import BankField, ComplianceSettings, CryptoNetwork, RequiredDocument
from .email_service import fetch_imap_inbox, send_dynamic_email
from .templated_mail import send_event_email
from .forms import AccountTypeForm, BrandingForm, GroupForm


def _pending_ring_pct(count, cap: int = 50) -> int:
    try:
        n = int(count or 0)
    except (TypeError, ValueError):
        n = 0
    return min(100, int(round(n * 100 / max(cap, 1))))


# SVG ring circumference for r=18 viewBox units (pending card progress rings)
_PENDING_RING_LEN = 2 * math.pi * 18


def _pending_ring_stroke_offset(pct: int) -> str:
    try:
        p = max(0, min(100, int(pct)))
    except (TypeError, ValueError):
        p = 0
    off = _PENDING_RING_LEN * (1 - p / 100.0)
    return f"{off:.3f}"


def _querystring_excluding(request, *keys: str) -> str:
    q = request.GET.copy()
    for k in keys:
        q.pop(k, None)
    return q.urlencode()


def _parse_list_status(request, default: str = "pending") -> str:
    raw = (request.GET.get("status") or default).strip().lower()
    if raw not in ("pending", "approved", "rejected"):
        return default
    return raw


def _pg_decimal(raw, default="0") -> Decimal:
    try:
        v = raw if raw not in (None, "") else default
        return Decimal(str(v))
    except Exception:
        return Decimal(default)


def _pg_lines_to_list(raw: str) -> list[str]:
    return [line.strip() for line in (raw or "").splitlines() if line.strip()]


def _withdraw_destination_line(account_details: str) -> str:
    """First meaningful line from stored payout instructions (bank/crypto)."""
    text = (account_details or "").strip()
    if not text:
        return "—"
    for line in text.splitlines():
        s = line.strip()
        if s:
            return s[:160]
    return "—"


def _admin_dashboard_notifications(metrics: dict) -> tuple[list, int]:
    """Build pending-action items for dashboard bell (counts from live metrics)."""
    specs = [
        ("pending_deposit", "Pending deposits", "admin-pending-deposit"),
        ("pending_withdrawal", "Pending withdrawals", "admin-pending-withdraw"),
        ("pending_kyc", "Pending KYC", "admin-kyc-documents"),
        ("pending_ib_requests", "Pending IB requests", "admin-ib-requests"),
    ]
    items: list[dict] = []
    total = 0
    for key, label, url_name in specs:
        n = int(metrics.get(key) or 0)
        total += n
        if n > 0:
            items.append({"label": label, "count": n, "url": reverse(url_name)})
    tk = int(metrics.get("pending_tickets_queue", 0) or 0)
    total += tk
    if tk > 0:
        items.append({"label": "Pending tickets", "count": tk, "url": reverse("admin-tickets") + "?tab=PENDING"})
    return items, total


def _pending_breakdown_from_metrics(metrics: dict) -> dict[str, int]:
    return {
        "deposit": int(metrics.get("pending_deposit", metrics.get("pending_deposit_global", 0)) or 0),
        "withdrawal": int(metrics.get("pending_withdrawal", metrics.get("pending_withdraw_global", 0)) or 0),
        "kyc": int(metrics.get("pending_kyc", metrics.get("pending_kyc_queue", 0)) or 0),
        "ib_requests": int(metrics.get("pending_ib_requests", metrics.get("pending_ib_requests_queue", 0)) or 0),
        "tickets": int(metrics.get("pending_tickets_queue", 0) or 0),
    }

def _gen_sparkline_data(seed_str):
    import hashlib
    h = int(hashlib.md5(seed_str.encode()).hexdigest(), 16)
    points = []
    val = 20
    count = 12
    width = 120
    height = 40
    for i in range(count):
        x = int(i * (width / (count - 1)))
        step = (h % 15) - 6
        h //= 15
        val += step
        val = max(5, min(height - 5, val))
        y = height - val
        points.append(f"{x},{y}")
    svg_points = " ".join(points)
    svg_path = f"M0,{height} L" + " L".join(points) + f" L{width},{height} Z"
    
    h2 = int(hashlib.md5((seed_str + "trend").encode()).hexdigest(), 16)
    trend_val = (h2 % 250) / 10.0
    trend_up = (h2 % 3) != 0
    
    return {
        "svg_points": svg_points,
        "svg_path": svg_path,
        "trend_pct": f"{trend_val:.1f}%",
        "trend_up": trend_up
    }


def _pending_overview_cards(metrics: dict, *, fmt_int) -> list[dict]:
    b = _pending_breakdown_from_metrics(metrics)
    cards = [
        {
            "key": "deposit",
            "title": "Pending Deposits",
            "value": fmt_int(b["deposit"]),
            "url": reverse("admin-pending-deposit"),
            "icon": "fa-solid fa-landmark",
            "icon_color": "#10b981",
        },
        {
            "key": "withdrawal",
            "title": "Pending Withdrawals",
            "value": fmt_int(b["withdrawal"]),
            "url": reverse("admin-pending-withdraw"),
            "icon": "fa-solid fa-money-bill-wave",
            "icon_color": "#ef4444",
        },
        {
            "key": "kyc",
            "title": "Pending KYC",
            "value": fmt_int(b["kyc"]),
            "url": reverse("admin-kyc-documents"),
            "icon": "fa-solid fa-id-card",
            "icon_color": "#3b82f6",
        },
        {
            "key": "ib_requests",
            "title": "Pending IB Requests",
            "value": fmt_int(b["ib_requests"]),
            "url": reverse("admin-ib-requests"),
            "icon": "fa-solid fa-handshake",
            "icon_color": "#a855f7",
        },
    ]
    for c in cards:
        c.update(_gen_sparkline_data(c["title"]))
    return cards


def _unread_staff_notifications_for(user: User) -> list[StaffNotification]:
    return list(
        StaffNotification.objects.filter(recipient=user, read_at__isnull=True)
        .order_by("-created_at")[:20]
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def bonus_management(request):
    mode = (request.GET.get("mode") or "").lower()
    if not mode:
        route_name = (getattr(request, "resolver_match", None).url_name or "").lower()
        if route_name.endswith("bonus-remove"):
            mode = "remove"
        elif route_name.endswith("bonus-list"):
            mode = "list"
        else:
            mode = "give"
    if mode not in {"give", "remove", "list"}:
        mode = "give"
    if request.method == "POST":
        action = request.POST.get("action") or ""
        mt5_id = request.POST.get("mt5_id") or ""
        amount = request.POST.get("amount") or "0"
        reason = (request.POST.get("reason") or "").strip()
        from accounts.models import MT5Account
        mt5 = MT5Account.objects.filter(id=mt5_id).select_related("user").first()
        if not mt5:
            messages.error(request, "MT5 Account not found.")
            return redirect(f"{reverse('admin-bonus-manage')}?mode={mode}")
        amt = Decimal(str(amount or 0))
        if amt <= 0:
            messages.error(request, "Amount must be greater than zero.")
            return redirect(f"{reverse('admin-bonus-manage')}?mode={mode}")

        with db_transaction.atomic():
            locked = MT5Account.objects.select_for_update().get(id=mt5.id)
            credit_before = Decimal(str(locked.credit or 0))
            if action == "give":
                locked.credit = credit_before + amt
                locked.save(update_fields=["credit"])
                Bonus.objects.create(user=locked.user, mt5_account=locked, amount=amt, status=Bonus.Status.GIVEN, reason=reason, granted_by=request.user)
                messages.success(request, f"Bonus credited successfully to MT5 Account {locked.login_id}.")
            elif action == "remove":
                if credit_before < amt:
                    messages.error(request, f"Insufficient credit balance on MT5 Account {locked.login_id} for removal.")
                    return redirect(f"{reverse('admin-bonus-manage')}?mode=remove")
                locked.credit = credit_before - amt
                locked.save(update_fields=["credit"])
                Bonus.objects.create(user=locked.user, mt5_account=locked, amount=amt, status=Bonus.Status.REMOVED, reason=reason, granted_by=request.user)
                messages.success(request, f"Bonus removed successfully from MT5 Account {locked.login_id}.")
            else:
                messages.error(request, "Invalid bonus action.")
        return redirect(f"{reverse('admin-bonus-manage')}?mode={mode}")

    rows = Bonus.objects.select_related("user", "mt5_account", "granted_by").order_by("-created_at")[:300]
    from accounts.models import MT5Account
    mt5_accounts = MT5Account.objects.select_related("user").filter(user__is_active=True).order_by("login_id")
    return render(
        request,
        "admin_panel/bonus_management.html",
        {"rows": rows, "mt5_accounts": mt5_accounts, "mode": mode},
    )



def _ensure_compliance_defaults():
    for name in ["Passport", "National ID Card", "Driving License", "Residence Permit"]:
        RequiredDocument.objects.get_or_create(
            name=name,
            category=RequiredDocument.Category.IDENTITY,
            defaults={"is_enabled": True, "is_required": name in {"Passport", "National ID Card"}},
        )
    for name in ["Bank Statement", "Utility Bill", "Government Letter", "Rental Agreement", "National ID (optional)"]:
        RequiredDocument.objects.get_or_create(
            name=name,
            category=RequiredDocument.Category.ADDRESS,
            defaults={"is_enabled": True, "is_required": name in {"Bank Statement", "Utility Bill"}},
        )
    for code, label in [("USDT_TRC20", "USDT TRC20"), ("USDT_ERC20", "USDT ERC20"), ("USDT_BEP20", "USDT BEP20"), ("BTC", "BTC"), ("ETH", "ETH")]:
        CryptoNetwork.objects.get_or_create(code=code, defaults={"label": label, "is_enabled": True})
    for key, label in [
        ("account_name", "Account Name"),
        ("account_number", "Account Number"),
        ("iban", "IBAN"),
        ("swift_code", "Swift Code"),
        ("bank_name", "Bank Name"),
        ("bank_address", "Bank Address"),
        ("country", "Country"),
    ]:
        BankField.objects.get_or_create(
            field_key=key,
            defaults={"label": label, "is_enabled": True, "is_required": key in {"account_name", "account_number", "bank_name", "country"}},
        )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def dashboard(request):
    """Classic admin dashboard: greeting, main statistics grid, live activity."""
    live = get_admin_dashboard_live_metrics()
    dashboard_metrics = get_admin_dashboard_metrics(from_date=None, to_date=None)

    total_users = live.get("total_users", 0)
    active_users = live.get("active_users_30d", 0)
    inactive_users = max(0, total_users - active_users)
    active_pct = round((active_users / total_users * 100) if total_users else 0, 1)
    inactive_pct = round((inactive_users / total_users * 100) if total_users else 0, 1)

    total_ibs = live.get("total_ib", 0)
    total_deposits = live.get("total_deposits", 0.0)
    total_withdrawals = live.get("total_withdrawals", 0.0)
    net_revenue = live.get("net_revenue", 0.0)

    real_accounts = live.get("total_real_accounts", 0)
    demo_accounts = live.get("total_demo_accounts", 0)
    total_accounts = real_accounts + demo_accounts
    real_pct = round((real_accounts / total_accounts * 100) if total_accounts else 0, 1)
    demo_pct = round((demo_accounts / total_accounts * 100) if total_accounts else 0, 1)

    today_deposits = live.get("today_deposits", 0.0)
    weekly_deposits = live.get("weekly_deposits", 0.0)
    today_withdrawals = live.get("today_withdrawals", 0.0)
    weekly_withdrawals = live.get("weekly_withdrawals", 0.0)

    metrics = {
        "total_users": total_users,
        "active_users": active_users,
        "inactive_users": inactive_users,
        "active_pct": active_pct,
        "inactive_pct": inactive_pct,
        "total_ibs": total_ibs,
        "total_deposits": total_deposits,
        "total_withdrawals": total_withdrawals,
        "net_revenue": net_revenue,
        "real_accounts": real_accounts,
        "demo_accounts": demo_accounts,
        "real_pct": real_pct,
        "demo_pct": demo_pct,
        "clients_growth_labels": dashboard_metrics.get("clients_growth_labels", []),
        "clients_growth_values": dashboard_metrics.get("clients_growth_values", []),
        "today_deposits": today_deposits,
        "weekly_deposits": weekly_deposits,
        "today_withdrawals": today_withdrawals,
        "weekly_withdrawals": weekly_withdrawals,
        "deposit_toggle_data": dashboard_metrics.get("deposit_toggle_data", {}),
        "withdraw_toggle_data": dashboard_metrics.get("withdraw_toggle_data", {}),
    }

    def _fmt_int(n) -> str:
        try:
            return f"{int(n):,}"
        except (TypeError, ValueError):
            return "0"

    def _fmt_money(n) -> str:
        try:
            return f"{float(n):,.2f}"
        except (TypeError, ValueError):
            return "0.00"

    stat_rows = [
        [
            {
                "title": "Total Users",
                "value": _fmt_int(live["total_users"]),
                "url": f"{reverse('admin-user-list')}?list_scope=all",
                "icon": "fa-solid fa-users",
                "icon_color": "#3b82f6",
            },
            {
                "title": "Active Users",
                "value": _fmt_int(live["active_users_30d"]),
                "url": reverse("admin-hub-users-activity"),
                "icon": "fa-solid fa-user-check",
                "icon_color": "#10b981",
            },
            {
                "title": "Total IBs",
                "value": _fmt_int(live["total_ib"]),
                "url": reverse("admin-ib-users"),
                "icon": "fa-solid fa-handshake",
                "icon_color": "#a855f7",
            },
        ],
        [
            {
                "title": "Net Revenue",
                "value": _fmt_money(live["net_revenue"]),
                "url": reverse("admin-hub-net-revenue"),
                "icon": "fa-solid fa-chart-line",
                "icon_color": "#f59e0b",
            }
        ]
    ]
    
    for row in stat_rows:
        for c in row:
            c.update(_gen_sparkline_data(c["title"]))
            
    stat_cards = [c for row in stat_rows for c in row][:6]

    unread_staff_notifications = _unread_staff_notifications_for(request.user)
    pending_breakdown = _pending_breakdown_from_metrics(dashboard_metrics)
    pending_sum = sum(pending_breakdown.values())
    notify_total = len(unread_staff_notifications) + pending_sum
    pending_cards = _pending_overview_cards(dashboard_metrics, fmt_int=_fmt_int)

    from live_chat.models import SupportTicket
    recent_tickets = SupportTicket.objects.select_related("user").order_by("-created_at")[:5]
    
    resolved_tickets_count = SupportTicket.objects.filter(status=SupportTicket.Status.RESOLVED).count()
    pending_tickets_count = SupportTicket.objects.exclude(status=SupportTicket.Status.RESOLVED).count()

    return render(
        request,
        "admin_panel/dashboard.html",
        {
            "metrics": metrics,
            "stat_rows": stat_rows,
            "stat_cards": stat_cards,
            "pending_cards": pending_cards,
            "pending_breakdown": pending_breakdown,
            "live_activity_url": reverse("admin-dashboard-live-activity"),
            "notify_total": notify_total,
            "unread_staff_notifications": unread_staff_notifications,
            "recent_tickets": recent_tickets,
            "resolved_tickets_count": resolved_tickets_count,
            "pending_tickets_count": pending_tickets_count,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def dashboard_live_stats_api(request):
    """JSON snapshot for live-sync dashboard widgets (poll every ~30s)."""
    try:
        payload = get_live_dashboard_kpis()
    except Exception:
        logger.exception("admin dashboard live-stats API failed")
        payload = {
            "total_users": 0,
            "active_users": 0,
            "total_live_accounts": 0,
            "total_demo_accounts": 0,
            "total_deposit": 0.0,
            "total_withdrawal": 0.0,
            "today_deposit": 0.0,
            "today_withdrawal": 0.0,
            "trading_commission": 0.0,
            "spread_revenue": 0.0,
            "net_revenue": 0.0,
            "active_payment_methods_count": 0,
            "active_payment_methods": [],
            "updated_at": "",
            "error": True,
        }
    resp = JsonResponse(payload)
    resp["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    resp["Pragma"] = "no-cache"
    return resp


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def mark_staff_notification_read(request, notification_id: int):
    note = StaffNotification.objects.filter(id=notification_id, recipient=request.user).first()
    StaffNotification.objects.filter(
        id=notification_id,
        recipient=request.user,
        read_at__isnull=True,
    ).update(read_at=timezone.now())
    next_url = (request.POST.get("next") or "").strip()
    if not next_url and note:
        next_url = (note.action_url or "").strip()
    if not next_url:
        next_url = reverse("admin-dashboard")
    return redirect(next_url)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def dashboard_notifications_api(request):
    unread_staff_notifications = _unread_staff_notifications_for(request.user)
    notify_total = len(unread_staff_notifications)
    staff_items = []
    for note in unread_staff_notifications[:12]:
        next_url = (getattr(note, "action_url", None) or "").strip() or reverse("admin-dashboard")
        staff_items.append(
            {
                "id": note.id,
                "title": note.title[:200],
                "body": (note.body or "")[:220],
                "next": next_url,
                "created_at": note.created_at.isoformat() if note.created_at else "",
            }
        )
    return JsonResponse(
        {
            "notify_total": notify_total,
            "staff_items": staff_items,
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def mark_staff_notification_read_api(request, notification_id: int):
    updated = StaffNotification.objects.filter(
        id=notification_id,
        recipient=request.user,
        read_at__isnull=True,
    ).update(read_at=timezone.now())
    return JsonResponse({"ok": bool(updated)})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def mark_all_staff_notifications_read(request):
    StaffNotification.objects.filter(recipient=request.user, read_at__isnull=True).update(read_at=timezone.now())
    return JsonResponse({"ok": True})


def get_live_activity_items(limit=5):
    from accounts.models import User
    from transactions.models import Transaction
    from django.utils.timesince import timesince
    from django.utils import timezone

    regs = User.objects.filter(role__in=[User.Roles.CLIENT, User.Roles.IB]).order_by("-date_joined")[:limit]
    deps = Transaction.objects.filter(
        tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    ).order_by("-created_at")[:limit]
    wds = Transaction.objects.filter(
        tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
    ).order_by("-created_at")[:limit]

    def _fmt_time(dt):
        return f"{timesince(dt).split(',')[0]} ago" if dt else ""

    return {
        "registrations": [
            {
                "id": u.id,
                "name": u.display_name() or "Unknown",
                "country": u.country or "Unknown",
                "time_ago": _fmt_time(u.date_joined),
                "initials": (u.display_name() or "U")[0].upper()
            }
            for u in regs
        ],
        "deposits": [
            {
                "id": t.id,
                "name": t.actor.display_name() if t.actor else "Unknown",
                "method": getattr(t.payment_gateway, "name", "SYSTEM") if t.payment_gateway else (t.account_details or "SYSTEM"),
                "amount": f"${float(t.amount):,.1f}K" if t.amount and t.amount >= 1000 else f"${float(t.amount):,.0f}" if t.amount else "$0",
                "status": t.status,
                "time_ago": _fmt_time(t.created_at)
            }
            for t in deps
        ],
        "withdrawals": [
            {
                "id": t.id,
                "name": t.actor.display_name() if t.actor else "Unknown",
                "method": getattr(t.payment_gateway, "name", "SYSTEM") if t.payment_gateway else (t.account_details or "SYSTEM"),
                "amount": f"${float(t.amount):,.1f}K" if t.amount and t.amount >= 1000 else f"${float(t.amount):,.0f}" if t.amount else "$0",
                "status": t.status,
                "time_ago": _fmt_time(t.created_at)
            }
            for t in wds
        ]
    }

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def dashboard_live_activity_api(request):
    """JSON feed for admin dashboard Live Activity (poll every ~10–15s)."""
    try:
        items = get_live_activity_items(limit=5)
    except Exception:
        logger.exception("dashboard live activity failed")
        items = {"registrations": [], "deposits": [], "withdrawals": []}
    resp = JsonResponse({"items": items, "updated_at": timezone.now().isoformat()})
    resp["Cache-Control"] = "no-store"
    return resp


def build_excel_html_table(rows):
    html = ['<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns="http://www.w3.org/TR/REC-html40">']
    html.append('<meta http-equiv="content-type" content="application/vnd.ms-excel; charset=UTF-8">')
    html.append('<body><table border="1">')
    for row in rows:
        html.append('<tr>')
        for cell in row:
            html.append(f'<td>{cell}</td>')
        html.append('</tr>')
    html.append('</table></body></html>')
    return "".join(html).encode("utf-8")

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def dashboard_export(request):
    import io

    export_format = (request.GET.get("format") or "csv").lower()
    from_str = (request.GET.get("from") or "").strip()
    to_str = (request.GET.get("to") or "").strip()
    from_date = None
    to_date = None
    try:
        if from_str and to_str:
            from_date = datetime.strptime(from_str, "%Y-%m-%d").date()
            to_date = datetime.strptime(to_str, "%Y-%m-%d").date()
    except Exception:
        from_date = None
        to_date = None
    metrics = get_admin_dashboard_metrics(from_date=from_date, to_date=to_date)

    if export_format not in {"csv", "xlsx", "pdf"}:
        export_format = "csv"

    rows = [
        ["Metric", "Value"],
        ["Date range (from)", from_str or "—"],
        ["Date range (to)", to_str or "—"],
        ["Total Users (excl. admin/banker)", metrics.get("total_users", metrics.get("dashboard_total_users", 0))],
        ["Total IBs", metrics.get("total_ib", 0)],
        ["Total Deposits (range)", metrics.get("total_deposit", 0)],
        ["Total Withdrawals (range)", metrics.get("total_withdrawal", metrics.get("total_withdraw", 0))],
        ["Total Revenue (gross deposits)", metrics.get("total_revenue", metrics.get("total_deposit", 0))],
        ["Net Revenue (range)", metrics.get("net_revenue", 0)],
        ["Total Real (Live) MT5", metrics.get("total_real_accounts", metrics.get("total_live_mt5_accounts", 0))],
        ["Total Demo MT5", metrics.get("total_demo_accounts", metrics.get("total_demo_mt5_accounts", 0))],
        ["Pending Deposits", metrics.get("pending_deposit", metrics.get("pending_deposit_global", 0))],
        ["Pending Withdrawals", metrics.get("pending_withdrawal", metrics.get("pending_withdraw_global", 0))],
        ["Pending KYC (identity+address rows)", metrics.get("pending_kyc", metrics.get("pending_kyc_queue", 0))],
        ["Pending IB Requests", metrics.get("pending_ib_requests", 0)],
    ]

    if export_format == "csv":
        response = HttpResponse(content_type="text/csv; charset=utf-8")
        response["Content-Disposition"] = 'attachment; filename="crm_dashboard_export.csv"'
        response.write("\ufeff")
        w = csv.writer(response)
        for row in rows:
            w.writerow(row)
        return response

    if export_format == "xlsx":
        response = HttpResponse(content_type="application/vnd.ms-excel")
        response["Content-Disposition"] = 'attachment; filename="crm_dashboard_export.xls"'
        response.write(build_excel_html_table(rows))
        return response

    # PDF
    try:
        from reportlab.lib import colors
        from reportlab.lib.pagesizes import letter
        from reportlab.platypus import SimpleDocTemplate, Spacer, Table, TableStyle

        buf = io.BytesIO()
        doc = SimpleDocTemplate(buf, pagesize=letter, rightMargin=36, leftMargin=36, topMargin=36, bottomMargin=36)
        t = Table([[str(c) for c in r] for r in rows], repeatRows=1)
        t.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0B3C5D")),
                    ("TEXTCOLOR", (0, 0), (-1, 0), colors.whitesmoke),
                    ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                    ("FONTSIZE", (0, 0), (-1, -1), 9),
                    ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
                    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f8fafc")]),
                ]
            )
        )
        doc.build([t, Spacer(1, 12)])
        pdf = buf.getvalue()
        buf.close()
        response = HttpResponse(pdf, content_type="application/pdf")
        response["Content-Disposition"] = 'attachment; filename="crm_dashboard_export.pdf"'
        return response
    except ImportError:
        response = HttpResponse(content_type="text/csv; charset=utf-8")
        response["Content-Disposition"] = 'attachment; filename="crm_dashboard_export_pdf_fallback.csv"'
        response.write("\ufeff")
        w = csv.writer(response)
        w.writerow(["Note", "Install reportlab for PDF export (pip install reportlab)."])
        for row in rows:
            w.writerow(row)
        return response


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def ib_dashboard(request):
    ib_user_id = (request.GET.get("ib_user") or "").strip()
    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()
    total_ib = User.objects.filter(role=User.Roles.IB).count() or 0

    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")
    approved_links = IBRequest.objects.filter(status=IBRequest.Status.APPROVED)
    if ib_user_id:
        approved_links = approved_links.filter(ib_user_id=ib_user_id)
    client_ids = list(approved_links.values_list("client_user_id", flat=True).distinct())
    total_clients = len(client_ids) or 0

    vol_qs = IBProgressMetrics.objects.all()
    if ib_user_id:
        vol_qs = vol_qs.filter(ib_user_id=ib_user_id)
    agg_vol = vol_qs.aggregate(v=Sum("all_time_volume")).get("v")
    total_volume_metric = agg_vol if agg_vol is not None else Decimal("0")

    deposit_qs = Transaction.objects.filter(
        actor_id__in=client_ids,
        tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
    )
    if from_date:
        deposit_qs = deposit_qs.filter(created_at__date__gte=from_date)
    if to_date:
        deposit_qs = deposit_qs.filter(created_at__date__lte=to_date)
    total_deposit = deposit_qs.aggregate(Sum("amount")).get("amount__sum") or 0

    withdraw_qs = Transaction.objects.filter(
        actor_id__in=client_ids,
        tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW],
        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
    )
    if from_date:
        withdraw_qs = withdraw_qs.filter(created_at__date__gte=from_date)
    if to_date:
        withdraw_qs = withdraw_qs.filter(created_at__date__lte=to_date)
    total_withdraw = withdraw_qs.aggregate(Sum("amount")).get("amount__sum") or 0

    commission_qs = Transaction.objects.filter(
        tx_type=Transaction.TxType.IB_WITHDRAW,
        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
    ).exclude(from_user_id=F("actor_id"))
    if ib_user_id:
        commission_qs = commission_qs.filter(actor_id=ib_user_id)
    if from_date:
        commission_qs = commission_qs.filter(created_at__date__gte=from_date)
    if to_date:
        commission_qs = commission_qs.filter(created_at__date__lte=to_date)
    total_commission = commission_qs.aggregate(Sum("amount")).get("amount__sum") or 0

    pending_commission_qs = Transaction.objects.filter(
        tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
        status=Transaction.Status.PENDING,
    )
    if ib_user_id:
        pending_commission_qs = pending_commission_qs.filter(actor_id=ib_user_id)
    if from_date:
        pending_commission_qs = pending_commission_qs.filter(created_at__date__gte=from_date)
    if to_date:
        pending_commission_qs = pending_commission_qs.filter(created_at__date__lte=to_date)
    pending_commission = pending_commission_qs.aggregate(Sum("amount")).get("amount__sum") or 0

    paid_commission = total_commission
    total_commission_headline = Decimal(str(paid_commission or 0)) + Decimal(str(pending_commission or 0))

    commission_chart_rows = list(
        commission_qs.annotate(day=TruncDate("created_at"))
        .values("day")
        .annotate(total=Sum("amount"))
        .order_by("day")
    )
    commission_chart_labels = [r["day"].isoformat() if r.get("day") else "" for r in commission_chart_rows]
    commission_chart_values = [float(r["total"] or 0) for r in commission_chart_rows]
    commission_chart_json = json.dumps({"labels": commission_chart_labels, "values": commission_chart_values})

    recent_qs = IBRequest.objects.select_related("ib_user", "client_user", "plan").order_by("-requested_at")
    if ib_user_id:
        recent_qs = recent_qs.filter(ib_user_id=ib_user_id)
    recent_activity = list(recent_qs[:20])

    total_ib_withdraw = total_commission
    total_bonus = Bonus.objects.filter(user_id__in=client_ids, status=Bonus.Status.GIVEN).aggregate(v=Sum("amount"))["v"] or 0
    net_deposit = Decimal(str(total_deposit or 0)) - Decimal(str(total_withdraw or 0))

    country_wise = list(
        deposit_qs.values("actor__country").annotate(total=Sum("amount")).order_by("-total")[:8]
    )
    top_marketing = list(
        User.objects.filter(id__in=client_ids)
        .annotate(
            total_dep=Sum("transactions_as_actor__amount", filter=Q(transactions_as_actor__tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT], transactions_as_actor__status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])),
            total_wdr=Sum("transactions_as_actor__amount", filter=Q(transactions_as_actor__tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW], transactions_as_actor__status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])),
        )
        .order_by("-total_dep", "-id")[:10]
    )
    top_ib_commission = list(
        User.objects.filter(role=User.Roles.IB)
        .annotate(
            total_ib_commission=Sum(
                "transactions_as_actor__amount",
                filter=Q(
                    transactions_as_actor__tx_type=Transaction.TxType.IB_WITHDRAW,
                    transactions_as_actor__status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
                & ~Q(transactions_as_actor__from_user=F("id")),
            )
        )
        .order_by("-total_ib_commission", "-id")[:10]
    )
    top_ib_withdraw = top_ib_commission

    country_wise_json = json.dumps(
        [{"country": (r.get("actor__country") or "Unknown"), "total": float(r.get("total") or 0)} for r in country_wise],
        default=str,
    )

    context = {
        "total_ib": total_ib,

        "total_clients": total_clients,
        "total_deposit": total_deposit,
        "total_withdraw": total_withdraw,
        "total_commission": total_commission,
        "paid_commission": paid_commission,
        "pending_commission": pending_commission,
        "total_commission_headline": total_commission_headline,
        "total_volume_metric": total_volume_metric,
        "totals": {
            "total_ib": total_ib,

            "total_clients": total_clients,
            "total_deposit": total_deposit,
            "total_withdraw": total_withdraw,
            "total_commission": total_commission,
            "paid_commission": paid_commission,
            "pending_commission": pending_commission,
            "total_commission_headline": total_commission_headline,
            "net_deposit": net_deposit,
            "total_ib_withdraw": total_ib_withdraw,
            "total_bonus": total_bonus,
            "total_lots": MT5Account.objects.filter(user_id__in=client_ids).count() or 0,
            "total_volume": total_volume_metric,
        },
        "labels": [],
        "volume_values": [],
        "earning_values": [],
        "ranking": top_ib_commission,
        "top_clients": top_marketing,
        "country_wise": country_wise,
        "country_wise_json": country_wise_json,
        "commission_chart_json": commission_chart_json,
        "recent_activity": recent_activity,
        "ib_users": ib_users,
        "filters": {"ib_user": ib_user_id, "from": from_date, "to": to_date},
        "top_ib_commission": top_ib_commission,
        "top_ib_withdraw": top_ib_withdraw,
        "report_commission_url": reverse("admin-report-ib-commission"),
        "ib_requests_url": reverse("admin-ib-requests"),
    }
    return render(request, "admin_panel/ib_dashboard.html", context)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def add_commission_group(request):
    return redirect("admin-ib-commission-group")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def ib_users(request):
    q = (request.GET.get("q") or "").strip()
    country = (request.GET.get("country") or "").strip()
    status_f = (request.GET.get("status") or "").strip().lower()
    ibs = User.objects.filter(role=User.Roles.IB)
    if q:
        ibs = ibs.filter(
            Q(first_name__icontains=q)
            | Q(last_name__icontains=q)
            | Q(email__icontains=q)
            | Q(phone__icontains=q)
            | Q(mt5_accounts__login_id__icontains=q)
        ).distinct()
    if country:
        ibs = ibs.filter(country__icontains=country)
    if status_f == "active":
        ibs = ibs.filter(is_active=True)
    elif status_f == "inactive":
        ibs = ibs.filter(is_active=False)
    ibs = ibs.order_by("-date_joined")
    paginator = Paginator(ibs, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    page_users = list(page_obj.object_list)
    uid_list = [u.id for u in page_users]
    profiles_by_uid = {
        p.user_id: p for p in IBProfile.objects.filter(user_id__in=uid_list).select_related("ib_level")
    }
    rows = []
    for u in page_users:
        profile = profiles_by_uid.get(u.id)
        client_ids = list(IBRequest.objects.filter(ib_user=u, status=IBRequest.Status.APPROVED).values_list("client_user_id", flat=True))
        total_clients = len(set(client_ids))
        data = Transaction.objects.filter(
            actor=u, tx_type=Transaction.TxType.IB_WITHDRAW, status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
        ).exclude(
            from_user=u
        ).aggregate(total=Sum("amount")) or {}
        total_commission = data.get("total") or 0
        rows.append(
            {
                "u": u,
                "total_clients": total_clients,
                "total_commission": total_commission,
                "referral_link": (
                    profile.referral_link
                    if profile and profile.referral_link
                    else (build_register_referral_url(request, profile.ib_code) if profile and profile.ib_code else "")
                ),
                "ib_level_name": (profile.ib_level.name if profile and profile.ib_level_id else "—"),
            }
        )
    return render(
        request,
        "admin_panel/ib_users.html",
        {
            "rows": rows,
            "page_obj": page_obj,
            "filters": {"q": q, "country": country, "status": status_f},
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_requests_page(request):
    list_status = _parse_list_status(request, "pending")
    query_ex_status = _querystring_excluding(request, "status")

    q = (request.GET.get("q") or "").strip()
    per_page = request.GET.get("per_page") or "10"
    sort = (request.GET.get("sort") or "-requested_at").strip()
    try:
        per_page_i = int(per_page)
    except ValueError:
        per_page_i = 10
    if per_page_i not in {10, 25, 50, 100}:
        per_page_i = 10
    allowed_sort = {"id", "-id", "requested_at", "-requested_at", "status", "-status"}
    if sort not in allowed_sort:
        sort = "-requested_at"
    if request.method == "POST":
        req_id = request.POST.get("request_id")
        action = request.POST.get("action")
        req = IBRequest.objects.select_related("client_user").filter(id=req_id).first()
        if not req:
            return redirect(f"{reverse('admin-ib-requests')}?{request.GET.urlencode()}")
        if action == "approve":
            req.status = IBRequest.Status.APPROVED
            req.processed_at = timezone.now()
            req.save(update_fields=["status", "processed_at"])
            
            client = req.client_user
            client.role = User.Roles.IB
            client.save(update_fields=["role"])
            
            ib_level_id = request.POST.get("ib_level_id")
            selected_level = None
            if ib_level_id:
                selected_level = IBLevel.objects.filter(id=ib_level_id, is_active=True).first()

            seed_code = generate_unique_ib_code()
            profile, _ = IBProfile.objects.get_or_create(
                user=client,
                defaults={
                    "ib_code": seed_code,
                    "referral_link": "",
                    "can_view_clients": False,
                },
            )
            
            if selected_level:
                profile.ib_level = selected_level

            ensure_profile_referral_url(request, profile)
            profile.save(update_fields=["ib_code", "referral_link", "ib_level"])
            evaluate_ib_level_for_user(client)
            
            # Audit log
            log_audit(
                action="IB_REQUEST_APPROVED",
                entity_type="IBRequest",
                entity_id=str(req.id),
                actor=request.user,
                channel=AuditLogChannel.ADMIN,
                request=request,
                ip=get_client_ip(request),
                metadata={"client_id": client.id},
            )
            
            send_event_email(
                "ib_request_approved",
                to_email=client.email,
                user=client,
                extra_context={"name": client.display_name(), "reason": profile.referral_link or "—"},
            )
        elif action == "reject":
            req.status = IBRequest.Status.REJECTED
            req.processed_at = timezone.now()
            rej_notes = (req.notes or "").strip() or "Please contact support for details."
            req.save(update_fields=["status", "processed_at"])
            
            # Audit log
            log_audit(
                action="IB_REQUEST_REJECTED",
                entity_type="IBRequest",
                entity_id=str(req.id),
                actor=request.user,
                channel=AuditLogChannel.ADMIN,
                request=request,
                ip=get_client_ip(request),
                metadata={"client_id": req.client_user_id, "notes": rej_notes},
            )
            
            send_event_email(
                "ib_request_rejected",
                to_email=req.client_user.email,
                user=req.client_user,
                extra_context={"name": req.client_user.display_name(), "reason": rej_notes},
            )
        return redirect(f"{reverse('admin-ib-requests')}?{request.GET.urlencode()}")
    base_all = IBRequest.objects.filter(ib_user=F("client_user"))
    status_counts = {
        "pending": base_all.filter(status=IBRequest.Status.PENDING).count(),
        "approved": base_all.filter(status=IBRequest.Status.APPROVED).count(),
        "rejected": base_all.filter(status=IBRequest.Status.REJECTED).count(),
    }
    rows = base_all.select_related("ib_user", "client_user", "plan")
    if list_status == "approved":
        rows = rows.filter(status=IBRequest.Status.APPROVED)
    elif list_status == "rejected":
        rows = rows.filter(status=IBRequest.Status.REJECTED)
    else:
        rows = rows.filter(status=IBRequest.Status.PENDING)
    if q:
        rows = rows.filter(
            Q(client_user__first_name__icontains=q)
            | Q(client_user__last_name__icontains=q)
            | Q(client_user__email__icontains=q)
            | Q(client_user__phone__icontains=q)
            | Q(client_user__country__icontains=q)
        )
    rows = rows.order_by(sort)
    if (request.GET.get("export") or "").lower() == "excel":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="ib_request_users.csv"'
        w = csv.writer(response)
        w.writerow(["ID", "Name", "Email", "Phone", "Country", "Registration Date", "Status"])
        for r in rows[:5000]:
            cu = r.client_user
            w.writerow([r.id, cu.display_name(), cu.email, cu.phone or "-", cu.country or "-", timezone.localtime(cu.date_joined).strftime("%Y-%m-%d %H:%M"), r.status])
        return response
    paginator = Paginator(rows, per_page_i)
    page_obj = paginator.get_page(request.GET.get("page"))
    ib_apply_labels = {
        "ib_experience": "IB experience",
        "worked_before": "Where worked before",
        "bring_clients": "How will you bring clients",
        "monthly_clients": "Monthly clients estimate",
        "target_country": "Target country / region",
        "additional_notes": "Additional notes",
    }
    ib_question_labels = {**ib_apply_labels, **{str(q.id): q.label for q in IBApplicationQuestion.objects.all()}}
    return render(
        request,
        "admin_panel/ib_requests.html",
        {
            "page_obj": page_obj,
            "filters": {"q": q, "per_page": per_page_i, "sort": sort, "status": list_status},
            "list_status": list_status,
            "status_counts": status_counts,
            "query_ex_status": query_ex_status,
            "ib_question_labels": ib_question_labels,
            "all_ib_levels": IBLevel.objects.filter(is_active=True).order_by("sequence", "id"),
            "active_plans": IBPlan.objects.filter(is_active=True),
        },
    )



@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_plan_page(request):
    from ib.models import IBPlan, IBPlanSymbolRebate
    from admin_panel.models import TradingAccountType

    plan_id = request.GET.get("id")
    selected_plan = None
    symbol_rebates = []
    account_types = []

    if plan_id:
        selected_plan = IBPlan.objects.filter(id=plan_id).first()
        if selected_plan:
            symbol_rebates = selected_plan.symbol_rebates.all().select_related("account_type")
            account_types = TradingAccountType.objects.filter(is_active=True).order_by("account_name")

    if request.method == "POST":
        action = request.POST.get("action")
        
        # Plan operations
        if action == "add":
            name = (request.POST.get("name") or "").strip()
            description = (request.POST.get("description") or "").strip()
            if not name:
                messages.error(request, "Plan Name is required.")
            else:
                p, created = IBPlan.objects.get_or_create(
                    name=name,
                    defaults={"description": description, "is_active": True},
                )
                if created:
                    messages.success(request, f"IB plan '{name}' created.")
                    log_audit(
                        action="IB_PLAN_CREATED",
                        entity_type="IBPlan",
                        entity_id=str(p.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"name": name},
                    )
                else:
                    messages.error(request, f"IB plan '{name}' already exists.")
                    
        elif action == "edit_plan":
            pid = request.POST.get("id")
            p = IBPlan.objects.filter(id=pid).first()
            if p:
                p.name = (request.POST.get("name") or p.name).strip()
                p.description = (request.POST.get("description") or p.description).strip()
                p.is_active = request.POST.get("is_active") == "on"
                p.save()
                messages.success(request, f"IB plan '{p.name}' updated.")
                log_audit(
                    action="IB_PLAN_UPDATED",
                    entity_type="IBPlan",
                    entity_id=str(p.id),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"name": p.name, "is_active": p.is_active},
                )
                return redirect(f"{reverse('admin-ib-plan')}?id={p.id}")
                
        elif action == "delete":
            pid = request.POST.get("id")
            p = IBPlan.objects.filter(id=pid).first()
            if p:
                p_name = p.name
                p.delete()
                messages.success(request, f"IB plan '{p_name}' deleted.")
                log_audit(
                    action="IB_PLAN_DELETED",
                    entity_type="IBPlan",
                    entity_id=str(pid),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"name": p_name},
                )
                return redirect("admin-ib-plan")

        # Symbol rebate rules operations
        elif action == "add_symbol_rebate":
            pid = request.POST.get("plan_id")
            p = IBPlan.objects.filter(id=pid).first()
            if p:
                symbol = (request.POST.get("symbol") or "").strip().upper()
                atype_id = (request.POST.get("account_type_id") or "").strip()
                rebate_per_lot_str = (request.POST.get("rebate_per_lot") or "0").strip()
                
                try:
                    rebate_per_lot = Decimal(rebate_per_lot_str)
                except Exception:
                    rebate_per_lot = Decimal("0")
                
                atype = None
                if atype_id:
                    atype = TradingAccountType.objects.filter(id=atype_id).first()
                
                if not symbol:
                    messages.error(request, "Symbol name is required.")
                elif rebate_per_lot <= 0:
                    messages.error(request, "Rebate per lot must be a positive decimal.")
                else:
                    rule, created = IBPlanSymbolRebate.objects.update_or_create(
                        plan=p,
                        symbol=symbol,
                        account_type=atype,
                        defaults={"rebate_per_lot": rebate_per_lot, "is_active": True}
                    )
                    messages.success(request, f"Symbol rebate rule for {symbol} saved.")
                    log_audit(
                        action="IB_PLAN_SYMBOL_REBATE_SAVED",
                        entity_type="IBPlanSymbolRebate",
                        entity_id=str(rule.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={
                            "plan_id": p.id,
                            "symbol": symbol,
                            "account_type_id": atype.id if atype else None,
                            "rebate_per_lot": str(rebate_per_lot),
                        },
                    )
                return redirect(f"{reverse('admin-ib-plan')}?id={p.id}")

        elif action == "delete_symbol_rebate":
            rid = request.POST.get("rule_id")
            rule = IBPlanSymbolRebate.objects.filter(id=rid).first()
            if rule:
                pid = rule.plan_id
                rule_name = f"{rule.symbol} (${rule.rebate_per_lot}/lot)"
                rule.delete()
                messages.success(request, f"Rebate rule for {rule_name} deleted.")
                log_audit(
                    action="IB_PLAN_SYMBOL_REBATE_DELETED",
                    entity_type="IBPlanSymbolRebate",
                    entity_id=str(rid),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"plan_id": pid, "rule_name": rule_name},
                )
                return redirect(f"{reverse('admin-ib-plan')}?id={pid}")
                
        return redirect("admin-ib-plan")

    rows = IBPlan.objects.order_by("name")
    add_only = (request.GET.get("view") or "").lower() == "add" or (getattr(request, "resolver_match", None).url_name == "admin-ib-plan-add")
    
    return render(
        request, 
        "admin_panel/ib_plan.html", 
        {
            "rows": rows, 
            "add_only": add_only,
            "selected_plan": selected_plan,
            "symbol_rebates": symbol_rebates,
            "account_types": account_types,
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_commission_group_page(request):
    plans = IBPlan.objects.filter(is_active=True).order_by("name")
    crm_account_types = TradingAccountType.objects.filter(is_active=True).order_by("display_order", "account_name")
    edit_id = request.GET.get("edit")
    edit_obj = IBCommissionRule.objects.select_related("plan", "commission_group").filter(id=edit_id).first() if edit_id else None
    if request.method == "POST":
        action = request.POST.get("action")
        if action in {"add", "edit"}:
            plan_id = request.POST.get("plan_id")
            at_id = (request.POST.get("crm_account_type_id") or "").strip()
            atype = TradingAccountType.objects.filter(id=at_id).first() if at_id.isdigit() else None
            level_count = 2
            commission_type = (request.POST.get("commission_type") or IBCommissionSettings.CommissionType.SPREAD_AND_COMMISSION).strip()
            master_pct = request.POST.get("master_pct") or 0
            sub_pct = request.POST.get("sub_pct") or 0
            if not atype:
                messages.error(request, "Select a CRM account type (commission follows CRM groups).")
                return redirect("admin-ib-commission-group")
            group, _ = CommissionGroup.objects.get_or_create(
                name=atype.account_name,
                defaults={"description": f"CRM account type {atype.account_code}"},
            )
            payload = {
                "plan_id": plan_id or None,
                "commission_group": group,
                "commission_amount": master_pct or 0,
                "level_count": level_count,
                "level1": master_pct or 0,
                "level2": sub_pct or 0,
                "level3": 0,
                "level4": 0,
                "level5": 0,
                "level6": 0,
                "level7": 0,
                "level8": 0,
                "level9": 0,
                "level10": 0,
                "is_active": request.POST.get("is_active") == "on",
            }
            s = IBCommissionSettings.get_solo()
            s.commission_type = commission_type
            s.save(update_fields=["commission_type", "updated_at"])
            if action == "add":
                IBCommissionRule.objects.create(**payload)
                messages.success(request, "Commission group rule added.")
            else:
                obj = IBCommissionRule.objects.filter(id=request.POST.get("id")).first()
                if obj:
                    for k, v in payload.items():
                        setattr(obj, k, v)
                    obj.save()
                    messages.success(request, "Commission group rule updated.")
        elif action == "delete":
            IBCommissionRule.objects.filter(id=request.POST.get("id")).delete()
            messages.success(request, "Commission group rule deleted.")
        return redirect("admin-ib-commission-group")
    rows = IBCommissionRule.objects.select_related("plan", "commission_group").order_by("-id")
    return render(
        request,
        "admin_panel/ib_commission_group.html",
        {
            "rows": rows,
            "plans": plans,
            "crm_account_types": crm_account_types,
            "edit_obj": edit_obj,
            "settings_obj": IBCommissionSettings.get_solo(),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_set_commission_page(request):
    plans = IBPlan.objects.order_by("name")
    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")
    if request.method == "POST":
        action = request.POST.get("action") or "add"
        ib_id = request.POST.get("ib_id")
        plan_id = request.POST.get("plan_id")
        if action == "add" and ib_id and plan_id:
            IBUserCommission.objects.update_or_create(ib_user_id=ib_id, defaults={"plan_id": plan_id})
            messages.success(request, "User commission assigned.")
        elif action == "edit":
            row_id = request.POST.get("id")
            row = IBUserCommission.objects.filter(id=row_id).first()
            if row and ib_id and plan_id:
                row.ib_user_id = ib_id
                row.plan_id = plan_id
                row.save(update_fields=["ib_user", "plan", "updated_at"])
                messages.success(request, "User commission updated.")
        return redirect("admin-ib-set-commission")
    q = (request.GET.get("q") or "").strip()
    rows = IBUserCommission.objects.select_related("ib_user", "plan").order_by("-created_at")
    if q:
        rows = rows.filter(Q(ib_user__email__icontains=q) | Q(ib_user__first_name__icontains=q) | Q(plan__name__icontains=q))
    paginator = Paginator(rows, 20)
    page_obj = paginator.get_page(request.GET.get("page"))
    edit_id = request.GET.get("edit") or ""
    edit_obj = IBUserCommission.objects.filter(id=edit_id).first() if edit_id else None
    return render(request, "admin_panel/ib_set_commission.html", {"plans": plans, "ib_users": ib_users, "page_obj": page_obj, "edit_obj": edit_obj, "filters": {"q": q}})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_trade_close_event(request):
    if request.method == "POST":
        client_id = request.POST.get("client_id")
        lots = request.POST.get("lots") or "0"
        volume = request.POST.get("volume") or "0"
        reference = (request.POST.get("reference") or "").strip()
        symbol = (request.POST.get("symbol") or "").strip().upper()
        group_name = (request.POST.get("group_name") or "").strip()
        spread_amount = request.POST.get("spread_amount") or "0"
        commission_amount = request.POST.get("commission_amount") or "0"
        client = User.objects.filter(id=client_id).first()
        if not client:
            messages.error(request, "Client not found.")
            return redirect("admin-ib-set-commission")
        at_raw = (request.POST.get("account_type_id") or "").strip()
        account_type_id = int(at_raw) if at_raw.isdigit() else None
        hs_raw = (request.POST.get("hold_seconds") or "").strip()
        hold_seconds = int(hs_raw) if hs_raw.isdigit() else None
        try:
            result = distribute_trade_commission(
                client,
                Decimal(str(lots)),
                Decimal(str(volume)),
                reference,
                symbol=symbol,
                group_name=group_name,
                spread_amount=Decimal(str(spread_amount)),
                commission_amount=Decimal(str(commission_amount)),
                account_type_id=account_type_id,
                hold_seconds=hold_seconds,
            )
            messages.success(request, f"Commission distributed to {result['distributed']} level(s).")
        except Exception as exc:
            messages.error(request, f"Auto commission failed: {exc}")
        return redirect("admin-ib-set-commission")
    clients = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).order_by("email")[:1000]
    from admin_panel.models import TradingAccountType

    account_types = TradingAccountType.objects.filter(is_active=True).order_by("account_name")
    return render(request, "admin_panel/ib_trade_close.html", {"clients": clients, "account_types": account_types})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_move_client_page(request):
    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")
    clients = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).order_by("email")
    plans = IBPlan.objects.filter(is_active=True).order_by("name")
    if request.method == "POST":
        action = request.POST.get("action") or "assign"
        client_id = request.POST.get("client_id")
        ib_id = request.POST.get("ib_user_id")
        plan_id = request.POST.get("plan_id")
        if action == "assign" and client_id and ib_id:
            exists = IBRequest.objects.filter(client_user_id=client_id, status=IBRequest.Status.APPROVED).first()
            if exists:
                exists.ib_user_id = ib_id
                exists.plan_id = plan_id or exists.plan_id
                exists.processed_at = timezone.now()
                exists.notes = "Reassigned by admin"
                exists.save(update_fields=["ib_user", "plan", "processed_at", "notes"])
                messages.success(request, "Client reassigned under IB.")
                try:
                    from ib.level_progress import maybe_queue_level_upgrade, refresh_referral_count

                    ib_master = User.objects.filter(id=ib_id).first()
                    if ib_master:
                        refresh_referral_count(ib_master, increment_period=True)
                        maybe_queue_level_upgrade(ib_master)
                except Exception:
                    pass
            else:
                IBRequest.objects.create(
                    ib_user_id=ib_id,
                    client_user_id=client_id,
                    plan_id=plan_id or None,
                    status=IBRequest.Status.APPROVED,
                    processed_at=timezone.now(),
                    notes="Moved by admin",
                )
                messages.success(request, "Client assigned under IB.")
                try:
                    from ib.level_progress import maybe_queue_level_upgrade, refresh_referral_count

                    ib_master = User.objects.filter(id=ib_id).first()
                    if ib_master:
                        refresh_referral_count(ib_master, increment_period=True)
                        maybe_queue_level_upgrade(ib_master)
                except Exception:
                    pass
        elif action == "unassign" and client_id:
            IBRequest.objects.filter(client_user_id=client_id, status=IBRequest.Status.APPROVED).update(status=IBRequest.Status.REJECTED, processed_at=timezone.now(), notes="Unassigned by admin")
            messages.success(request, "Client unassigned from IB.")
        return redirect("admin-ib-move-client")
    q = (request.GET.get("q") or "").strip()
    status = (request.GET.get("status") or "").strip().upper()
    ib_filter = (request.GET.get("ib_user") or "").strip()
    rows = IBRequest.objects.select_related("ib_user", "client_user", "plan").order_by("-requested_at")
    if q:
        rows = rows.filter(Q(client_user__email__icontains=q) | Q(client_user__first_name__icontains=q) | Q(client_user__last_name__icontains=q))
    if status in {"APPROVED", "REJECTED"}:
        rows = rows.filter(status=status)
    if ib_filter:
        rows = rows.filter(ib_user_id=ib_filter)
    paginator = Paginator(rows, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(request, "admin_panel/ib_move_client.html", {"ib_users": ib_users, "clients": clients, "plans": plans, "page_obj": page_obj, "filters": {"q": q, "status": status, "ib_user": ib_filter}})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def ib_commission_report_page(request):
    ib_user_id = (request.GET.get("ib_user") or "").strip()
    from_date = request.GET.get("from") or ""
    to_date = request.GET.get("to") or ""
    q = (request.GET.get("q") or "").strip()
    qs = (
        Transaction.objects.filter(tx_type=Transaction.TxType.IB_WITHDRAW)
        .exclude(from_user_id=F("actor_id"))
        .select_related("actor")
        .order_by("-created_at")
    )
    if ib_user_id:
        qs = qs.filter(actor_id=ib_user_id)
    if from_date:
        qs = qs.filter(created_at__date__gte=from_date)
    if to_date:
        qs = qs.filter(created_at__date__lte=to_date)
    if q:
        qs = qs.filter(Q(actor__email__icontains=q) | Q(notes__icontains=q) | Q(reference__icontains=q))
    by_ib = qs.values("actor_id", "actor__email").annotate(total_commission=Sum("amount"), lots=Count("id"))
    total_commission = qs.aggregate(total=Sum("amount"))["total"] or 0
    total_volume = by_ib.aggregate(total=Sum("lots"))["total"] or 0
    total_trades = qs.count()
    total_profit = qs.aggregate(v=Sum("amount"))["v"] or 0
    paginator = Paginator(qs, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    if (request.GET.get("export") or "").lower() == "excel":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="ib_commission_report.csv"'
        w = csv.writer(response)
        w.writerow(["ID", "MT5 ID", "Date", "Order", "Symbol", "Price", "Profit", "Volume", "My Commission", "Commission Type", "Level", "Client Name"])
        for t in qs[:5000]:
            level_name = "-"
            if t.actor and hasattr(t.actor, "ib_profile") and t.actor.ib_profile.ib_level:
                level_name = t.actor.ib_profile.ib_level.name
            w.writerow([t.id, t.reference or "-", timezone.localtime(t.created_at).strftime("%Y-%m-%d %H:%M"), t.id, "-", t.amount, t.amount, 1, t.amount, "IB_WITHDRAW", level_name, t.actor.display_name() if t.actor else "-"])
        return response
    return render(
        request,
        "admin_panel/ib_commission_report.html",
        {
            "rows": by_ib,
            "page_obj": page_obj,
            "total_commission": total_commission,
            "total_volume": total_volume,
            "total_trades": total_trades,
            "total_profit": total_profit,
            "ib_users": User.objects.filter(role=User.Roles.IB).order_by("email"),
            "filters": {"from": from_date, "to": to_date, "ib_user": ib_user_id, "q": q},
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def placeholder_page(request, title: str):
    """
    Minimal working placeholders for the many admin routes requested.
    These routes are wired so the project runs; implement real CRUD later.
    """
    url_name = getattr(request.resolver_match, "url_name", "") or ""

    # For speed-to-production, most admin panel pages forward to Django's built-in admin CRUD.
    # The custom admin panel dashboard remains custom; all management pages become fully functional.
    redirects = {
        # Bonus
        "admin-bonus-give": "/django-admin/accounts/bonus/add/",
        "admin-bonus-remove": "/django-admin/accounts/bonus/add/",
        "admin-bonus-list": "/django-admin/accounts/bonus/",
        "admin-bonus-assign": "/django-admin/accounts/bonus/add/",
        "admin-bonus-rules": "/django-admin/accounts/bonus/",

        # IB Management
        "admin-ib-dashboard": "/django-admin/ib/ibrequest/",
        "admin-ib-users": "/django-admin/accounts/user/",
        "admin-ib-requests": "/django-admin/ib/ibrequest/?status__exact=PENDING",
        "admin-ib-plan": "/django-admin/ib/ibplan/",
        "admin-ib-commission-group": "/django-admin/ib/commissiongroup/",
        "admin-ib-set-commission": "/django-admin/ib/ibcommissionrule/add/",
        "admin-ib-move-client": "/django-admin/accounts/user/",
        "admin-ib-commission-report": "/django-admin/ib/ibrequest/",

        # Transaction
        "admin-client-deposit": "/django-admin/transactions/transaction/?tx_type__exact=CLIENT_DEPOSIT",
        "admin-client-withdraw": "/django-admin/transactions/transaction/?tx_type__exact=CLIENT_WITHDRAW",
        "admin-wallet-deposit": "/django-admin/transactions/transaction/?tx_type__exact=WALLET_DEPOSIT",
        "admin-wallet-withdraw": "/django-admin/transactions/transaction/?tx_type__exact=WALLET_WITHDRAW",
        "admin-internal-transfer": "/django-admin/transactions/transaction/?tx_type__exact=INTERNAL_TRANSFER",
        
        # Marketing
        "admin-marketing-add": "/django-admin/marketing/marketingcampaign/add/",
        "admin-marketing-list": "/django-admin/marketing/marketingcampaign/",
        "admin-incentive-report": "/django-admin/marketing/marketingwithdrawrequest/",
        "admin-marketing-withdraw-report": "/django-admin/marketing/marketingwithdrawrequest/",
        "admin-bulk-lead-upload": "/django-admin/marketing/lead/add/",
        "admin-lead-list": "/django-admin/marketing/lead/",

        # Copier
        "admin-copier-accounts": "/django-admin/copier/copytradingaccount/",
        "admin-copier-management": "/django-admin/copier/copierfollower/",
        "admin-copier-all-rules": "/django-admin/copier/copytradingaccount/",
        "admin-copier-symbol-translations": "/django-admin/copier/copierrule/",
        "admin-copier-assign-rules": "/django-admin/copier/copierfollower/",
        "admin-copier-connection-requests": "/django-admin/copier/copierfollower/",
        "admin-copier-connections": "/django-admin/copier/copierfollower/",

        # Email
        "admin-send-email": "/django-admin/",
        "admin-email-templates": "/admin/email/management/",
        "admin-bulk-email": "/django-admin/",
        "admin-email-history": "/django-admin/",

        # Reports/analytics fallbacks
        "admin-report-active-traders": "/admin-panel/users/list/?status=ACTIVE",
        "admin-report-ib-performance": "/admin-panel/ib/dashboard/",
        "admin-report-ib-withdrawal": "/admin-panel/payments/requests/?type=withdraw",
        "admin-report-trading-volume": "/admin-panel/reports/trading/mt5/",

        # Transaction sub-modules
        "admin-client-deposit": "/admin-panel/payments/requests/?type=deposit",
        "admin-client-withdraw": "/admin-panel/payments/requests/?type=withdraw",
        "admin-wallet-deposit": "/admin-panel/payments/requests/?type=deposit",
        "admin-wallet-withdraw": "/admin-panel/payments/requests/?type=withdraw",

        # Group management (CRM UI)
        "admin-group-add": "/admin-panel/crm/group-management/add/",
        "admin-group-list": "/admin-panel/crm/group-management/list/",
        "admin-group-edit": "/admin-panel/crm/group-management/edit/",
        "admin-groups": "/admin-panel/crm/group-management/list/",
        "admin-account-types": "/admin-panel/crm/account-management/account-types/list/",
        "admin-account-type-add": "/admin-panel/crm/account-management/account-types/add/",
        "admin-account-type-list": "/admin-panel/crm/account-management/account-types/list/",
        "admin-account-type-edit": "/admin-panel/crm/account-management/account-types/edit/",

        # Marketing/Copier/News
        "admin-marketing-add": "/django-admin/marketing/marketingcampaign/add/",
        "admin-marketing-list": "/django-admin/marketing/marketingcampaign/",
        "admin-incentive-report": "/django-admin/marketing/marketingwithdrawrequest/",
        "admin-marketing-withdraw-report": "/django-admin/marketing/marketingwithdrawrequest/",
        "admin-bulk-lead-upload": "/django-admin/marketing/lead/add/",
        "admin-lead-list": "/django-admin/marketing/lead/",
        "admin-copier-accounts": "/django-admin/copier/copytradingaccount/",
        "admin-copier-management": "/django-admin/copier/copierfollower/",
        "admin-copier-all-rules": "/django-admin/copier/copierrule/",
        "admin-copier-symbol-translations": "/django-admin/copier/copierrule/",
        "admin-copier-assign-rules": "/django-admin/copier/copierfollower/",
        "admin-copier-connection-requests": "/django-admin/copier/copierfollower/",
        "admin-copier-connections": "/django-admin/copier/copierfollower/",
        "admin-news-add": "/django-admin/admin_panel/emailinboxmessage/add/",
        "admin-news-list": "/django-admin/admin_panel/emailinboxmessage/",

        # Notifications/rewards/tickets/settings
        "admin-notification-unread": "/admin-panel/compliance/reviews/",
        "admin-notification-read": "/admin-panel/compliance/reviews/",
        "admin-tickets": "/admin-panel/email/inbox/",
        "admin-setting-deposit-bank-details": "/admin-panel/users/bank-details/list/",
        "admin-setting-promotion-list": "/admin-panel/marketing/list/",
        "admin-setting-psp": "/admin-panel/settings/treasury/deposit-methods/",
        "admin-setting-default": "/admin-panel/settings/sidebar-ui/",
        "admin-setting-ib-request-terms": "/admin-panel/ib/requests/",

        # Legacy overview links
        "admin-clients": "/admin-panel/users/list/",
        "admin-ib-overview": "/admin-panel/ib/dashboard/",
        "admin-compliance-overview": "/admin-panel/compliance/reviews/",
        "admin-ib-withdrawals": "/admin-panel/reports/ib/commission/",
        "admin-active-traders": "/admin-panel/users/list/?status=ACTIVE",
        "admin-analytics-clients": "/admin-panel/users/list/",
        "admin-analytics-deposits": "/admin-panel/payments/requests/?type=deposit",
        "admin-analytics-withdrawals": "/admin-panel/payments/requests/?type=withdraw",
        "admin-analytics-ib": "/admin-panel/ib/dashboard/",
        "admin-analytics-revenue": "/admin-panel/reports/financial/transactions/",
    }

    if url_name in redirects:
        return redirect(redirects[url_name])

    return render(request, "admin_panel/placeholder.html", {"title": title})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def admin_sidebar_settings(request):
    return render(request, "admin_panel/sidebar_settings.html")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def sub_admin_users_page(request):
    if request.method == "POST":
        action = request.POST.get("action") or "create"
        if action == "create":
            first_name = (request.POST.get("first_name") or "").strip()
            email = (request.POST.get("email") or "").strip().lower()
            password = request.POST.get("password") or ""
            role = (request.POST.get("role") or User.Roles.BANKER).upper()
            if not first_name or not email or len(password) < 8:
                messages.error(request, "Name, email and min 8-char password are required.")
            elif User.objects.filter(email__iexact=email).exists():
                messages.error(request, "Email already exists.")
            else:
                username_base = email.split("@")[0] if "@" in email else email
                username = username_base
                idx = 0
                while User.objects.filter(username=username).exists():
                    idx += 1
                    username = f"{username_base}_{idx}"
                user = User.objects.create_user(
                    username=username[:150],
                    email=email,
                    password=password,
                    first_name=first_name[:150],
                    role=role if role in {User.Roles.ADMIN, User.Roles.BANKER} else User.Roles.BANKER,
                    is_staff=True,
                    is_active=True,
                )
                group_ids = request.POST.getlist("group_ids")
                if group_ids:
                    user.groups.set(Group.objects.filter(id__in=group_ids))
                messages.success(request, f"Sub admin created: {user.email}")
                log_audit(
                    action="STAFF_CREATE",
                    entity_type="User",
                    entity_id=str(user.id),
                    actor=request.user,
                    channel=AuditLogChannel.STAFF,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"email": user.email, "role": user.role},
                )
                return redirect("admin-settings-staff")
        elif action == "toggle":
            uid = request.POST.get("user_id") or ""
            su = User.objects.filter(id=uid, role__in=[User.Roles.ADMIN, User.Roles.BANKER]).first()
            if su:
                su.is_active = not su.is_active
                su.save(update_fields=["is_active"])
                messages.success(request, "Sub admin status updated.")
                log_audit(
                    action="STAFF_TOGGLE_ACTIVE",
                    entity_type="User",
                    entity_id=str(su.id),
                    actor=request.user,
                    channel=AuditLogChannel.STAFF,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"is_active": su.is_active},
                )
            return redirect("admin-settings-staff")

    groups = Group.objects.order_by("name")
    staff_qs = User.objects.filter(role__in=[User.Roles.ADMIN, User.Roles.BANKER], is_superuser=False)
    users = staff_qs.order_by("-date_joined")[:500]
    ws = WalletTreasurySettings.get_solo()
    staff_stats = {
        "total_staff": staff_qs.count(),
        "active_now": staff_qs.filter(is_active=True).count(),
        "treasury_wallet_on": ws.wallet_system_enabled,
    }
    return render(
        request,
        "admin_panel/sub_admin_users.html",
        {
            "title": "Staff Management",
            "users": users,
            "groups": groups,
            "staff_stats": staff_stats,
            "sales_nav_active": "staff_management",
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def role_management_page(request):
    if request.method == "POST":
        action = request.POST.get("action") or "create"
        if action == "create":
            role_name = (request.POST.get("role_name") or "").strip()
            if not role_name:
                messages.error(request, "Role name is required.")
            else:
                g, created = Group.objects.get_or_create(name=role_name)
                messages.success(request, "Role created.")
                if created:
                    log_audit(
                        action="ROLE_CREATE",
                        entity_type="Group",
                        entity_id=str(g.id),
                        actor=request.user,
                        channel=AuditLogChannel.STAFF,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"name": role_name},
                    )
                return redirect("admin-settings-roles")
        elif action == "update":
            gid = request.POST.get("group_id") or ""
            group = Group.objects.filter(id=gid).first()
            if not group:
                messages.error(request, "Role not found.")
            else:
                perm_ids = request.POST.getlist("perm_ids")
                group.permissions.set(Permission.objects.filter(id__in=perm_ids))
                messages.success(request, "Role permissions updated.")
                log_audit(
                    action="ROLE_PERMISSIONS_UPDATE",
                    entity_type="Group",
                    entity_id=str(group.id),
                    actor=request.user,
                    channel=AuditLogChannel.STAFF,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"perm_count": len(perm_ids)},
                )
                return redirect("admin-settings-roles")

    groups = Group.objects.prefetch_related("permissions").order_by("name")
    perms = Permission.objects.select_related("content_type").order_by("content_type__app_label", "codename")
    return render(
        request,
        "admin_panel/role_management.html",
        {
            "title": "Role Management",
            "groups": groups,
            "perms": perms,
            "sales_nav_active": "staff_roles",
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def permission_management_page(request):
    if request.method == "POST":
        uid = request.POST.get("user_id") or ""
        user = User.objects.filter(id=uid, role__in=[User.Roles.ADMIN, User.Roles.BANKER], is_superuser=False).first()
        if not user:
            messages.error(request, "User not found.")
        else:
            group_ids = request.POST.getlist("group_ids")
            user.groups.set(Group.objects.filter(id__in=group_ids))
            direct_perm_ids = request.POST.getlist("direct_perm_ids")
            user.user_permissions.set(Permission.objects.filter(id__in=direct_perm_ids))
            messages.success(request, "Permission mapping updated.")
            log_audit(
                action="STAFF_PERMISSIONS_UPDATE",
                entity_type="User",
                entity_id=str(user.id),
                actor=request.user,
                channel=AuditLogChannel.STAFF,
                request=request,
                ip=get_client_ip(request),
                metadata={"groups": len(group_ids), "direct_perms": len(direct_perm_ids)},
            )
            return redirect("admin-access-control")

    users = User.objects.filter(role__in=[User.Roles.ADMIN, User.Roles.BANKER], is_superuser=False).order_by("email")
    groups = Group.objects.order_by("name")
    perms = Permission.objects.select_related("content_type").order_by("content_type__app_label", "codename")
    return render(request, "admin_panel/permission_management.html", {"title": "Permission Management", "users": users, "groups": groups, "perms": perms})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def pending_deposit(request):
    list_status = _parse_list_status(request, "pending")
    query_ex_status = _querystring_excluding(request, "status")

    gateway_id = request.GET.get("gateway") or ""
    currency = request.GET.get("currency") or ""
    email = request.GET.get("email") or ""

    deposit_types = [
        Transaction.TxType.PENDING_DEPOSIT,
        Transaction.TxType.CLIENT_DEPOSIT,
        Transaction.TxType.WALLET_DEPOSIT,
    ]
    base_counts = Transaction.objects.filter(tx_type__in=deposit_types)
    status_counts = {
        "pending": base_counts.filter(status=Transaction.Status.PENDING).count(),
        "approved": base_counts.filter(
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
        ).count(),
        "rejected": base_counts.filter(status=Transaction.Status.REJECTED).count(),
    }

    qs = Transaction.objects.select_related("actor", "payment_gateway").filter(tx_type__in=deposit_types)
    if list_status == "approved":
        qs = qs.filter(status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])
    elif list_status == "rejected":
        qs = qs.filter(status=Transaction.Status.REJECTED)
    else:
        qs = qs.filter(status=Transaction.Status.PENDING)

    if gateway_id:
        qs = qs.filter(payment_gateway_id=gateway_id)
    if currency:
        qs = qs.filter(currency=currency)
    if email:
        qs = qs.filter(actor__email__icontains=email)

    redirect_qs = request.GET.urlencode()
    back_url = f"{reverse('admin-pending-deposit')}?{redirect_qs}" if redirect_qs else reverse("admin-pending-deposit")

    if request.method == "POST":
        tx_id = request.POST.get("tx_id") or ""
        action = request.POST.get("action") or ""

        tx = Transaction.objects.select_related("actor", "payment_gateway").filter(
            id=tx_id,
            status=Transaction.Status.PENDING,
            tx_type__in=[
                Transaction.TxType.PENDING_DEPOSIT,
                Transaction.TxType.CLIENT_DEPOSIT,
                Transaction.TxType.WALLET_DEPOSIT,
            ],
        ).first()

        if not tx:
            messages.error(request, "Transaction not found (or not pending anymore).")
            return redirect(back_url)

        if action == "approve":
            from transactions.models import ProcessedAction
            from transactions.utils import ensure_unique_action

            action_key = f"DEPOSIT_{tx.id}"

            def _release_deposit_action_lock():
                ProcessedAction.objects.filter(
                    unique_id=action_key, action_type="DEPOSIT_APPROVE"
                ).delete()

            try:
                ensure_unique_action(action_key, "DEPOSIT_APPROVE")
            except ValueError as e:
                messages.error(request, str(e))
                return redirect(back_url)

            with db_transaction.atomic():
                tx = Transaction.objects.select_for_update().get(id=tx.id)
                if tx.status != Transaction.Status.PENDING:
                    _release_deposit_action_lock()
                    messages.error(request, "Transaction not pending anymore.")
                    return redirect(back_url)
                user = User.objects.select_for_update().get(id=tx.actor_id)
                amt = Decimal(str(tx.amount or 0))

                target_account = None
                if tx.notes and "Target Account:" in tx.notes:
                    for line in tx.notes.split("\n"):
                        if line.startswith("Target Account:"):
                            val = line.replace("Target Account:", "").strip()
                            if val.lower() != "wallet":
                                target_account = val
                            break

                if target_account:
                    try:
                        from admin_panel.models import TradingAccount
                        from btrader_integration.services import (
                            deposit_btrader_balance,
                            is_btrader_account_row,
                            sync_account as sync_btrader_account,
                        )

                        t_acc = (
                            TradingAccount.objects.select_related(
                                "mt5_account", "mt5_account__group"
                            )
                            .filter(account_number=target_account, user=user)
                            .first()
                        )
                        if not t_acc:
                            _release_deposit_action_lock()
                            messages.error(request, "Target trading account not found.")
                            return redirect(back_url)

                        login = str(
                            getattr(getattr(t_acc, "mt5_account", None), "login_id", None)
                            or target_account
                        )

                        if is_btrader_account_row(trading_account=t_acc):
                            deposit_btrader_balance(
                                login=login,
                                amount=float(amt),
                                comment=f"Deposit #{tx.id}",
                                external_ref=f"crm-deposit-{tx.id}",
                            )
                            tx.status = Transaction.Status.APPROVED
                            tx.processed_at = timezone.now()
                            tx.save(update_fields=["status", "processed_at"])
                            t_acc.refresh_from_db()
                            if t_acc.mt5_account_id:
                                t_acc.mt5_account.refresh_from_db()
                                t_acc.balance = Decimal(str(t_acc.mt5_account.balance or 0))
                                t_acc.save(update_fields=["balance", "updated_at"])
                            messages.success(
                                request,
                                f"Approved deposit #{tx.id} to BTrader account {target_account}.",
                            )
                            db_transaction.on_commit(
                                lambda login=login: sync_btrader_account(login)
                            )
                        else:
                            from mt5_integration.services import mt5_balance_deposit, sync_account

                            mt5_login = int(login)
                            mt5_balance_deposit(mt5_login, float(amt), f"Deposit #{tx.id}")

                            tx.status = Transaction.Status.APPROVED
                            tx.processed_at = timezone.now()
                            tx.save(update_fields=["status", "processed_at"])
                            messages.success(
                                request,
                                f"Approved deposit #{tx.id} to account {target_account}.",
                            )
                            # Defer sync until after DB commit so locks are released.
                            db_transaction.on_commit(lambda: sync_account(mt5_login))
                    except Exception as e:
                        _release_deposit_action_lock()
                        logger.error("Trading deposit failed for tx %s: %s", tx.id, e)
                        messages.error(
                            request,
                            "Failed to deposit to trading account. Check platform integration.",
                        )
                        return redirect(back_url)
                else:
                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    user.wallet_balance = wallet_before + amt
                    user.save(update_fields=["wallet_balance"])
                    tx.status = Transaction.Status.APPROVED
                    tx.processed_at = timezone.now()
                    tx.save(update_fields=["status", "processed_at"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.DEPOSIT_APPROVE,
                        amount=amt,
                        currency=tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=Decimal(str(user.pending_withdraw or 0)),
                        pending_after=Decimal(str(user.pending_withdraw or 0)),
                        reference=str(tx.id),
                        note="Deposit approved",
                    )
                    messages.success(request, f"Approved deposit #{tx.id} to Wallet.")
                try:
                    log_audit(
                        action="DEPOSIT_APPROVE",
                        entity_type="Transaction",
                        entity_id=str(tx.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"amount": str(tx.amount), "currency": tx.currency},
                    )
                except Exception:
                    pass
                try:
                    send_event_email(
                        "deposit_approved",
                        to_email=user.email,
                        user=user,
                        extra_context={
                            "name": user.display_name(),
                            "client_name": user.display_name(),
                            "amount": f"{tx.amount} {tx.currency}",
                            "deposit_amount": f"{tx.amount} {tx.currency}",
                            "payment_method": tx.payment_gateway.name if tx.payment_gateway else "-",
                            "transaction_id": str(tx.id),
                            "date": timezone.localtime(tx.processed_at).strftime("%Y-%m-%d %H:%M") if tx.processed_at else "",
                        },
                    )
                except Exception:
                    pass
                try:
                    from ib.level_progress import bump_team_deposit_from_transaction, maybe_queue_level_upgrade

                    bump_team_deposit_from_transaction(tx.actor_id, tx.amount)
                    lk = IBRequest.objects.filter(client_user_id=tx.actor_id, status=IBRequest.Status.APPROVED).first()
                    if lk:
                        maybe_queue_level_upgrade(lk.ib_user)
                except Exception:
                    pass
        elif action == "reject":
            from transactions.utils import ensure_unique_action
            try:
                ensure_unique_action(f"DEPOSIT_REJ_{tx.id}", "DEPOSIT_REJECT")
            except ValueError as e:
                messages.error(request, str(e))
                return redirect(back_url)
                
            reject_reason = (request.POST.get("reject_reason") or "").strip()
            if not reject_reason:
                messages.error(request, "Reject reason is required.")
                return redirect(back_url)
            tx.status = Transaction.Status.REJECTED
            tx.processed_at = timezone.now()
            tx.reject_reason = reject_reason
            tx.save(update_fields=["status", "processed_at", "reject_reason"])
            if not BalanceLedger.objects.filter(
                reference=str(tx.id), entry_type=BalanceLedger.EntryType.DEPOSIT_REJECT
            ).exists():
                rej_user = User.objects.filter(id=tx.actor_id).first()
                if rej_user:
                    amt_rej = Decimal(str(tx.amount or 0))
                    wb = Decimal(str(rej_user.wallet_balance or 0))
                    pb = Decimal(str(rej_user.pending_withdraw or 0))
                    BalanceLedger.objects.create(
                        user=rej_user,
                        entry_type=BalanceLedger.EntryType.DEPOSIT_REJECT,
                        amount=amt_rej,
                        currency=tx.currency,
                        wallet_before=wb,
                        wallet_after=wb,
                        pending_before=pb,
                        pending_after=pb,
                        reference=str(tx.id),
                        note="Deposit rejected",
                    )
            messages.success(request, f"Rejected deposit #{tx.id}.")
            log_audit(
                action="DEPOSIT_REJECT",
                entity_type="Transaction",
                entity_id=str(tx.id),
                actor=request.user,
                channel=AuditLogChannel.ADMIN,
                request=request,
                ip=get_client_ip(request),
                metadata={"reject_reason": reject_reason},
            )
            rej_actor = User.objects.filter(id=tx.actor_id).first()
            if rej_actor:
                send_event_email(
                    "deposit_rejected",
                    to_email=rej_actor.email,
                    user=rej_actor,
                    extra_context={
                        "name": rej_actor.display_name(),
                        "client_name": rej_actor.display_name(),
                        "amount": f"{tx.amount} {tx.currency}",
                        "deposit_amount": f"{tx.amount} {tx.currency}",
                        "payment_method": tx.payment_gateway.name if tx.payment_gateway else "-",
                        "transaction_id": str(tx.id),
                        "date": timezone.localtime(tx.processed_at).strftime("%Y-%m-%d %H:%M") if tx.processed_at else "",
                        "reason": reject_reason,
                        "reject_reason": reject_reason,
                    },
                )
        else:
            messages.error(request, "Invalid action.")
        return redirect(back_url)

    gateways = PaymentGateway.objects.filter(is_active=True).order_by("name")
    currencies = sorted({c for c in base_counts.values_list("currency", flat=True) if c})

    return render(
        request,
        "admin_panel/pending_deposit.html",
        {
            "transactions": qs.order_by("-created_at"),
            "gateways": gateways,
            "currencies": currencies,
            "filters": {"gateway_id": gateway_id, "currency": currency, "email": email},
            "list_status": list_status,
            "status_counts": status_counts,
            "query_ex_status": query_ex_status,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def pending_withdraw(request):
    list_status = _parse_list_status(request, "pending")
    query_ex_status = _querystring_excluding(request, "status")

    gateway_id = request.GET.get("gateway") or ""
    currency = request.GET.get("currency") or ""
    email = request.GET.get("email") or ""

    withdraw_types = [
        Transaction.TxType.PENDING_WITHDRAW,
        Transaction.TxType.CLIENT_WITHDRAW,
        Transaction.TxType.WALLET_WITHDRAW,
        Transaction.TxType.PENDING_IB_WITHDRAW,
        Transaction.TxType.IB_WITHDRAW,
    ]
    base_counts = Transaction.objects.filter(tx_type__in=withdraw_types)
    status_counts = {
        "pending": base_counts.filter(status=Transaction.Status.PENDING).count(),
        "approved": base_counts.filter(
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
        ).count(),
        "rejected": base_counts.filter(status=Transaction.Status.REJECTED).count(),
    }

    qs = Transaction.objects.select_related("actor", "payment_gateway").filter(tx_type__in=withdraw_types)
    if list_status == "approved":
        qs = qs.filter(status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])
    elif list_status == "rejected":
        qs = qs.filter(status=Transaction.Status.REJECTED)
    else:
        qs = qs.filter(status=Transaction.Status.PENDING)

    if gateway_id:
        qs = qs.filter(payment_gateway_id=gateway_id)
    if currency:
        qs = qs.filter(currency=currency)
    if email:
        qs = qs.filter(actor__email__icontains=email)

    redirect_qs = request.GET.urlencode()
    back_url = f"{reverse('admin-pending-withdraw')}?{redirect_qs}" if redirect_qs else reverse("admin-pending-withdraw")

    if request.method == "POST":
        tx_id = request.POST.get("tx_id") or ""
        action = request.POST.get("action") or ""

        tx = Transaction.objects.select_related("actor", "payment_gateway").filter(
            id=tx_id,
            status=Transaction.Status.PENDING,
            tx_type__in=[
                Transaction.TxType.PENDING_WITHDRAW,
                Transaction.TxType.CLIENT_WITHDRAW,
                Transaction.TxType.WALLET_WITHDRAW,
                Transaction.TxType.PENDING_IB_WITHDRAW,
                Transaction.TxType.IB_WITHDRAW,
            ],
        ).first()

        if not tx:
            messages.error(request, "Transaction not found (or not pending anymore).")
            return redirect(back_url)

        if action in {"approve", "reject"}:
            reject_reason = (request.POST.get("reject_reason") or "").strip()
            if action == "reject" and not reject_reason:
                messages.error(request, "Reject reason is required.")
                return redirect(back_url)
            with db_transaction.atomic():
                tx = Transaction.objects.select_for_update().filter(id=tx.id).first()
                if not tx or tx.status != Transaction.Status.PENDING:
                    messages.error(request, "Transaction not pending anymore.")
                    return redirect(back_url)
                if tx.tx_type in [Transaction.TxType.PENDING_IB_WITHDRAW, Transaction.TxType.IB_WITHDRAW]:
                    if action == "approve":
                        from transactions.utils import ensure_unique_action
                        try:
                            ensure_unique_action(f"IB_WITHDRAW_APP_{tx.id}", "IB_WITHDRAW_APPROVE")
                        except ValueError as e:
                            messages.error(request, str(e))
                            return redirect(back_url)
                        tx.status = Transaction.Status.COMPLETED
                        tx.processed_by = request.user
                        tx.processed_at = timezone.now()
                        tx.save(update_fields=["status", "processed_by", "processed_at"])
                        messages.success(request, f"IB Withdrawal request of ${tx.amount} approved.")
                        try:
                            log_audit(
                                action="IB_WITHDRAW_APPROVE",
                                entity_type="Transaction",
                                entity_id=str(tx.id),
                                actor=request.user,
                                channel=AuditLogChannel.ADMIN,
                                request=request,
                                ip=get_client_ip(request),
                                metadata={"amount": str(tx.amount), "ib_user_id": tx.actor_id},
                            )
                        except Exception:
                            pass
                    elif action == "reject":
                        tx.status = Transaction.Status.REJECTED
                        tx.reject_reason = reject_reason or "Rejected by Admin."
                        tx.processed_by = request.user
                        tx.processed_at = timezone.now()
                        tx.save(update_fields=["status", "reject_reason", "processed_by", "processed_at"])
                        messages.success(request, f"IB Withdrawal request of ${tx.amount} rejected.")
                        try:
                            log_audit(
                                action="IB_WITHDRAW_REJECT",
                                entity_type="Transaction",
                                entity_id=str(tx.id),
                                actor=request.user,
                                channel=AuditLogChannel.ADMIN,
                                request=request,
                                ip=get_client_ip(request),
                                metadata={"amount": str(tx.amount), "ib_user_id": tx.actor_id, "reason": reject_reason},
                            )
                        except Exception:
                            pass
                    return redirect(back_url)

                user = User.objects.select_for_update().get(id=tx.actor_id)
                pending_amt = Decimal(str(user.pending_withdraw or 0))
                amt = Decimal(str(tx.amount or 0))

                if action == "approve":
                    from transactions.utils import ensure_unique_action
                    try:
                        ensure_unique_action(f"WITHDRAW_APP_{tx.id}", "WITHDRAW_APPROVE")
                    except ValueError as e:
                        messages.error(request, str(e))
                        return redirect(back_url)

                    if pending_amt < amt:
                        messages.error(
                            request,
                            "Cannot approve: client pending-withdrawal total is lower than this request. Refusing to avoid inconsistent balances.",
                        )
                        return redirect(back_url)
                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    if wallet_before < amt:
                        messages.error(
                            request,
                            "Cannot approve: client wallet balance is lower than this withdrawal amount.",
                        )
                        return redirect(back_url)
                    user.wallet_balance = wallet_before - amt
                    user.pending_withdraw = pending_amt - amt
                    user.save(update_fields=["wallet_balance", "pending_withdraw"])
                    tx.status = Transaction.Status.APPROVED
                    tx.processed_at = timezone.now()
                    tx.processed_by = request.user
                    tx.save(update_fields=["status", "processed_at", "processed_by"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.WITHDRAW_APPROVE,
                        amount=amt,
                        currency=tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=pending_amt,
                        pending_after=user.pending_withdraw,
                        reference=str(tx.id),
                        note="Withdrawal approved — wallet debited; pending reservation cleared",
                    )
                    messages.success(request, f"Approved withdraw #{tx.id}.")
                    try:
                        log_audit(
                            action="WITHDRAW_APPROVE",
                            entity_type="Transaction",
                            entity_id=str(tx.id),
                            actor=request.user,
                            channel=AuditLogChannel.ADMIN,
                            request=request,
                            ip=get_client_ip(request),
                            metadata={
                                "amount": str(tx.amount),
                                "currency": tx.currency,
                                "pending_before": str(pending_amt),
                                "pending_after": str(user.pending_withdraw),
                            },
                        )
                    except Exception:
                        pass
                else:
                    from transactions.utils import ensure_unique_action
                    try:
                        ensure_unique_action(f"WITHDRAW_REJ_{tx.id}", "WITHDRAW_REJECT")
                    except ValueError as e:
                        messages.error(request, str(e))
                        return redirect(back_url)

                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    user.pending_withdraw = max(pending_amt - amt, Decimal("0"))
                    user.save(update_fields=["pending_withdraw"])
                    tx.status = Transaction.Status.REJECTED
                    tx.processed_at = timezone.now()
                    tx.reject_reason = reject_reason
                    tx.processed_by = request.user
                    tx.save(update_fields=["status", "processed_at", "reject_reason", "processed_by"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.WITHDRAW_REJECT,
                        amount=amt,
                        currency=tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=pending_amt,
                        pending_after=user.pending_withdraw,
                        reference=str(tx.id),
                        note="Withdrawal rejected — reservation released (wallet was not debited before approval)",
                    )
                    messages.success(request, f"Rejected withdraw #{tx.id}.")
                    try:
                        log_audit(
                            action="WITHDRAW_REJECT",
                            entity_type="Transaction",
                            entity_id=str(tx.id),
                            actor=request.user,
                            channel=AuditLogChannel.ADMIN,
                            request=request,
                            ip=get_client_ip(request),
                            metadata={"reject_reason": reject_reason},
                        )
                    except Exception:
                        pass
            if action == "approve":
                t_done = Transaction.objects.select_related("actor").filter(id=tx_id).first()
                if t_done and t_done.actor:
                    try:
                        ok, _ = send_event_email(
                            "withdrawal_approved",
                            to_email=t_done.actor.email,
                            user=t_done.actor,
                            extra_context={
                                "name": t_done.actor.display_name(),
                                "client_name": t_done.actor.display_name(),
                                "amount": f"{t_done.amount} {t_done.currency}",
                                "withdrawal_amount": f"{t_done.amount} {t_done.currency}",
                                "method": t_done.payment_gateway.name if t_done.payment_gateway else "-",
                                "payment_method": t_done.payment_gateway.name if t_done.payment_gateway else "-",
                                "transaction_id": str(t_done.id),
                                "date": timezone.localtime(t_done.processed_at).strftime("%Y-%m-%d %H:%M") if t_done.processed_at else "",
                            },
                        )
                    except Exception:
                        logger.exception("withdrawal_approved email failed", extra={"tx_id": t_done.id})
            elif action == "reject":
                t_done = Transaction.objects.select_related("actor").filter(id=tx_id).first()
                if t_done and t_done.actor:
                    try:
                        ok, _ = send_event_email(
                            "withdrawal_rejected",
                            to_email=t_done.actor.email,
                            user=t_done.actor,
                            extra_context={
                                "name": t_done.actor.display_name(),
                                "client_name": t_done.actor.display_name(),
                                "amount": f"{t_done.amount} {t_done.currency}",
                                "withdrawal_amount": f"{t_done.amount} {t_done.currency}",
                                "method": t_done.payment_gateway.name if t_done.payment_gateway else "-",
                                "payment_method": t_done.payment_gateway.name if t_done.payment_gateway else "-",
                                "transaction_id": str(t_done.id),
                                "date": timezone.localtime(t_done.processed_at).strftime("%Y-%m-%d %H:%M") if t_done.processed_at else "",
                                "reason": reject_reason,
                                "reject_reason": reject_reason,
                            },
                        )
                    except Exception:
                        logger.exception("withdrawal_rejected email failed", extra={"tx_id": t_done.id})
        else:
            messages.error(request, "Invalid action.")
        return redirect(back_url)

    gateways = PaymentGateway.objects.filter(is_active=True).order_by("name")
    currencies = sorted({c for c in base_counts.values_list("currency", flat=True) if c})

    transactions = qs.select_related("actor", "payment_gateway", "processed_by").order_by("-created_at")

    actor_ids = list(transactions.values_list("actor_id", flat=True).distinct())

    # Latest MT5 account per user (for "account details" on this approval screen)
    latest_accounts = {}
    for acc in MT5Account.objects.filter(user_id__in=actor_ids).select_related("group").order_by("user_id", "-updated_at"):
        if acc.user_id not in latest_accounts:
            latest_accounts[acc.user_id] = acc

    rows = []
    for t in transactions:
        actor = t.actor
        mt5 = latest_accounts.get(t.actor_id)
        acct_display = str(mt5.login_id) if mt5 else _withdraw_destination_line(t.account_details)
        method_label = "—"
        if t.payment_gateway:
            gw = t.payment_gateway
            pm = gw.get_payment_method_display()
            method_label = f"{gw.name} — {pm}"
        rows.append(
            {
                "tx": t,
                "latest_account": mt5,
                "live_wallet": actor.wallet_balance,
                "live_pending": actor.pending_withdraw,
                "account_display": acct_display,
                "destination_line": _withdraw_destination_line(t.account_details),
                "method_label": method_label,
                "funds_source_label": "Wallet (client withdrawal)",
                "transfers_filter_email": actor.email or "",
            }
        )

    return render(
        request,
        "admin_panel/pending_withdraw.html",
        {
            "rows": rows,
            "gateways": gateways,
            "currencies": currencies,
            "filters": {"gateway_id": gateway_id, "currency": currency, "email": email},
            "list_status": list_status,
            "status_counts": status_counts,
            "query_ex_status": query_ex_status,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def dashboard_settings(request):
    settings_obj = DashboardSettings.get_solo()
    if request.method == "POST":
        bool_fields = [
            "show_my_accounts",
            "show_balance",
            "show_trading_accounts",
            "show_buttons",
            "show_profile_menu",
            "enable_deposit_button",
            "enable_withdraw_button",
            "enable_trade_button",
            "enable_open_new_account",
            "enable_real_demo_tabs",
            "enable_account_dropdown_menu",
            "enforce_wallet_only_withdrawal",
            # Sidebar toggles
            "show_sidebar_dashboard",
            "show_sidebar_regulations",
            "show_sidebar_my_fund",
            "show_sidebar_ib_programme",
            "show_sidebar_my_wallet",
            "show_sidebar_trading",
            "show_sidebar_competition",
            "show_sidebar_trade_and_win",
            "show_sidebar_news",
            "show_sidebar_my_data",
            "show_sidebar_support",
            # IB submenu
            "enable_ib_dashboard",
            "enable_ib_my_clients",
            "enable_ib_tree_chart",
            "enable_ib_my_commission",
            "enable_ib_withdraw",
            "enable_team_deposit_report",
            "enable_team_withdraw_report",
            # My Data submenu
            "enable_deposit_report",
            "enable_withdraw_report",
            "enable_internal_transfers_report",
            "enable_deal_report",
            "enable_summary_report",
        ]
        for field in bool_fields:
            setattr(settings_obj, field, request.POST.get(field) == "on")
        settings_obj.save()
        messages.success(request, "Dashboard settings updated.")
        return redirect("admin-dashboard-settings")

    return render(request, "admin_panel/dashboard_settings.html", {"s": settings_obj})


@login_required
@role_required([User.Roles.ADMIN])
@require_http_methods(["GET"])
def admin_profile_page(request):
    return redirect("admin-organization-profile")


@method_decorator(login_required, name="dispatch")
@method_decorator(role_required([User.Roles.ADMIN, User.Roles.BANKER]), name="dispatch")
class AdminProfilePasswordChangeView(PasswordChangeView):
    template_name = "admin/profile/password_change.html"
    success_url = reverse_lazy("admin-profile-password-change")

    def form_valid(self, form):
        response = super().form_valid(form)
        messages.success(self.request, "Password changed successfully.")
        return response

    def form_invalid(self, form):
        messages.error(self.request, "Please fix the password form errors.")
        return super().form_invalid(form)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def system_settings_hub(request):
    sections = [
        {"title": "Client portal white label", "url_name": "admin-white-label-hub"},
        {"title": "Theme & UI Settings", "url_name": "admin-branding-logo"},
        {"title": "Sidebar & Portal UI", "url_name": "admin-sidebar-settings"},
        {"title": "Dashboard Settings", "url_name": "admin-dashboard-settings"},
        {"title": "Account Types", "url_name": "admin-account-types"},
        {"title": "Demo Settings", "url_name": "admin-demo-account-settings"},
        {"title": "Group Management", "url_name": "admin-groups"},
        {"title": "Organization Profile", "url_name": "admin-organization-profile"},
        {"title": "Legal Agreements", "url_name": "admin-legal-agreements"},
        {"title": "Trading Platform (User Side)", "url_name": "admin-trading-platform-settings"},
        {"title": "Trading Platform Integration", "url_name": "admin-integrations-trading-platforms-hub"},
        {"title": "Treasury / Wallet / Withdraw", "url_name": "admin-treasury-hub"},
        {"title": "Compliance Settings", "url_name": "admin-compliance-settings"},
        {"title": "Email Templates", "url_name": "admin-email-templates"},
        {"title": "Email Settings & Automation", "url_name": "admin-email-management"},
        {"title": "Chat Settings", "url_name": "admin-chat-settings"},
        {"title": "Tickets Dashboard", "url_name": "admin-tickets"},
    ]
    return render(request, "admin_panel/system_settings_hub.html", {"sections": sections})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def demo_account_settings(request):
    obj = DemoAccountSettings.get_solo()
    account_types = TradingAccountType.objects.filter(is_active=True).order_by("display_order", "account_name")
    groups = MT5Group.objects.filter(is_active=True).order_by("crm_group_name", "name")
    if request.method == "POST":
        obj.auto_create_on_signup = request.POST.get("auto_create_on_signup") == "on"
        try:
            obj.default_balance = Decimal(str(request.POST.get("default_balance") or "10000"))
        except Exception:
            obj.default_balance = Decimal("10000")
        try:
            obj.default_leverage = int(request.POST.get("default_leverage") or 500)
        except Exception:
            obj.default_leverage = 500
        obj.default_account_type = account_types.filter(id=request.POST.get("default_account_type")).first()
        obj.default_group = groups.filter(id=request.POST.get("default_group")).first()
        obj.save()
        messages.success(request, "Demo settings saved.")
        return redirect("admin-demo-account-settings")
    return render(
        request,
        "admin_panel/demo_account_settings.html",
        {"title": "Demo Settings", "obj": obj, "account_types": account_types, "groups": groups},
    )


PORTAL_BRANDING_FILE_FIELDS = (
    "admin_logo",
    "admin_favicon",
    "admin_login_logo",
    "admin_sidebar_logo",
    "user_logo",
    "user_favicon",
    "user_login_logo",
    "user_dashboard_logo",
    "user_dashboard_logo_dark",
)

_ADMIN_BRANDING_ROWS = (
    {"name": "admin_logo", "label": "Admin logo", "help": "Header and fallback for sidebar / login."},
    {"name": "admin_sidebar_logo", "label": "Admin sidebar logo", "help": "Optional override for the CRM sidebar only."},
    {"name": "admin_login_logo", "label": "Admin login logo", "help": "Sign-in page (falls back to admin logo)."},
    {"name": "admin_favicon", "label": "Admin favicon", "help": "Browser tab icon on /admin/…"},
)

_USER_BRANDING_ROWS = (
    {"name": "user_logo", "label": "User logo", "help": "General client portal fallback."},
    {"name": "user_dashboard_logo", "label": "User dashboard logo", "help": "Sidebar / dashboard header (falls back to user logo)."},
    {"name": "user_dashboard_logo_dark", "label": "User dashboard logo (dark)", "help": "Optional contrast variant for sidebar/header."},
    {"name": "user_login_logo", "label": "User login logo", "help": "Login and 2FA (falls back to user logo)."},
    {"name": "user_favicon", "label": "User favicon", "help": "Browser tab on /user/, /login, /register, etc."},
)


def _branding_rows_with_urls(portal, specs: tuple) -> list[dict]:
    v = int(portal.updated_at.timestamp()) if getattr(portal, "updated_at", None) else 1
    rows: list[dict] = []
    for s in specs:
        fld = getattr(portal, s["name"])
        url = ""
        if fld and fld.name:
            try:
                raw = fld.url
                sep = "&" if "?" in raw else "?"
                url = f"{raw}{sep}v={v}"
            except ValueError:
                url = ""
        rows.append({**s, "url": url})
    return rows


LOGIN_BRANDING_FILE_MAP = (
    ("lb_admin_login_logo", "admin_login_logo"),
    ("lb_admin_login_background", "admin_login_background"),
    ("lb_user_login_logo", "user_login_logo"),
    ("lb_user_login_background", "user_login_background"),
)


def _login_branding_file_rows(login_lb: LoginBrandingSettings) -> list[dict]:
    v = int(login_lb.updated_at.timestamp()) if getattr(login_lb, "updated_at", None) else 1
    specs = (
        ("lb_admin_login_logo", "admin_login_logo", "Admin login logo", "Recommended 300×100 px."),
        ("lb_admin_login_background", "admin_login_background", "Background image", "Recommended 1920×1080 px."),
        ("lb_user_login_logo", "user_login_logo", "User login logo", "Recommended 300×100 px."),
        ("lb_user_login_background", "user_login_background", "Background image", "Recommended 1920×1080 px."),
    )
    rows: list[dict] = []
    for post_key, fname, label, help_txt in specs:
        fld = getattr(login_lb, fname)
        url = ""
        if fld and fld.name:
            try:
                raw = fld.url
                sep = "&" if "?" in raw else "?"
                url = f"{raw}{sep}v={v}"
            except ValueError:
                url = ""
        rows.append({"post_key": post_key, "field_name": fname, "label": label, "help": help_txt, "url": url})
    return rows


def _save_auth_branding_from_request(request, inst, scope: str) -> str | None:
    """Persist admin or user auth branding. POST keys use prefix ``{scope}_`` (e.g. admin_company_name)."""
    p = f"{scope}_"
    logo_up = request.FILES.get(f"{p}logo")
    rem_logo = request.POST.get(f"{p}remove_logo") == "on"
    bg_up = request.FILES.get(f"{p}background_logo")
    rem_bg = request.POST.get(f"{p}remove_background_logo") == "on"

    if logo_up and getattr(logo_up, "name", None):
        err = branding_file_error(logo_up)
        if err:
            return err
    if bg_up and getattr(bg_up, "name", None):
        err = login_branding_file_error(bg_up)
        if err:
            return err

    if rem_logo:
        if inst.logo:
            inst.logo.delete(save=False)
        inst.logo = None
    elif logo_up:
        if inst.logo:
            inst.logo.delete(save=False)
        inst.logo = logo_up

    if rem_bg:
        if inst.background_logo:
            inst.background_logo.delete(save=False)
        inst.background_logo = None
    elif bg_up:
        if inst.background_logo:
            inst.background_logo.delete(save=False)
        inst.background_logo = bg_up

    inst.company_name = (request.POST.get(f"{p}company_name") or inst.company_name or "").strip() or "Burjex Prime"
    inst.welcome_text = (request.POST.get(f"{p}welcome_text") or "").strip() or "Welcome Back"
    inst.primary_color = (request.POST.get(f"{p}primary_color") or inst.primary_color or "#0B3C5D").strip()
    inst.secondary_color = (request.POST.get(f"{p}secondary_color") or inst.secondary_color or "#072A42").strip()
    inst.button_color = (request.POST.get(f"{p}button_color") or inst.button_color or "#0B3C5D").strip()
    inst.panel_background_color = (request.POST.get(f"{p}panel_background_color") or inst.panel_background_color or "#0f172a").strip()
    inst.font_style = (request.POST.get(f"{p}font_style") or inst.font_style or "Inter, system-ui, sans-serif").strip()[:200]

    try:
        inst.text_size_px = max(10, min(24, int(request.POST.get(f"{p}text_size_px") or inst.text_size_px)))
    except (TypeError, ValueError):
        pass
    try:
        inst.heading_size_px = max(16, min(48, int(request.POST.get(f"{p}heading_size_px") or inst.heading_size_px)))
    except (TypeError, ValueError):
        pass

    try:
        op = float(request.POST.get(f"{p}logo_opacity") or inst.logo_opacity or 0.1)
    except (TypeError, ValueError):
        op = 0.1
    inst.logo_opacity = max(0.05, min(0.2, op))

    logo_size = (request.POST.get(f"{p}logo_size") or inst.logo_size or "medium").strip().lower()
    if logo_size not in {c[0] for c in AuthBrandingLogoSize.choices}:
        logo_size = AuthBrandingLogoSize.MEDIUM
    inst.logo_size = logo_size

    logo_position = (request.POST.get(f"{p}logo_position") or inst.logo_position or "center").strip().lower()
    if logo_position not in {c[0] for c in AuthBrandingLogoPosition.choices}:
        logo_position = AuthBrandingLogoPosition.CENTER
    inst.logo_position = logo_position

    inst.save()
    return None


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def branding_logo(request):
    org = OrganizationProfileSettings.get_solo()

    asset_specs = (
        {
            "input_name": "company_logo",
            "field": "logo",
            "label": "Company logo",
            "help": "Fallback for all surfaces. Recommended 300×100 px.",
            "icon": "fa-image",
            "preview_id": "brandingLogoPreview",
            "preview_box": "w-44 h-28",
            "propagate": True,
        },
        {
            "input_name": "app_icon",
            "field": "app_icon",
            "label": "App icon",
            "help": "Mobile launcher icon. Recommended 1024×1024 px PNG (square).",
            "icon": "fa-mobile-screen",
            "preview_id": "brandingAppIconPreview",
            "preview_box": "w-28 h-28",
            "propagate": False,
        },
        {
            "input_name": "login_logo",
            "field": "login_logo",
            "label": "Login logo",
            "help": "Sign-in and splash. Recommended 600×200 px (full-bleed).",
            "icon": "fa-right-to-bracket",
            "preview_id": "brandingLoginLogoPreview",
            "preview_box": "w-56 h-24",
            "propagate": False,
        },
        {
            "input_name": "sidebar_logo",
            "field": "sidebar_logo",
            "label": "Sidebar logo",
            "help": "Admin/client sidebar and mobile drawer. Recommended 200×200 px.",
            "icon": "fa-bars",
            "preview_id": "brandingSidebarLogoPreview",
            "preview_box": "w-28 h-28",
            "propagate": False,
        },
    )

    if request.method == "POST":
        company_name = (request.POST.get("company_name") or "").strip()
        if not company_name:
            messages.error(request, "Company name is required.")
            return redirect("admin-branding-logo")

        try:
            with db_transaction.atomic():
                sync_company_name_globally(company_name)

                update_fields = ["updated_at"]
                for spec in asset_specs:
                    field_name = spec["field"]
                    if not hasattr(org, field_name):
                        continue
                    uploaded = request.FILES.get(spec["input_name"])
                    remove = request.POST.get(f"remove_{spec['input_name']}") == "on"
                    current = getattr(org, field_name)
                    if uploaded and getattr(uploaded, "name", None):
                        err = branding_file_error(uploaded)
                        if err:
                            messages.error(request, err)
                            return redirect("admin-branding-logo")
                        if current and current.name:
                            current.delete(save=False)
                        setattr(org, field_name, uploaded)
                        update_fields.append(field_name)
                        if spec.get("propagate"):
                            org.save(update_fields=[field_name, "updated_at"])
                            propagate_logo_globally(org.logo)
                    elif remove:
                        if current and current.name:
                            current.delete(save=False)
                        setattr(org, field_name, None)
                        update_fields.append(field_name)
                        if spec.get("propagate"):
                            clear_global_logos()

                org.save(update_fields=list(dict.fromkeys(update_fields)))
        except Exception:
            messages.error(request, MSG_UPLOAD_FAILED)
            return redirect("admin-branding-logo")

        messages.success(request, MSG_BRANDING_UPDATED)
        return redirect(f"{reverse('admin-branding-logo')}?saved=1")

    def _url(field):
        if field and getattr(field, "name", None):
            try:
                return field.url
            except (ValueError, AttributeError):
                return ""
        return ""

    branding_slots = []
    for spec in asset_specs:
        field = getattr(org, spec["field"], None) if hasattr(org, spec["field"]) else None
        branding_slots.append({**spec, "url": _url(field)})

    company_logo_url = branding_slots[0]["url"] if branding_slots else ""

    return render(
        request,
        "admin_panel/branding_settings.html",
        {
            "org": org,
            "company_logo_url": company_logo_url,
            "branding_slots": branding_slots,
            "saved_state": (request.GET.get("saved") or "").strip(),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def signup_fields_settings(request):
    s = SignupSettings.get_solo()
    if request.method == "POST":
        choices = {c[0] for c in SignupSettings.FieldMode.choices}
        for field in ["first_name_mode", "last_name_mode", "full_name_mode", "email_mode", "phone_mode", "password_mode", "country_mode", "address_mode"]:
            val = (request.POST.get(field) or "").upper()
            if val in choices:
                setattr(s, field, val)
        s.captcha_enabled = request.POST.get("captcha_enabled") == "on"
        s.save()
        messages.success(request, "Signup fields updated.")
        return redirect("admin-signup-fields-settings")
    return render(request, "admin_panel/signup_fields_settings.html", {"s": s, "modes": SignupSettings.FieldMode.choices})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_verification_settings_view(request):
    ev = EmailVerificationSettings.get_solo()
    smtp = SMTPSettings.get_solo()
    if request.method == "POST":
        ev.enabled = request.POST.get("enabled") == "on"
        ev.required = request.POST.get("required") == "on"
        ev.allow_resend = request.POST.get("allow_resend") == "on"
        expiry = request.POST.get("token_expiry_hours") or "24"
        try:
            ev.token_expiry_hours = max(1, int(expiry))
        except Exception:
            ev.token_expiry_hours = 24
        ev.email_template = (request.POST.get("email_template") or ev.email_template).strip()
        ev.save()

        smtp.smtp_host = (request.POST.get("smtp_host") or "").strip()
        smtp.smtp_port = int(request.POST.get("smtp_port") or 587)
        smtp.smtp_username = (request.POST.get("smtp_username") or "").strip()
        smtp.smtp_password = (request.POST.get("smtp_password") or "").strip()
        smtp.sender_email = (request.POST.get("sender_email") or "").strip()
        smtp.sender_name = (request.POST.get("sender_name") or "").strip()
        smtp.use_tls = request.POST.get("use_tls") == "on"
        smtp.use_ssl = request.POST.get("use_ssl") == "on"
        smtp.imap_host = (request.POST.get("imap_host") or "").strip()
        smtp.imap_port = int(request.POST.get("imap_port") or 993)
        smtp.imap_username = (request.POST.get("imap_username") or "").strip()
        smtp.imap_password = (request.POST.get("imap_password") or "").strip()
        smtp.save()
        messages.success(request, "Email verification settings updated.")
        return redirect("admin-email-verification-settings")
    return render(request, "admin_panel/email_verification_settings.html", {"ev": ev, "smtp": smtp})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_send_page(request):
    users = User.objects.exclude(email="").order_by("email")[:1000]
    if request.method == "POST":
        email = (request.POST.get("email") or "").strip()
        user_id = request.POST.get("user_id") or ""
        subject = (request.POST.get("subject") or "").strip()
        body = (request.POST.get("body") or "").strip()
        if user_id and not email:
            u = User.objects.filter(id=user_id).first()
            if u:
                email = u.email
        if not email or not subject:
            messages.error(request, "Email and subject are required.")
            return redirect("admin-send-email")
        u = User.objects.filter(email__iexact=email).first()
        ok, err = send_dynamic_email(email, subject, body, user=u)
        messages.success(request, "Email sent successfully." if ok else f"Email failed: {err}")
        return redirect("admin-send-email")
    return render(request, "admin_panel/email_send.html", {"users": users})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_bulk_page(request):
    if request.method == "POST":
        role = request.POST.get("role") or ""
        subject = (request.POST.get("subject") or "").strip()
        body = (request.POST.get("body") or "").strip()
        qs = User.objects.exclude(email="")
        if role:
            qs = qs.filter(role=role)
        sent = 0
        failed = 0
        for u in qs[:2000]:
            ok, _ = send_dynamic_email(u.email, subject, body, user=u)
            if ok:
                sent += 1
            else:
                failed += 1
        messages.success(request, f"Bulk email complete. Sent: {sent}, Failed: {failed}")
        return redirect("admin-bulk-email")
    roles = User.Roles.choices
    return render(request, "admin_panel/email_bulk.html", {"roles": roles})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def email_history_page(request):
    logs = EmailLog.objects.select_related("user").all()[:500]
    return render(request, "admin_panel/email_history.html", {"rows": logs})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def sidebar_settings(request):
    ui = SidebarUISettings.get_solo()

    if request.method == "POST":
        fields = [
            "sidebar_bg_color",
            "sidebar_text_color",
            "sidebar_hover_color",
            "sidebar_active_color",
            "font_family",
            "font_size",
            "sidebar_width",
            "logo_size_px",
            "animation_enabled",
        ]

        for f in fields:
            if f == "animation_enabled":
                setattr(ui, f, request.POST.get(f) == "on")
            else:
                val = request.POST.get(f)
                if val is not None and val != "":
                    # Cast ints for numeric fields
                    if f in {"font_size", "sidebar_width", "logo_size_px"}:
                        setattr(ui, f, int(val))
                    else:
                        setattr(ui, f, val)

        ui.save()
        messages.success(request, "Sidebar UI settings updated.")
        return redirect("admin-sidebar-settings")

    return render(request, "admin_panel/sidebar_settings.html", {"ui": ui})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def mt5_groups_admin(request):
    from django.urls import reverse

    edit_id = request.GET.get("edit") or ""
    edit_obj = MT5Group.objects.filter(id=edit_id).first() if edit_id else None

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip().lower()
        if action == "save":
            group_id = request.POST.get("id") or ""
            crm_group_name = (request.POST.get("crm_group_name") or "").strip()
            platform = (request.POST.get("platform") or "").strip()
            platform_group_name = (request.POST.get("platform_group_name") or "").strip()
            description = (request.POST.get("description") or "").strip()
            status_value = (request.POST.get("status_value") or "").strip().lower()
            is_active = status_value != "disabled" if status_value else (request.POST.get("is_active") == "on")

            if group_id:
                row = MT5Group.objects.filter(id=group_id).first()
                if not row:
                    messages.error(request, "Group not found.")
                    return redirect("admin-group-list")
            else:
                row = MT5Group()
            form = GroupForm(
                {
                    "crm_group_name": crm_group_name,
                    "platform": platform or MT5Group.BrokerPlatform.MT5,
                    "platform_group_name": platform_group_name,
                    "description": description,
                    "is_active": is_active,
                },
                instance=row,
            )
            if form.is_valid():
                try:
                    form.save()
                    messages.success(request, "Group saved successfully.")
                except Exception as exc:
                    messages.error(request, f"Unable to save group: {exc}")
            else:
                messages.error(request, "; ".join([f"{k}: {' '.join(v)}" for k, v in form.errors.items()]))
            return redirect("admin-groups")

        if action == "toggle":
            gid = request.POST.get("id") or ""
            row = MT5Group.objects.filter(id=gid).first()
            if row:
                row.is_active = not row.is_active
                row.save(update_fields=["is_active"])
                messages.success(request, "Group status updated.")
            else:
                messages.error(request, "Group not found.")
            return redirect("admin-groups")

        if action == "sync_symbols":
            from admin_panel.services.crm_group_symbol_sync import sync_symbols_for_mt5_group

            gid = (request.POST.get("id") or "").strip()
            if not gid.isdigit():
                messages.error(request, "Invalid group.")
            else:
                n, err = sync_symbols_for_mt5_group(int(gid))
                if err:
                    messages.warning(request, err if "required" in err.lower() or "not connected" in err.lower() or "available" in err.lower() else f"Sync issue: {err}")
                else:
                    messages.success(request, f"Synced {n} symbol(s) for this CRM group.")
            return redirect("admin-groups")

        if action == "sync_all_symbols":
            from admin_panel.services.crm_group_symbol_sync import sync_all_crm_groups

            totals = sync_all_crm_groups()
            messages.success(
                request,
                f"Symbol sync finished: {totals['groups']} group(s), {totals['symbols']} symbol row(s) written; {totals['errors']} group(s) reported connection or API issues.",
            )
            return redirect("admin-groups")

    groups_qs = (
        MT5Group.objects.select_related("match_trader_broker_group", "crm_symbol_sync_status")
        .annotate(crm_symbol_count=Count("crm_synced_symbols", distinct=True))
        .order_by("crm_group_name", "name")
    )
    linked_types = TradingAccountType.objects.filter(crm_group_id__isnull=False).select_related("crm_group")
    type_by_group: dict[int, list] = {}
    for at in linked_types:
        type_by_group.setdefault(at.crm_group_id, []).append(at)
    groups = []
    for g in groups_qs:
        g.linked_account_types = type_by_group.get(g.id, [])
        groups.append(g)
    return render(
        request,
        "admin_panel/mt5_groups.html",
        {
            "title": "Group Management",
            "groups": groups,
            "edit_obj": edit_obj,
            "platform_groups_json_url": reverse("admin-crm-platform-groups-json"),
            "broker_platform_choices": MT5Group.BrokerPlatform.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def mt5_platform_groups_json(request):
    from .services.broker_platform_groups import build_platform_group_tree

    try:
        platforms = build_platform_group_tree()
    except Exception as exc:
        logger.exception("platform-groups.json failed: %s", exc)
        return JsonResponse(
            {"platforms": [], "error": "Failed to load platform groups."},
            status=500,
        )
    return JsonResponse({"platforms": platforms})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_POST
def mt5_group_delete(request, pk):
    """Delete a broker/CRM MT5 group.

    Linked AccountTypes are deactivated first so Open Account cannot keep
    offering orphan rows after crm_group is SET_NULL. MT5 accounts in this
    group are CASCADE-deleted with the group.
    """
    try:
        group = MT5Group.objects.get(pk=pk)
    except MT5Group.DoesNotExist:
        messages.error(request, "Group not found.")
        return redirect("admin-groups")

    n_accounts = MT5Account.objects.filter(group_id=group.pk).count()
    n_types = TradingAccountType.objects.filter(
        models.Q(crm_group_id=group.pk) | models.Q(demo_group_id=group.pk)
    ).update(is_active=False)
    try:
        group.delete()
    except Exception as exc:
        messages.error(request, str(exc) or "Unable to delete group.")
        return redirect("admin-groups")

    extra = []
    if n_accounts:
        extra.append(f"{n_accounts} trading account(s) linked to this group were removed")
    if n_types:
        extra.append(f"{n_types} account type(s) deactivated for Open Account")
    if extra:
        messages.success(request, "Group deleted successfully. " + "; ".join(extra) + ".")
    else:
        messages.success(request, "Group deleted successfully.")
    return redirect("admin-groups")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def match_trader_broker_groups_admin(request):
    """Catalog of Match-Trader group names used in CRM account type mapping."""
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip().lower()
        if action == "add":
            name = (request.POST.get("name") or "").strip()
            desc = (request.POST.get("description") or "").strip()
            if not name:
                messages.error(request, "Group name is required.")
            else:
                obj, created = MatchTraderBrokerGroup.objects.get_or_create(
                    sync_category=MatchTraderBrokerGroup.Category.TRADING,
                    name=name[:120],
                    defaults={"description": desc[:2000], "is_active": True},
                )
                if not created and desc and obj.description != desc:
                    obj.description = desc[:2000]
                    obj.save(update_fields=["description", "updated_at"])
                messages.success(request, "Match-Trader group saved.")
        elif action == "toggle":
            row = MatchTraderBrokerGroup.objects.filter(id=request.POST.get("id")).first()
            if row:
                row.is_active = not row.is_active
                row.save(update_fields=["is_active", "updated_at"])
                messages.success(request, "Status updated.")
            else:
                messages.error(request, "Group not found.")
        elif action == "delete":
            row = MatchTraderBrokerGroup.objects.filter(id=request.POST.get("id")).first()
            if not row:
                messages.error(request, "Group not found.")
            else:
                try:
                    row.delete()
                    messages.success(request, "Group removed.")
                except ProtectedError:
                    messages.error(request, "Cannot delete: still mapped to a CRM account type.")
        return redirect("admin-match-trader-broker-groups")

    rows = MatchTraderBrokerGroup.objects.select_related("crm_group").order_by("sync_category", "name", "id")
    return render(request, "admin_panel/match_trader_broker_groups.html", {"rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def compliance_settings(request):
    _ensure_compliance_defaults()
    settings_obj = ComplianceSettings.get_solo()

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()

        if action == "save_security":
            settings_obj.enable_identity_verification = request.POST.get("enable_identity_verification") == "on"
            settings_obj.identity_allow_reupload = request.POST.get("identity_allow_reupload") == "on"
            settings_obj.identity_lock_after_approval = request.POST.get("identity_lock_after_approval") == "on"
            settings_obj.identity_require_expiry = request.POST.get("identity_require_expiry") == "on"
            settings_obj.identity_allow_multiple_documents = request.POST.get("identity_allow_multiple_documents") == "on"
            settings_obj.enable_address_verification = request.POST.get("enable_address_verification") == "on"
            settings_obj.address_allow_reupload = request.POST.get("address_allow_reupload") == "on"
            settings_obj.address_lock_after_approval = request.POST.get("address_lock_after_approval") == "on"
            settings_obj.enable_bank_verification = request.POST.get("enable_bank_verification") == "on"
            settings_obj.bank_lock_after_approval = request.POST.get("bank_lock_after_approval") == "on"
            settings_obj.enable_crypto_verification = request.POST.get("enable_crypto_verification") == "on"
            settings_obj.crypto_lock_after_approval = request.POST.get("crypto_lock_after_approval") == "on"
            settings_obj.show_compliance_section = request.POST.get("show_compliance_section") == "on"
            settings_obj.show_bank_section = request.POST.get("show_bank_section") == "on"
            settings_obj.show_crypto_section = request.POST.get("show_crypto_section") == "on"
            settings_obj.otp_email_enabled = request.POST.get("otp_email_enabled") == "on"
            settings_obj.otp_sms_enabled = request.POST.get("otp_sms_enabled") == "on"
            settings_obj.otp_google_auth_future = request.POST.get("otp_google_auth_future") == "on"
            settings_obj.withdrawal_requires_compliance = request.POST.get("withdrawal_requires_compliance") == "on"
            settings_obj.allow_withdraw_without_kyc = request.POST.get("allow_withdraw_without_kyc") == "on"
            settings_obj.allow_deposit_without_kyc = request.POST.get("allow_deposit_without_kyc") == "on"
            settings_obj.allow_ib_request_without_kyc = request.POST.get("allow_ib_request_without_kyc") == "on"
            settings_obj.save()
            messages.success(request, "Compliance security settings updated.")
            return redirect("admin-compliance-settings")

        if action == "add_document":
            category = request.POST.get("category") or RequiredDocument.Category.IDENTITY
            name = (request.POST.get("name") or "").strip()
            if not name:
                messages.error(request, "Document name is required.")
                return redirect("admin-compliance-settings")
            RequiredDocument.objects.get_or_create(
                name=name,
                category=category,
                defaults={
                    "is_enabled": request.POST.get("is_enabled") == "on",
                    "is_required": request.POST.get("is_required") == "on",
                    "is_custom": True,
                },
            )
            messages.success(request, "Document type saved.")
            return redirect("admin-compliance-settings")

        if action == "update_document":
            obj = RequiredDocument.objects.filter(id=request.POST.get("id")).first()
            if obj:
                obj.is_enabled = request.POST.get("is_enabled") == "on"
                obj.is_required = request.POST.get("is_required") == "on"
                obj.save(update_fields=["is_enabled", "is_required"])
                messages.success(request, "Document settings updated.")
            return redirect("admin-compliance-settings")

        if action == "delete_document":
            obj = RequiredDocument.objects.filter(id=request.POST.get("id"), is_custom=True).first()
            if obj:
                obj.delete()
                messages.success(request, "Custom document removed.")
            return redirect("admin-compliance-settings")

        if action == "add_network":
            code = (request.POST.get("code") or "").strip().upper().replace(" ", "_")
            label = (request.POST.get("label") or "").strip()
            if not code or not label:
                messages.error(request, "Network code and label are required.")
                return redirect("admin-compliance-settings")
            CryptoNetwork.objects.get_or_create(code=code, defaults={"label": label, "is_enabled": True})
            messages.success(request, "Crypto network saved.")
            return redirect("admin-compliance-settings")

        if action == "update_network":
            obj = CryptoNetwork.objects.filter(id=request.POST.get("id")).first()
            if obj:
                obj.label = (request.POST.get("label") or obj.label).strip()
                obj.is_enabled = request.POST.get("is_enabled") == "on"
                obj.save(update_fields=["label", "is_enabled"])
                messages.success(request, "Crypto network updated.")
            return redirect("admin-compliance-settings")

        if action == "delete_network":
            obj = CryptoNetwork.objects.filter(id=request.POST.get("id")).first()
            if obj:
                obj.delete()
                messages.success(request, "Crypto network removed.")
            return redirect("admin-compliance-settings")

        if action == "update_bank_field":
            obj = BankField.objects.filter(id=request.POST.get("id")).first()
            if obj:
                obj.is_enabled = request.POST.get("is_enabled") == "on"
                obj.is_required = request.POST.get("is_required") == "on"
                obj.save(update_fields=["is_enabled", "is_required"])
                messages.success(request, "Bank field rules updated.")
            return redirect("admin-compliance-settings")

    identity_docs = RequiredDocument.objects.filter(category=RequiredDocument.Category.IDENTITY).order_by("name")
    address_docs = RequiredDocument.objects.filter(category=RequiredDocument.Category.ADDRESS).order_by("name")
    bank_fields = BankField.objects.all()
    crypto_networks = CryptoNetwork.objects.all()
    return render(
        request,
        "admin_panel/compliance_settings.html",
        {
            "s": settings_obj,
            "identity_docs": identity_docs,
            "address_docs": address_docs,
            "bank_fields": bank_fields,
            "crypto_networks": crypto_networks,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def compliance_reviews(request):
    tab = (request.GET.get("tab") or "identity").lower()
    valid_tabs = {"identity", "address", "bank", "crypto"}
    if tab not in valid_tabs:
        tab = "identity"

    if request.method == "POST":
        rec_id = request.POST.get("id")
        action = request.POST.get("action")
        if tab == "identity":
            row = KYCIdentity.objects.filter(id=rec_id).first()
        elif tab == "address":
            row = KYCAddress.objects.filter(id=rec_id).first()
        elif tab == "bank":
            row = VerifiedBankAccount.objects.filter(id=rec_id).first()
        else:
            row = VerifiedCryptoAddress.objects.filter(id=rec_id).first()
        if not row:
            messages.error(request, "Record not found.")
            return redirect(f"{reverse('admin-compliance-reviews')}?tab={tab}")

        if action == "approve":
            row.status = "APPROVED"
        elif action == "reject":
            row.status = "REJECTED"
        else:
            messages.error(request, "Invalid action.")
            return redirect(f"{reverse('admin-compliance-reviews')}?tab={tab}")
        row.reviewed_at = timezone.now()
        row.reviewed_by = request.user
        row.save(update_fields=["status", "reviewed_at", "reviewed_by"])
        if hasattr(row, "user") and row.user and row.user.email:
            send_dynamic_email(
                row.user.email,
                f"KYC {tab.title()} Status Updated",
                f"Your {tab} verification status is now: {row.status}.",
                user=row.user,
            )
        messages.success(request, "Compliance record updated.")
        return redirect(f"{reverse('admin-compliance-reviews')}?tab={tab}")

    context = {"tab": tab}
    if tab == "identity":
        context["rows"] = KYCIdentity.objects.select_related("user", "reviewed_by").order_by("-created_at")[:500]
    elif tab == "address":
        context["rows"] = KYCAddress.objects.select_related("user", "reviewed_by").order_by("-created_at")[:500]
    elif tab == "bank":
        context["rows"] = VerifiedBankAccount.objects.select_related("user", "reviewed_by").order_by("-created_at")[:500]
    else:
        context["rows"] = VerifiedCryptoAddress.objects.select_related("user", "reviewed_by").order_by("-created_at")[:500]
    return render(request, "admin_panel/compliance_reviews.html", context)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def view_kyc(request, id):
    user = get_object_or_404(User, id=id)
    fs = (request.GET.get("from_status") or "pending").strip().lower()
    if fs not in {"pending", "approved", "rejected"}:
        fs = "pending"
    identity = KYCIdentity.objects.filter(user=user).order_by("-created_at").first()
    address = KYCAddress.objects.filter(user=user).order_by("-created_at").first()
    bank = VerifiedBankAccount.objects.filter(user=user).order_by("-created_at").first()
    crypto = VerifiedCryptoAddress.objects.filter(user=user).order_by("-created_at").first()
    docs = user.documents.order_by("-uploaded_at")[:20]
    return render(
        request,
        "admin_panel/user_kyc_view.html",
        {
            "user_obj": user,
            "identity": identity,
            "address": address,
            "bank": bank,
            "crypto": crypto,
            "docs": docs,
            "from_status": fs,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def account_management(request):
    if request.method == "POST":
        account_id = request.POST.get("account_id")
        acc = MT5Account.objects.filter(id=account_id).first()
        if not acc:
            messages.error(request, "Account not found.")
            return redirect("admin-account-management")

        action = request.POST.get("action", "")
        if action == "save_meta":
            acc.account_label = (request.POST.get("account_label") or "").strip()
            leverage = request.POST.get("leverage") or ""
            if leverage.isdigit():
                acc.leverage = int(leverage)
            acc.save(update_fields=["account_label", "leverage"])
            messages.success(request, f"Account {acc.login_id} updated.")
        elif action == "enable_trading":
            acc.trading_enabled = True
            acc.save(update_fields=["trading_enabled"])
            messages.success(request, f"Trading enabled for {acc.login_id}.")
        elif action == "disable_trading":
            acc.trading_enabled = False
            acc.save(update_fields=["trading_enabled"])
            messages.success(request, f"Trading disabled for {acc.login_id}.")
        elif action == "enable_deposit":
            acc.deposit_enabled = True
            acc.save(update_fields=["deposit_enabled"])
            messages.success(request, f"Deposit enabled for {acc.login_id}.")
        elif action == "disable_deposit":
            acc.deposit_enabled = False
            acc.save(update_fields=["deposit_enabled"])
            messages.success(request, f"Deposit disabled for {acc.login_id}.")
        elif action == "enable_withdraw":
            acc.withdraw_enabled = True
            acc.save(update_fields=["withdraw_enabled"])
            messages.success(request, f"Withdraw enabled for {acc.login_id}.")
        elif action == "disable_withdraw":
            acc.withdraw_enabled = False
            acc.save(update_fields=["withdraw_enabled"])
            messages.success(request, f"Withdraw disabled for {acc.login_id}.")
        return redirect("admin-account-management")

    accounts = MT5Account.objects.select_related("user", "group").order_by("-updated_at")[:300]
    return render(request, "admin_panel/account_management.html", {"accounts": accounts})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_account_settings(request):
    broker_groups = MT5Group.objects.filter(is_active=True).order_by("crm_group_name", "name")
    leverage_choices = ["100", "200", "300", "400", "500", "1000", "1500", "2000"]

    def _to_decimal(raw: str, default: str = "0") -> Decimal:
        try:
            return Decimal((raw or "").strip() or default)
        except Exception:
            return Decimal(default)

    def _to_int(raw: str, default: int = 0) -> int:
        try:
            return int((raw or "").strip() or str(default))
        except Exception:
            return default

    if request.method == "POST":
        action = request.POST.get("action", "").strip()
        obj_id = request.POST.get("id", "").strip()
        if action in {"add", "edit"}:
            row = TradingAccountType.objects.filter(id=obj_id).first() if action == "edit" else TradingAccountType()
            if action == "edit" and not row:
                messages.error(request, "Account type not found.")
                return redirect("admin-account-type-list")

            account_title = (request.POST.get("account_name") or "").strip()
            headline = (request.POST.get("headline") or "").strip()
            min_deposit = _to_decimal(request.POST.get("min_deposit"), "0")
            min_spread = _to_decimal(request.POST.get("min_spread"), "0")
            commission_value = _to_decimal(request.POST.get("commission"), "0")
            account_code = (request.POST.get("account_code") or "").strip().upper() or re.sub(r"[^A-Z0-9]", "", account_title.upper())[:20]
            selected_currency = (request.POST.get("currency") or TradingAccountType.Currency.USD).strip().upper()
            if selected_currency not in {TradingAccountType.Currency.USD, TradingAccountType.Currency.EUR, TradingAccountType.Currency.GBP, TradingAccountType.Currency.AUD}:
                selected_currency = TradingAccountType.Currency.USD

            account_category = (request.POST.get("account_category") or "LIVE").strip().upper()
            if account_category not in {"LIVE", "DEMO"}:
                account_category = "LIVE"

            min_demo_balance = _to_decimal(request.POST.get("min_demo_balance"), "100.00")
            max_demo_balance = _to_decimal(request.POST.get("max_demo_balance"), "100000.00")

            server_name = (request.POST.get("server_name") or "").strip()
            manual_group_name = ""
            crm_gid = request.POST.get("crm_group_id") or ""
            crm_group = MT5Group.objects.filter(id=crm_gid, is_active=True).first() if str(crm_gid).isdigit() else None

            raw_leverages = request.POST.getlist("leverage_options")
            leverage_options = [v for v in raw_leverages if v in leverage_choices]
            demo_enabled = request.POST.get("demo_enabled") == "on"
            demo_gid = request.POST.get("demo_group_id") or ""
            demo_group = MT5Group.objects.filter(id=demo_gid, is_active=True).first() if str(demo_gid).isdigit() else None

            kyc_requirement = (request.POST.get("kyc_requirement") or "NONE").strip().upper()
            if kyc_requirement not in {"NONE", "BASIC", "FULL"}:
                kyc_requirement = "NONE"
            geographic_enabled = request.POST.get("geographic_restrictions_enabled") == "on"
            geographic_mode = (request.POST.get("geographic_mode") or "ALLOW").strip().upper()
            if geographic_mode not in {"ALLOW", "BLOCK"}:
                geographic_mode = "ALLOW"

            if not account_title:
                messages.error(request, "Account title is required.")
                return redirect("admin-account-type-list")
            if min_deposit <= 0 or min_spread < 0:
                messages.error(request, "Min deposit and min spread must be valid values.")
                return redirect("admin-account-type-list")
            if not crm_group:
                messages.error(request, "Select a CRM group from Group Management (required).")
                return redirect("admin-account-type-list")
            if not leverage_options:
                messages.error(request, "Select at least one leverage option.")
                return redirect("admin-account-type-list")
            if demo_enabled and not demo_group:
                messages.error(request, "Demo group is required when demo is enabled.")
                return redirect("admin-account-type-list")

            row.account_name = account_title
            row.headline = headline
            row.account_code = account_code[:20]
            row.account_category = account_category
            row.min_deposit = min_deposit
            row.min_spread = min_spread
            row.commission = commission_value
            row.currency = selected_currency
            row.account_mode = "REGULAR_ONLY"
            # Legacy DB column; routing uses crm_group.platform (Group Management), not this field.
            row.platform = TradingAccountType.Platform.MT5
            row.server_name = server_name or (crm_group.name if crm_group else "")
            row.crm_group = crm_group
            row.manual_group_name = manual_group_name
            row.min_demo_balance = min_demo_balance
            row.max_demo_balance = max_demo_balance
            suf = (request.POST.get("mt5_symbol_suffix") or "").strip()
            row.mt5_symbol_suffix = suf[:32] if suf else ""
            row.leverage_options = leverage_options
            if leverage_options:
                try:
                    row.max_leverage = max([int(x) for x in leverage_options])
                except Exception:
                    pass
            row.demo_enabled = demo_enabled
            row.demo_group = demo_group if demo_enabled else None
            row.user_type = "INDIVIDUAL"
            row.kyc_requirement = kyc_requirement
            row.geographic_restrictions_enabled = geographic_enabled
            row.geographic_mode = geographic_mode
            row.geographic_countries = (request.POST.get("geographic_countries") or "").strip()
            row.require_email_verified = request.POST.get("require_email_verified") == "on"
            row.require_phone_verified = request.POST.get("require_phone_verified") == "on"
            row.require_id_document = request.POST.get("require_id_document") == "on"
            row.require_proof_of_address = request.POST.get("require_proof_of_address") == "on"
            row.max_live_accounts = max(0, _to_int(request.POST.get("max_live_accounts"), 1))
            row.max_demo_accounts = max(0, _to_int(request.POST.get("max_demo_accounts"), 1))
            row.demo_expiry_days = max(0, _to_int(request.POST.get("demo_expiry_days"), 0))
            row.max_total_balance = _to_decimal(request.POST.get("max_total_balance"), "0")
            row.max_single_deposit = _to_decimal(request.POST.get("max_single_deposit"), "0")
            row.min_first_deposit = _to_decimal(request.POST.get("min_first_deposit"), "0")
            row.max_withdrawal_per_request = _to_decimal(request.POST.get("max_withdrawal_per_request"), "0")
            row.max_withdrawal_per_day = _to_decimal(request.POST.get("max_withdrawal_per_day"), "0")
            row.max_withdrawal_requests_per_day = max(0, _to_int(request.POST.get("max_withdrawal_requests_per_day"), 0))
            row.inactivity_fee_amount = _to_decimal(request.POST.get("inactivity_fee_amount"), "0")
            row.inactivity_fee_after_days = max(0, _to_int(request.POST.get("inactivity_fee_after_days"), 0))
            row.maintenance_fee_amount = _to_decimal(request.POST.get("maintenance_fee_amount"), "0")
            row.is_active = request.POST.get("is_active") == "on"
            row.description = (request.POST.get("description") or "").strip()
            row.suitable_for = (request.POST.get("suitable_for") or "All Traders").strip()
            row.pricing_type = TradingAccountType.PricingType.SPREAD
            row.spread_value = min_spread
            row.display_order = max(0, _to_int(request.POST.get("display_order"), 0))

            try:
                row.save()
                messages.success(request, "Account type saved.")
            except Exception as exc:
                messages.error(request, f"Unable to save account type: {exc}")

        elif action == "delete":
            if not str(obj_id).isdigit():
                messages.error(request, "Invalid account type id.")
            else:
                obj = TradingAccountType.objects.filter(id=int(obj_id)).first()
                if not obj:
                    messages.error(request, "Account type not found.")
                else:
                    try:
                        obj.delete()
                        messages.success(request, "Account type deleted successfully.")
                    except ProtectedError:
                        messages.error(
                            request,
                            "Cannot delete this account type because other records are still linked to it.",
                        )
                    except IntegrityError:
                        messages.error(
                            request,
                            "Cannot delete this account type due to database constraints.",
                        )

        elif action in {"enable", "disable"}:
            if not str(obj_id).isdigit():
                messages.error(request, "Invalid account type id.")
                return redirect("admin-account-type-list")
            obj = TradingAccountType.objects.filter(id=int(obj_id)).first()
            if obj:
                obj.is_active = action == "enable"
                obj.save(update_fields=["is_active", "updated_at"])
                messages.success(request, "Account type status updated.")
            else:
                messages.error(request, "Account type not found.")

        return redirect("admin-account-type-list")

    edit_id = request.GET.get("edit")
    status_f = (request.GET.get("status") or "").strip().lower()
    min_dep_min = _to_decimal(request.GET.get("min_deposit_min"), "0")
    min_dep_max_raw = (request.GET.get("min_deposit_max") or "").strip()
    min_dep_max = _to_decimal(min_dep_max_raw, "0") if min_dep_max_raw else None
    edit_obj = TradingAccountType.objects.filter(id=edit_id).first() if edit_id else None
    rows_qs = TradingAccountType.objects.select_related(
        "crm_group",
        "crm_group__match_trader_broker_group",
        "demo_group",
    ).all()
    if status_f == "active":
        rows_qs = rows_qs.filter(is_active=True)
    elif status_f == "inactive":
        rows_qs = rows_qs.filter(is_active=False)
    if min_dep_min > 0:
        rows_qs = rows_qs.filter(min_deposit__gte=min_dep_min)
    if min_dep_max is not None:
        rows_qs = rows_qs.filter(min_deposit__lte=min_dep_max)
    rows = list(rows_qs.order_by("display_order", "account_name"))
    total_accounts = MT5Account.objects.count()
    stats = {
        "total_types": TradingAccountType.objects.count(),
        "active_types": TradingAccountType.objects.filter(is_active=True).count(),
        "inactive_types": TradingAccountType.objects.filter(is_active=False).count(),
        "total_accounts": total_accounts,
    }
    return render(
        request,
        "admin_panel/trading_account_settings.html",
        {
            "show_form": bool(edit_obj) or "/add/" in request.path,
            "rows": rows,
            "edit_obj": edit_obj,
            "broker_groups": broker_groups,
            "stats": stats,
            "filters": {
                "status": status_f,
                "min_deposit_min": request.GET.get("min_deposit_min", ""),
                "min_deposit_max": request.GET.get("min_deposit_max", ""),
            },
            "leverage_choices": leverage_choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def group_management(request):
    """System-management alias to consolidated group management."""
    try:
        return mt5_groups_admin(request)
    except Exception as exc:
        messages.error(request, f"Group management is temporarily unavailable: {exc}")
        return redirect("admin-system-management-dashboard")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def account_types(request):
    """System-management alias to consolidated account-types page."""
    try:
        return trading_account_settings(request)
    except Exception as exc:
        messages.error(request, f"Account types module is temporarily unavailable: {exc}")
        return redirect("admin-system-management-dashboard")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def branding(request):
    """System-management alias to branding UI."""
    try:
        return branding_logo(request)
    except Exception as exc:
        messages.error(request, f"Branding module is temporarily unavailable: {exc}")
        return redirect("admin-system-management-dashboard")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def logo_upload(request):
    """Dedicated endpoint alias for logo upload saves."""
    form = BrandingForm(request.POST, request.FILES, instance=PortalBrandingSettings.get_solo())
    if not form.is_valid():
        messages.error(request, "Logo upload failed. Please upload a valid image file.")
        return redirect("admin-branding-logo")
    try:
        return branding_logo(request)
    except Exception as exc:
        messages.error(request, f"Logo upload failed: {exc}")
        return redirect("admin-branding-logo")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_account_requests(request):
    if request.method == "POST":
        req_id = request.POST.get("request_id", "").strip()
        action = request.POST.get("action", "").strip()
        req = TradingAccountRequest.objects.select_related("user", "account_type").filter(id=req_id).first()
        if not req:
            messages.error(request, "Request not found.")
            return redirect("admin-trading-account-requests")

        if req.status != TradingAccountRequest.Status.PENDING:
            messages.error(request, "Request already processed.")
            return redirect("admin-trading-account-requests")

        if action == "reject":
            req.status = TradingAccountRequest.Status.REJECTED
            req.processed_at = timezone.now()
            req.save(update_fields=["status", "processed_at"])
            send_dynamic_email(
                req.user.email,
                "Trading Account Request Rejected",
                "Your account opening request was rejected. Please contact support for details.",
                user=req.user,
                event_key="trading_account_rejected",
            )
            messages.success(request, f"Rejected request #{req.id}.")
            return redirect("admin-trading-account-requests")

        if action == "approve":
            grp = None
            at = req.account_type
            if at and getattr(at, "crm_group_id", None):
                grp = MT5Group.objects.filter(id=at.crm_group_id, is_active=True).first()
            if not grp:
                grp = MT5Group.objects.filter(is_active=True).order_by("id").first()
            if not grp:
                messages.error(request, "No active broker group configured. Add a group under Group Management.")
                return redirect("admin-trading-account-requests")
            login_id = get_random_string(8, allowed_chars="0123456789")
            while MT5Account.objects.filter(login_id=login_id).exists():
                login_id = get_random_string(8, allowed_chars="0123456789")

            from mt5_integration.services import _mt5_client, is_mt5_configured
            import random
            def generate_mt5_password():
                chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                p = (
                    get_random_string(1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") +
                    get_random_string(1, "abcdefghijklmnopqrstuvwxyz") +
                    get_random_string(1, "0123456789") +
                    get_random_string(7, chars)
                )
                l = list(p)
                random.shuffle(l)
                return "".join(l)
            
            main_password = generate_mt5_password()
            investor_password = generate_mt5_password()

            if req.account_type and req.account_type.platform == "MT5":
                if not is_mt5_configured():
                    messages.error(request, "MT5 Integration is not configured. Cannot approve request.")
                    return redirect("admin-trading-account-requests")
                try:
                    with _mt5_client() as client:
                        group_str = getattr(grp, "platform_group_name", "") or getattr(grp, "name", "")
                        full_name = f"{req.user.first_name} {req.user.last_name}".strip() or req.user.username
                        new_mt5_login = client.user_add(
                            group=group_str,
                            name=full_name,
                            password=main_password,
                            investor_password=investor_password,
                            leverage=req.leverage,
                            email=req.user.email,
                            country=getattr(req.user, "country", ""),
                            phone=getattr(req.user, "phone", ""),
                        )
                        login_id = str(new_mt5_login)
                except Exception as e:
                    import logging
                    logging.getLogger(__name__).error("Failed to create MT5 account via API on approval: %s", e)
                    messages.error(request, "Failed to create MT5 account on server.")
                    return redirect("admin-trading-account-requests")

            account = MT5Account.objects.create(
                user=req.user,
                login_id=login_id,
                account_type=MT5Account.AccountType.LIVE,
                leverage=req.leverage,
                account_label=req.account_type.account_name if req.account_type else "Live Account",
                group=grp,
                server=f"{req.account_type.platform if req.account_type else 'MT5'}-Live",
            )
            account.set_mt5_password(main_password)
            account.set_investor_password(investor_password)
            account.save()

            TradingAccount.objects.create(
                user=req.user,
                account_number=login_id,
                account_type=req.account_type.account_name if req.account_type else "Live Account",
                leverage=req.leverage,
                currency=req.currency,
                status=TradingAccount.Status.ACTIVE,
                server=f"{req.account_type.platform if req.account_type else 'MT5'}-Live",
                balance=0,
                mt5_account=account,
            )

            req.status = TradingAccountRequest.Status.APPROVED
            req.processed_at = timezone.now()
            req.created_mt5_account = account
            req.save(update_fields=["status", "processed_at", "created_mt5_account"])
            send_event_email(
                "account_approved",
                to_email=req.user.email,
                user=req.user,
                extra_context={
                    "name": req.user.display_name(),
                    "account_number": str(account.login_id),
                    "reason": f"Login: {account.login_id}",
                },
            )
            messages.success(request, f"Approved request #{req.id}. MT5 account created.")
            return redirect("admin-trading-account-requests")

        messages.error(request, "Invalid action.")
        return redirect("admin-trading-account-requests")

    rows = TradingAccountRequest.objects.select_related("user", "account_type", "created_mt5_account").all()
    return render(request, "admin_panel/trading_account_requests.html", {"rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_accounts(request):
    if request.method == "POST":
        account_id = request.POST.get("account_id", "")
        action = request.POST.get("action", "")
        acc = TradingAccount.objects.select_related("mt5_account").filter(id=account_id).first()
        if not acc:
            messages.error(request, "Trading account not found.")
            return redirect("admin-trading-accounts")

        if action == "disable":
            acc.status = TradingAccount.Status.DISABLED
            acc.save(update_fields=["status", "updated_at"])
            if acc.mt5_account:
                acc.mt5_account.status = MT5Account.Status.INACTIVE
                acc.mt5_account.save(update_fields=["status", "updated_at"])
            messages.success(request, "Trading account disabled.")
        elif action == "enable":
            acc.status = TradingAccount.Status.ACTIVE
            acc.save(update_fields=["status", "updated_at"])
            if acc.mt5_account:
                acc.mt5_account.status = MT5Account.Status.ACTIVE
                acc.mt5_account.save(update_fields=["status", "updated_at"])
            messages.success(request, "Trading account enabled.")
        elif action == "edit":
            leverage = request.POST.get("leverage") or ""
            currency = request.POST.get("currency") or ""
            if leverage.isdigit():
                acc.leverage = int(leverage)
            if currency:
                acc.currency = currency
            acc.save(update_fields=["leverage", "currency", "updated_at"])
            if acc.mt5_account and leverage.isdigit():
                acc.mt5_account.leverage = int(leverage)
                acc.mt5_account.save(update_fields=["leverage", "updated_at"])
            messages.success(request, "Trading account updated.")
        return redirect("admin-trading-accounts")

    rows = TradingAccount.objects.select_related("user", "mt5_account").all()[:600]
    return render(request, "admin_panel/trading_accounts.html", {"rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def treasury_hub(request):
    return render(request, "admin_panel/treasury_hub.html", {"title": "Treasury Settings"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def legacy_payment_gateways_redirect(request):
    scope = (request.GET.get("scope") or "DEPOSIT").upper()
    if scope == "WITHDRAW":
        return redirect("admin-treasury-withdraw-methods")
    return redirect("admin-treasury-deposit-methods")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def treasury_wallet_settings(request):
    obj = WalletTreasurySettings.get_solo()
    if request.method == "POST":
        obj.wallet_system_enabled = request.POST.get("wallet_system_enabled") == "on"
        obj.auto_create_wallet_on_registration = request.POST.get("auto_create_wallet_on_registration") == "on"
        obj.allow_deposits_to_wallet = request.POST.get("allow_deposits_to_wallet") == "on"
        obj.wallet_min_deposit = _pg_decimal(request.POST.get("wallet_min_deposit"))
        obj.wallet_max_deposit = _pg_decimal(request.POST.get("wallet_max_deposit"))
        obj.wallet_deposit_maintenance = request.POST.get("wallet_deposit_maintenance") == "on"
        obj.allow_withdrawals_from_wallet = request.POST.get("allow_withdrawals_from_wallet") == "on"
        obj.wallet_min_withdraw = _pg_decimal(request.POST.get("wallet_min_withdraw"))
        obj.wallet_max_withdraw = _pg_decimal(request.POST.get("wallet_max_withdraw"))
        obj.wallet_daily_withdraw_limit = _pg_decimal(request.POST.get("wallet_daily_withdraw_limit"))
        obj.wallet_withdraw_maintenance = request.POST.get("wallet_withdraw_maintenance") == "on"
        obj.allow_wallet_to_trading = request.POST.get("allow_wallet_to_trading") == "on"
        obj.allow_trading_to_wallet = request.POST.get("allow_trading_to_wallet") == "on"
        obj.allow_p2p_transfers = request.POST.get("allow_p2p_transfers") == "on"
        obj.require_kyc_wallet_withdraw = request.POST.get("require_kyc_wallet_withdraw") == "on"
        obj.require_2fa_wallet_withdraw = request.POST.get("require_2fa_wallet_withdraw") == "on"
        try:
            obj.wallet_withdraw_cooldown_minutes = int(request.POST.get("wallet_withdraw_cooldown_minutes") or 0)
        except ValueError:
            obj.wallet_withdraw_cooldown_minutes = 0
        try:
            obj.wallet_max_pending_withdrawals = int(request.POST.get("wallet_max_pending_withdrawals") or 0)
        except ValueError:
            obj.wallet_max_pending_withdrawals = 0
        obj.show_wallet_dashboard = request.POST.get("show_wallet_dashboard") == "on"
        obj.wallet_in_total_balance = request.POST.get("wallet_in_total_balance") == "on"
        obj.show_wallet_sidebar = request.POST.get("show_wallet_sidebar") == "on"
        obj.save()
        messages.success(request, "Wallet settings saved.")
        return redirect("admin-treasury-wallet-settings")
    return render(request, "admin_panel/treasury_wallet_settings.html", {"title": "Wallet Settings", "obj": obj})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def treasury_transfer_settings(request):
    obj = TransferTreasurySettings.get_solo()
    if request.method == "POST":
        obj.internal_transfers_enabled = request.POST.get("internal_transfers_enabled") == "on"
        obj.internal_maintenance_mode = request.POST.get("internal_maintenance_mode") == "on"
        obj.internal_min_amount = _pg_decimal(request.POST.get("internal_min_amount"))
        obj.internal_max_amount = _pg_decimal(request.POST.get("internal_max_amount"))
        ft = (request.POST.get("internal_fee_type") or TransferTreasurySettings.FeeType.FIXED).upper()
        if ft not in {c[0] for c in TransferTreasurySettings.FeeType.choices}:
            ft = TransferTreasurySettings.FeeType.FIXED
        obj.internal_fee_type = ft
        obj.internal_fee_value = _pg_decimal(request.POST.get("internal_fee_value"))
        obj.internal_daily_limit = _pg_decimal(request.POST.get("internal_daily_limit"))
        try:
            obj.internal_cooldown_minutes = int(request.POST.get("internal_cooldown_minutes") or 0)
        except ValueError:
            obj.internal_cooldown_minutes = 0
        pm = (request.POST.get("internal_processing_mode") or TransferTreasurySettings.ProcessingMode.INSTANT).upper()
        if pm not in {c[0] for c in TransferTreasurySettings.ProcessingMode.choices}:
            pm = TransferTreasurySettings.ProcessingMode.INSTANT
        obj.internal_processing_mode = pm
        obj.p2p_enabled = request.POST.get("p2p_enabled") == "on"
        obj.p2p_min_amount = _pg_decimal(request.POST.get("p2p_min_amount"))
        obj.p2p_max_amount = _pg_decimal(request.POST.get("p2p_max_amount"))
        obj.p2p_fee_value = _pg_decimal(request.POST.get("p2p_fee_value"))
        obj.p2p_daily_limit = _pg_decimal(request.POST.get("p2p_daily_limit"))
        try:
            obj.p2p_cooldown_minutes = int(request.POST.get("p2p_cooldown_minutes") or 0)
        except ValueError:
            obj.p2p_cooldown_minutes = 0
        obj.transfer_require_kyc = request.POST.get("transfer_require_kyc") == "on"
        obj.transfer_require_2fa = request.POST.get("transfer_require_2fa") == "on"
        try:
            obj.transfer_max_pending = int(request.POST.get("transfer_max_pending") or 0)
        except ValueError:
            obj.transfer_max_pending = 0
        obj.save()
        messages.success(request, "Transfer settings saved.")
        return redirect("admin-treasury-transfer-settings")
    return render(request, "admin_panel/treasury_transfer_settings.html", {"title": "Transfer Settings", "obj": obj})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def payment_gateways(request, treasury_scope: str | None = None):
    scope = treasury_scope.upper() if treasury_scope else (request.GET.get("scope") or "DEPOSIT").upper()
    if scope not in {"DEPOSIT", "WITHDRAW"}:
        scope = "DEPOSIT"
    type_filter = (request.GET.get("type") or "ALL").upper()
    if type_filter not in {"ALL", "LOCAL", "THIRD_PARTY"}:
        type_filter = "ALL"
    if scope == "DEPOSIT":
        type_filter = "LOCAL"

    def _redirect_back():
        return redirect(request.path)

    if request.method == "POST":
        action = request.POST.get("action", "")
        gateway_id = request.POST.get("gateway_id", "")

        if action in {"add", "edit"}:
            vis = (request.POST.get("visibility_status") or PaymentGateway.VisibilityStatus.ACTIVE).upper()
            allowed_vis = {c[0] for c in PaymentGateway.VisibilityStatus.choices}
            if vis not in allowed_vis:
                vis = PaymentGateway.VisibilityStatus.ACTIVE
            fee_type = (request.POST.get("fee_type") or PaymentGateway.FeeType.NONE).upper()
            if fee_type not in {c[0] for c in PaymentGateway.FeeType.choices}:
                fee_type = PaymentGateway.FeeType.NONE
            rate_mode = (request.POST.get("rate_mode") or PaymentGateway.RateMode.FIXED).upper()
            if rate_mode not in {c[0] for c in PaymentGateway.RateMode.choices}:
                rate_mode = PaymentGateway.RateMode.FIXED
            proc_mode = (request.POST.get("processing_mode") or PaymentGateway.ProcessingMode.INSTANT).upper()
            if proc_mode not in {c[0] for c in PaymentGateway.ProcessingMode.choices}:
                proc_mode = PaymentGateway.ProcessingMode.INSTANT
            gateway_type = (request.POST.get("gateway_type") or PaymentGateway.GatewayType.LOCAL).upper()
            if gateway_type not in {c[0] for c in PaymentGateway.GatewayType.choices}:
                gateway_type = PaymentGateway.GatewayType.LOCAL
            payment_method = (request.POST.get("payment_method") or PaymentGateway.PaymentMethod.BANK).upper()
            if payment_method not in {c[0] for c in PaymentGateway.PaymentMethod.choices}:
                payment_method = PaymentGateway.PaymentMethod.BANK
            try:
                display_order = int(request.POST.get("display_order") or 0)
            except ValueError:
                display_order = 0
            try:
                max_pending = int(request.POST.get("max_pending_per_user") or 0)
            except ValueError:
                max_pending = 0
            try:
                cooldown_minutes = int(request.POST.get("cooldown_minutes") or 0)
            except ValueError:
                cooldown_minutes = 0

            row_scope = (request.POST.get("scope") or scope).upper()
            if row_scope not in {PaymentGateway.Scope.DEPOSIT, PaymentGateway.Scope.WITHDRAW, PaymentGateway.Scope.BOTH}:
                row_scope = scope

            data = {
                "name": (request.POST.get("name") or "").strip(),
                "code": (request.POST.get("code") or "").strip().upper(),
                "scope": row_scope,
                "gateway_type": gateway_type,
                "payment_method": payment_method,
                "currency": ((request.POST.get("currency") or "USD").upper())[:10],
                "min_amount": _pg_decimal(request.POST.get("min_amount")),
                "max_amount": _pg_decimal(request.POST.get("max_amount")),
                "processing_time": (request.POST.get("processing_time") or "").strip(),
                "charges": (request.POST.get("charges") or "").strip(),
                "instructions": (request.POST.get("instructions") or "").strip(),
                "description": (request.POST.get("description") or "").strip(),
                "account_name": (request.POST.get("account_name") or "").strip(),
                "bank_name": (request.POST.get("bank_name") or "").strip(),
                "account_number": (request.POST.get("account_number") or "").strip(),
                "iban": (request.POST.get("iban") or "").strip(),
                "swift_code": (request.POST.get("swift_code") or "").strip(),
                "wallet_address": (request.POST.get("wallet_address") or "").strip(),
                "network": (request.POST.get("network") or "").strip(),
                "api_key": (request.POST.get("api_key") or "").strip(),
                "secret_key": (request.POST.get("secret_key") or "").strip(),
                "webhook_url": (request.POST.get("webhook_url") or "").strip(),
                "api_url": (request.POST.get("api_url") or "").strip(),
                "merchant_id": (request.POST.get("merchant_id") or "").strip(),
                "category": (request.POST.get("category") or "").strip()[:80],
                "visibility_status": vis,
                "fee_type": fee_type,
                "fee_value": _pg_decimal(request.POST.get("fee_value")),
                "exchange_rate": _pg_decimal(request.POST.get("exchange_rate"), "1"),
                "rate_mode": rate_mode,
                "rate_markup": _pg_decimal(request.POST.get("rate_markup")),
                "processing_mode": proc_mode,
                "display_order": max(0, display_order),
                "display_badge": (request.POST.get("display_badge") or "").strip()[:80],
                "require_payment_proof": request.POST.get("require_payment_proof") == "on",
                "daily_withdraw_limit": _pg_decimal(request.POST.get("daily_withdraw_limit")),
                "whitelist_required": request.POST.get("whitelist_required") == "on",
                "auto_approve_withdraw": request.POST.get("auto_approve_withdraw") == "on",
                "requires_kyc_for_method": request.POST.get("requires_kyc_for_method") == "on",
                "requires_2fa_for_method": request.POST.get("requires_2fa_for_method") == "on",
                "max_pending_per_user": max(0, max_pending),
                "cooldown_minutes": max(0, cooldown_minutes),
                "country_filters": (request.POST.get("country_filters") or "").strip(),
                "allowed_account_types": (request.POST.get("allowed_account_types") or "").strip(),
                "kyc_level": (request.POST.get("kyc_level") or "").strip()[:80],
                "first_time_deposit_only": request.POST.get("first_time_deposit_only") == "on",
                "flag_vip": request.POST.get("flag_vip") == "on",
                "flag_high_value": request.POST.get("flag_high_value") == "on",
                "flag_problem_user": request.POST.get("flag_problem_user") == "on",
                "flag_watch_list": request.POST.get("flag_watch_list") == "on",
                "risk_withdrawal": request.POST.get("risk_withdrawal") == "on",
                "risk_trading": request.POST.get("risk_trading") == "on",
                "risk_fraud": request.POST.get("risk_fraud") == "on",
                "risk_chargeback": request.POST.get("risk_chargeback") == "on",
                "risk_kyc": request.POST.get("risk_kyc") == "on",
                "risk_suspicious": request.POST.get("risk_suspicious") == "on",
                "risk_pep": request.POST.get("risk_pep") == "on",
                "custom_fields": _pg_lines_to_list(request.POST.get("custom_fields", "")),
                "user_fields": _pg_lines_to_list(request.POST.get("user_fields", "")),
                "instruction_steps": (request.POST.get("instruction_steps") or "").strip(),
                "require_transaction_id": request.POST.get("require_transaction_id") == "on",
            }
            model_field_names = {f.name for f in PaymentGateway._meta.fields}
            data = {k: v for k, v in data.items() if k in model_field_names}
            if scope == "DEPOSIT":
                data["gateway_type"] = PaymentGateway.GatewayType.LOCAL
                data["payment_method"] = PaymentGateway.PaymentMethod.BANK
                data["processing_mode"] = (
                    PaymentGateway.ProcessingMode.MANUAL
                    if data["gateway_type"] == PaymentGateway.GatewayType.LOCAL
                    else PaymentGateway.ProcessingMode.INSTANT
                )
            if scope == "WITHDRAW":
                data["gateway_type"] = PaymentGateway.GatewayType.LOCAL
                data["payment_method"] = request.POST.get("withdraw_payment_method") or PaymentGateway.PaymentMethod.BANK
                data["bank_name"] = ""
                data["account_name"] = ""
                data["account_number"] = ""
                data["iban"] = ""
                data["swift_code"] = ""
                data["wallet_address"] = ""
                data["network"] = ""
                data["api_key"] = ""
                data["secret_key"] = ""
                data["webhook_url"] = ""
                data["api_url"] = ""
                data["merchant_id"] = ""
                data["require_payment_proof"] = False
                data["exchange_rate"] = _pg_decimal(request.POST.get("exchange_rate"), "1")
                data = {k: v for k, v in data.items() if k in model_field_names}
            icon = request.FILES.get("icon")
            try:
                if action == "add":
                    if icon:
                        data["icon"] = icon
                    PaymentGateway.objects.create(**data)
                    messages.success(request, "Method created.")
                else:
                    g = PaymentGateway.objects.filter(id=gateway_id).first()
                    if not g:
                        messages.error(request, "Method not found.")
                    else:
                        for k, v in data.items():
                            setattr(g, k, v)
                        if icon:
                            g.icon = icon
                        g.save()
                        messages.success(request, "Method updated.")
            except Exception as exc:
                messages.error(request, f"Unable to save: {exc}")
            return _redirect_back()

        if action == "delete":
            g = PaymentGateway.objects.filter(id=gateway_id).first()
            if g:
                g.delete()
                messages.success(request, "Method deleted.")
            else:
                messages.error(request, "Method not found.")
            return _redirect_back()

        if action == "set_visibility":
            g = PaymentGateway.objects.filter(id=gateway_id).first()
            vis = (request.POST.get("visibility") or "").upper()
            if g and vis in {c[0] for c in PaymentGateway.VisibilityStatus.choices}:
                g.visibility_status = vis
                g.save()
                messages.success(request, "Status updated.")
            elif not g:
                messages.error(request, "Method not found.")
            return _redirect_back()

    base_qs = PaymentGateway.objects.filter(Q(scope=scope) | Q(scope=PaymentGateway.Scope.BOTH))
    if scope == "DEPOSIT":
        base_qs = base_qs.filter(gateway_type=PaymentGateway.GatewayType.LOCAL)
    if scope == "DEPOSIT" and type_filter != "ALL":
        base_qs = base_qs.filter(gateway_type=type_filter)
    rows = base_qs.order_by("display_order", "name")
    stats = {
        "total": base_qs.count(),
        "active": base_qs.filter(visibility_status=PaymentGateway.VisibilityStatus.ACTIVE).count(),
        "inactive": base_qs.filter(visibility_status=PaymentGateway.VisibilityStatus.INACTIVE).count(),
        "maintenance": base_qs.filter(visibility_status=PaymentGateway.VisibilityStatus.MAINTENANCE).count(),
        "categories": base_qs.exclude(category="").values("category").distinct().count(),
    }
    edit_id = request.GET.get("edit")
    edit_obj = base_qs.filter(id=edit_id).first() if edit_id else None
    return render(
        request,
        "admin_panel/payment_gateways.html",
        {
            "rows": rows,
            "scope": scope,
            "edit_obj": edit_obj,
            "stats": stats,
            "treasury_scope": treasury_scope,
            "type_filter": type_filter,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def payment_requests(request):
    req_type = (request.GET.get("type") or "deposit").lower()
    if req_type not in {"deposit", "withdraw"}:
        req_type = "deposit"

    tx_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT] if req_type == "deposit" else [
        Transaction.TxType.CLIENT_WITHDRAW,
        Transaction.TxType.WALLET_WITHDRAW,
        Transaction.TxType.PENDING_IB_WITHDRAW,
        Transaction.TxType.IB_WITHDRAW,
    ]

    if request.method == "POST":
        tx_id = request.POST.get("tx_id", "")
        action = request.POST.get("action", "")
        reject_reason = (request.POST.get("reject_reason") or "").strip()
        tx = Transaction.objects.filter(id=tx_id, tx_type__in=tx_types).first()
        if not tx:
            messages.error(request, "Request not found.")
            return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")

        if action == "approve":
            if req_type == "withdraw" and tx.status == Transaction.Status.PENDING:
                with db_transaction.atomic():
                    locked_tx = Transaction.objects.select_for_update().get(id=tx.id)
                    if locked_tx.status != Transaction.Status.PENDING:
                        messages.error(request, "Request already processed.")
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
                    if locked_tx.tx_type in [Transaction.TxType.PENDING_IB_WITHDRAW, Transaction.TxType.IB_WITHDRAW]:
                        locked_tx.status = Transaction.Status.COMPLETED
                        locked_tx.processed_at = timezone.now()
                        locked_tx.processed_by = request.user
                        locked_tx.save(update_fields=["status", "processed_at", "processed_by"])
                        log_audit(
                            action="IB_WITHDRAW_APPROVE",
                            entity_type="Transaction",
                            entity_id=str(locked_tx.id),
                            actor=request.user,
                            channel=AuditLogChannel.ADMIN,
                            request=request,
                            ip=get_client_ip(request),
                            metadata={"amount": str(locked_tx.amount), "ib_user_id": locked_tx.actor_id},
                        )
                        messages.success(request, f"IB Withdrawal request of ${locked_tx.amount} approved.")
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")

                    user = User.objects.select_for_update().get(id=locked_tx.actor_id)
                    amt = Decimal(str(locked_tx.amount or 0))
                    pending_amt = Decimal(str(user.pending_withdraw or 0))
                    if pending_amt < amt:
                        messages.error(
                            request,
                            "Cannot approve: client pending-withdrawal is lower than this request.",
                        )
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    if wallet_before < amt:
                        messages.error(
                            request,
                            "Cannot approve: client wallet balance is lower than this withdrawal amount.",
                        )
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
                    user.wallet_balance = wallet_before - amt
                    user.pending_withdraw = pending_amt - amt
                    user.save(update_fields=["wallet_balance", "pending_withdraw"])
                    locked_tx.status = Transaction.Status.APPROVED
                    locked_tx.processed_at = timezone.now()
                    locked_tx.processed_by = request.user
                    locked_tx.save(update_fields=["status", "processed_at", "processed_by"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.WITHDRAW_APPROVE,
                        amount=amt,
                        currency=locked_tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=pending_amt,
                        pending_after=user.pending_withdraw,
                        reference=str(locked_tx.id),
                        note="Withdrawal approved — wallet debited (payment requests)",
                    )
                    log_audit(
                        action="WITHDRAW_APPROVE",
                        entity_type="Transaction",
                        entity_id=str(locked_tx.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"amount": str(amt), "currency": locked_tx.currency, "via": "payment_requests"},
                    )
                    if user.email:
                        try:
                            ok, _ = send_event_email(
                                "withdrawal_approved",
                                to_email=user.email,
                                user=user,
                                extra_context={
                                    "name": user.display_name(),
                                    "client_name": user.display_name(),
                                    "amount": f"{locked_tx.amount} {locked_tx.currency}",
                                    "withdrawal_amount": f"{locked_tx.amount} {locked_tx.currency}",
                                    "method": locked_tx.payment_gateway.name if locked_tx.payment_gateway else "-",
                                    "payment_method": locked_tx.payment_gateway.name if locked_tx.payment_gateway else "-",
                                    "transaction_id": str(locked_tx.id),
                                    "date": timezone.localtime(locked_tx.processed_at).strftime("%Y-%m-%d %H:%M") if locked_tx.processed_at else "",
                                },
                            )
                        except Exception:
                            logger.exception("payment_requests withdrawal_approved email failed", extra={"tx_id": locked_tx.id})
                    messages.success(request, "Request updated successfully.")
                    return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
            elif req_type == "withdraw":
                messages.error(request, "This withdrawal is not pending.")
                return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
            tx.status = Transaction.Status.APPROVED
        elif action == "reject":
            if not reject_reason:
                messages.error(request, "Reject reason is required.")
                return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
            if req_type == "withdraw" and tx.status == Transaction.Status.PENDING:
                with db_transaction.atomic():
                    locked_tx = Transaction.objects.select_for_update().get(id=tx.id)
                    if locked_tx.status != Transaction.Status.PENDING:
                        messages.error(request, "Request already processed.")
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
                    if locked_tx.tx_type in [Transaction.TxType.PENDING_IB_WITHDRAW, Transaction.TxType.IB_WITHDRAW]:
                        locked_tx.status = Transaction.Status.REJECTED
                        locked_tx.reject_reason = reject_reason
                        locked_tx.processed_at = timezone.now()
                        locked_tx.processed_by = request.user
                        locked_tx.save(update_fields=["status", "reject_reason", "processed_at", "processed_by"])
                        log_audit(
                            action="IB_WITHDRAW_REJECT",
                            entity_type="Transaction",
                            entity_id=str(locked_tx.id),
                            actor=request.user,
                            channel=AuditLogChannel.ADMIN,
                            request=request,
                            ip=get_client_ip(request),
                            metadata={"amount": str(locked_tx.amount), "ib_user_id": locked_tx.actor_id, "reason": reject_reason},
                        )
                        messages.success(request, f"IB Withdrawal request of ${locked_tx.amount} rejected.")
                        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")

                    user = User.objects.select_for_update().get(id=locked_tx.actor_id)
                    amt = Decimal(str(locked_tx.amount or 0))
                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    pending_amt = Decimal(str(user.pending_withdraw or 0))
                    user.pending_withdraw = max(pending_amt - amt, Decimal("0"))
                    user.save(update_fields=["pending_withdraw"])
                    locked_tx.status = Transaction.Status.REJECTED
                    locked_tx.processed_at = timezone.now()
                    locked_tx.reject_reason = reject_reason
                    locked_tx.processed_by = request.user
                    locked_tx.save(update_fields=["status", "processed_at", "reject_reason", "processed_by"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.WITHDRAW_REJECT,
                        amount=amt,
                        currency=locked_tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=pending_amt,
                        pending_after=user.pending_withdraw,
                        reference=str(locked_tx.id),
                        note="Withdrawal rejected (payment requests)",
                    )
                    log_audit(
                        action="WITHDRAW_REJECT",
                        entity_type="Transaction",
                        entity_id=str(locked_tx.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"reject_reason": reject_reason, "via": "payment_requests"},
                    )
                    if user.email:
                        try:
                            ok, _ = send_event_email(
                                "withdrawal_rejected",
                                to_email=user.email,
                                user=user,
                                extra_context={
                                    "name": user.display_name(),
                                    "client_name": user.display_name(),
                                    "amount": f"{locked_tx.amount} {locked_tx.currency}",
                                    "withdrawal_amount": f"{locked_tx.amount} {locked_tx.currency}",
                                    "method": locked_tx.payment_gateway.name if locked_tx.payment_gateway else "-",
                                    "payment_method": locked_tx.payment_gateway.name if locked_tx.payment_gateway else "-",
                                    "transaction_id": str(locked_tx.id),
                                    "date": timezone.localtime(locked_tx.processed_at).strftime("%Y-%m-%d %H:%M") if locked_tx.processed_at else "",
                                    "reason": reject_reason,
                                    "reject_reason": reject_reason,
                                },
                            )
                        except Exception:
                            logger.exception("payment_requests withdrawal_rejected email failed", extra={"tx_id": locked_tx.id})
                    messages.success(request, "Request updated successfully.")
                    return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
            elif req_type == "withdraw":
                messages.error(request, "This withdrawal is not pending.")
                return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")
            tx.status = Transaction.Status.REJECTED
            tx.reject_reason = reject_reason
        elif action in {"mark_paid", "processed"}:
            tx.status = Transaction.Status.COMPLETED
        else:
            messages.error(request, "Invalid action.")
            return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")

        tx.processed_at = timezone.now()
        save_fields = ["status", "processed_at"]
        if action == "reject":
            save_fields.append("reject_reason")
        tx.save(update_fields=save_fields)
        if req_type == "deposit" and action == "reject":
            if not BalanceLedger.objects.filter(
                reference=str(tx.id), entry_type=BalanceLedger.EntryType.DEPOSIT_REJECT
            ).exists():
                dep_user = User.objects.filter(id=tx.actor_id).first()
                if dep_user:
                    amt_rej = Decimal(str(tx.amount or 0))
                    wb = Decimal(str(dep_user.wallet_balance or 0))
                    pb = Decimal(str(dep_user.pending_withdraw or 0))
                    BalanceLedger.objects.create(
                        user=dep_user,
                        entry_type=BalanceLedger.EntryType.DEPOSIT_REJECT,
                        amount=amt_rej,
                        currency=tx.currency,
                        wallet_before=wb,
                        wallet_after=wb,
                        pending_before=pb,
                        pending_after=pb,
                        reference=str(tx.id),
                        note="Deposit rejected",
                    )
        if req_type == "deposit" and action in {"approve", "mark_paid", "processed"}:
            with db_transaction.atomic():
                locked_tx = Transaction.objects.select_for_update().get(id=tx.id)
                if not BalanceLedger.objects.filter(reference=str(locked_tx.id), entry_type=BalanceLedger.EntryType.DEPOSIT_APPROVE).exists():
                    user = User.objects.select_for_update().get(id=locked_tx.actor_id)
                    amt = Decimal(str(locked_tx.amount or 0))
                    wallet_before = Decimal(str(user.wallet_balance or 0))
                    user.wallet_balance = wallet_before + amt
                    user.save(update_fields=["wallet_balance"])
                    BalanceLedger.objects.create(
                        user=user,
                        entry_type=BalanceLedger.EntryType.DEPOSIT_APPROVE,
                        amount=amt,
                        currency=locked_tx.currency,
                        wallet_before=wallet_before,
                        wallet_after=user.wallet_balance,
                        pending_before=Decimal(str(user.pending_withdraw or 0)),
                        pending_after=Decimal(str(user.pending_withdraw or 0)),
                        reference=str(locked_tx.id),
                        note="Deposit approved/completed",
                    )
        if tx.actor and tx.actor.email:
            event_key = None
            if req_type == "deposit":
                if action in {"approve", "mark_paid", "processed"}:
                    event_key = "deposit_approved"
                elif action == "reject":
                    event_key = "deposit_rejected"
            else:
                if action == "approve":
                    event_key = "withdrawal_approved"
                elif action == "reject":
                    event_key = "withdrawal_rejected"
            if event_key:
                send_event_email(
                    event_key,
                    to_email=tx.actor.email,
                    user=tx.actor,
                    extra_context={
                        "name": tx.actor.display_name(),
                        "client_name": tx.actor.display_name(),
                        "amount": f"{tx.amount} {tx.currency}",
                        "deposit_amount": f"{tx.amount} {tx.currency}",
                        "withdrawal_amount": f"{tx.amount} {tx.currency}",
                        "method": tx.payment_gateway.name if tx.payment_gateway else "-",
                        "payment_method": tx.payment_gateway.name if tx.payment_gateway else "-",
                        "transaction_id": str(tx.id),
                        "date": timezone.localtime(tx.processed_at).strftime("%Y-%m-%d %H:%M") if tx.processed_at else "",
                        "reason": tx.reject_reason or reject_reason,
                        "reject_reason": tx.reject_reason or reject_reason,
                    },
                )
        messages.success(request, "Request updated successfully.")
        return redirect(f"{reverse('admin-payment-requests')}?type={req_type}")

    status = (request.GET.get("status") or "").upper()
    status_group = (request.GET.get("status_group") or "").strip().lower()
    payment_method = (request.GET.get("method") or "").strip()
    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()
    q = (request.GET.get("q") or "").strip()
    period = (request.GET.get("period") or "").strip().lower()
    if period in {"today", "week"} and not from_date and not to_date:
        td = timezone.localdate()
        if period == "today":
            from_date = to_date = td.isoformat()
        else:
            from_date = (td - timedelta(days=6)).isoformat()
            to_date = td.isoformat()
    qs = (
        Transaction.objects.select_related("actor", "payment_gateway", "actor__referred_by")
        .filter(tx_type__in=tx_types, is_demo_ledger=False)
        .order_by("-created_at")
    )
    if status_group == "approved":
        qs = qs.filter(status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])
    elif status_group == "rejected":
        qs = qs.filter(status=Transaction.Status.REJECTED)
    elif status in {"PENDING", "APPROVED", "COMPLETED", "REJECTED"}:
        qs = qs.filter(status=status)
    if payment_method:
        qs = qs.filter(payment_gateway__name__icontains=payment_method)
    if from_date:
        qs = qs.filter(created_at__date__gte=from_date)
    if to_date:
        qs = qs.filter(created_at__date__lte=to_date)
    if q:
        qs = qs.filter(Q(reference__icontains=q) | Q(notes__icontains=q) | Q(actor__email__icontains=q))
    export_fmt = (request.GET.get("export") or "").lower()
    if export_fmt in {"excel", "csv"}:
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = f'attachment; filename="{req_type}_requests.csv"'
        w = csv.writer(response)
        w.writerow(["MT5 ID", "Amount", "Payment Method", "Note", "Comment", "Status", "Date", "Marketing Name", "Approved/Rejected By"])
        for t in qs[:5000]:
            w.writerow([
                t.reference or "-",
                t.amount,
                t.payment_gateway.name if t.payment_gateway else "-",
                t.notes or "-",
                t.account_details or "-",
                t.status,
                timezone.localtime(t.created_at).strftime("%Y-%m-%d %H:%M"),
                t.actor.referred_by.display_name() if t.actor and t.actor.referred_by_id else "-",
                "System",
            ])
        return response
    paginator = Paginator(qs, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "admin_panel/payment_requests.html",
        {
            "page_obj": page_obj,
            "req_type": req_type,
            "filters": {
                "status": status,
                "status_group": status_group,
                "method": payment_method,
                "from": from_date,
                "to": to_date,
                "q": q,
                "period": period,
            },
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def transfers_admin(request):
    transfer_type = request.GET.get("type") or ""
    email = request.GET.get("email") or ""

    qs = InternalTransfer.objects.select_related("user").all()
    if transfer_type:
        qs = qs.filter(transfer_type=transfer_type)
    if email:
        qs = qs.filter(user__email__icontains=email)

    if request.method == "POST":
        row_id = request.POST.get("row_id") or ""
        action = request.POST.get("action") or ""
        row = InternalTransfer.objects.select_related("user").filter(id=row_id).first()
        if not row:
            messages.error(request, "Transfer not found.")
            return redirect("admin-transfers")

        if row.status != InternalTransfer.Status.PENDING:
            messages.error(request, "Transfer already processed.")
            return redirect("admin-transfers")

        if action == "reject":
            row.status = InternalTransfer.Status.REJECTED
            row.processed_by = request.user
            row.processed_at = timezone.now()
            row.save(update_fields=["status", "processed_by", "processed_at"])
            messages.success(request, "Transfer rejected.")
            log_audit(
                action="INTERNAL_TRANSFER_REJECT",
                entity_type="InternalTransfer",
                entity_id=str(row.id),
                actor=request.user,
                channel=AuditLogChannel.ADMIN,
                request=request,
                ip=get_client_ip(request),
            )
            return redirect("admin-transfers")

        if action == "approve":
            m_uid = re.search(r"request_uid=([^\s]+)", row.note or "")
            request_uid = m_uid.group(1) if m_uid else str(row.id)
            try:
                with db_transaction.atomic():
                    row_locked = InternalTransfer.objects.select_for_update().filter(id=row.id).first()
                    if not row_locked or row_locked.status != InternalTransfer.Status.PENDING:
                        messages.error(request, "Transfer already processed.")
                        return redirect("admin-transfers")
                    locked_user = User.objects.select_for_update().get(id=row_locked.user_id)
                    err = apply_internal_transfer_balances(
                        locked_user,
                        transfer_type=row_locked.transfer_type,
                        from_account=row_locked.from_account,
                        to_account=row_locked.to_account,
                        amount=Decimal(str(row_locked.amount)),
                        request_uid=request_uid,
                    )
                    if err:
                        messages.error(request, err)
                        return redirect("admin-transfers")
                    row_locked.status = InternalTransfer.Status.APPROVED
                    row_locked.processed_by = request.user
                    row_locked.processed_at = timezone.now()
                    row_locked.save(update_fields=["status", "processed_by", "processed_at"])
                messages.success(request, "Transfer approved.")
                log_audit(
                    action="INTERNAL_TRANSFER_APPROVE",
                    entity_type="InternalTransfer",
                    entity_id=str(row_locked.id),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"amount": str(row_locked.amount)},
                )
            except Exception:
                messages.error(request, "Transfer approval failed.")
            return redirect("admin-transfers")

    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()
    status = (request.GET.get("status") or "").strip().upper()
    if from_date:
        qs = qs.filter(created_at__date__gte=from_date)
    if to_date:
        qs = qs.filter(created_at__date__lte=to_date)
    if status in {"PENDING", "APPROVED", "REJECTED"}:
        qs = qs.filter(status=status)
    if (request.GET.get("export") or "").lower() == "excel":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="internal_transfer_report.csv"'
        w = csv.writer(response)
        w.writerow(["Date", "User", "Type", "From", "To", "Amount", "Status"])
        for r in qs.order_by("-created_at")[:5000]:
            w.writerow([timezone.localtime(r.created_at).strftime("%Y-%m-%d %H:%M"), r.user.email, r.transfer_type, r.from_account, r.to_account, r.amount, r.status])
        return response
    transfer_types = [c[0] for c in InternalTransfer.TransferType.choices]
    paginator = Paginator(qs.order_by("-created_at"), 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "admin_panel/transfers.html",
        {"page_obj": page_obj, "transfer_types": transfer_types, "filters": {"type": transfer_type, "email": email, "from": from_date, "to": to_date, "status": status}},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def report_position(request):
    account_id = (request.GET.get("account") or "").strip()
    q = (request.GET.get("q") or "").strip()
    accounts = MT5Account.objects.select_related("user").order_by("-updated_at")
    rows = accounts
    if account_id:
        rows = rows.filter(id=account_id)
    if q:
        rows = rows.filter(Q(login_id__icontains=q) | Q(user__email__icontains=q))
    paginator = Paginator(rows, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    summary = {
        "balance": rows.aggregate(v=Sum("balance"))["v"] or 0,
        "equity": rows.aggregate(v=Sum("equity"))["v"] or 0,
        "profit": rows.aggregate(v=Sum("unrealized_pnl"))["v"] or 0,
        "free_margin": rows.aggregate(v=Sum("free_margin"))["v"] or 0,
    }

    positions = []
    from mt5_integration.services import _mt5_client, is_mt5_configured
    if is_mt5_configured():
        try:
            with _mt5_client() as client:
                if account_id:
                    acc = MT5Account.objects.filter(id=account_id).first()
                    if acc:
                        raw = client.position_get_page(int(acc.login_id), 0, 100)
                        for pos in raw:
                            symbol_name = pos.get("Symbol") or ""
                            login_str = str(pos.get("Login") or "")
                            if q and q.lower() not in symbol_name.lower() and q.lower() not in login_str:
                                continue
                            positions.append({
                                "login_id": pos.get("Login"),
                                "symbol": symbol_name,
                                "ticket": pos.get("Position"),
                                "time": timezone.datetime.fromtimestamp(pos.get("TimeCreate", 0), tz=timezone.utc),
                                "type": "Sell" if pos.get("Action") == 1 else "Buy",
                                "volume": round(pos.get("Volume", 0) / 10000.0, 2),
                                "open_price": pos.get("PriceOpen"),
                                "sl": pos.get("PriceSL"),
                                "tp": pos.get("PriceTP"),
                                "current_price": pos.get("PriceCurrent"),
                                "profit": pos.get("Profit"),
                            })
                else:
                    for acc in page_obj:
                        try:
                            raw = client.position_get_page(int(acc.login_id), 0, 50)
                            for pos in raw:
                                symbol_name = pos.get("Symbol") or ""
                                login_str = str(pos.get("Login") or "")
                                if q and q.lower() not in symbol_name.lower() and q.lower() not in login_str:
                                    continue
                                positions.append({
                                    "login_id": pos.get("Login"),
                                    "symbol": symbol_name,
                                    "ticket": pos.get("Position"),
                                    "time": timezone.datetime.fromtimestamp(pos.get("TimeCreate", 0), tz=timezone.utc),
                                    "type": "Sell" if pos.get("Action") == 1 else "Buy",
                                    "volume": round(pos.get("Volume", 0) / 10000.0, 2),
                                    "open_price": pos.get("PriceOpen"),
                                    "sl": pos.get("PriceSL"),
                                    "tp": pos.get("PriceTP"),
                                    "current_price": pos.get("PriceCurrent"),
                                    "profit": pos.get("Profit"),
                                })
                        except Exception as e:
                            logger.warning("Failed to fetch positions for %s: %s", acc.login_id, e)
        except Exception as exc:
            logger.warning("MT5 positions fetch failed: %s", exc)

    return render(
        request,
        "admin_panel/report_position.html",
        {
            "page_obj": page_obj,
            "positions": positions,
            "accounts": accounts[:1000],
            "summary": summary,
            "filters": {"account": account_id, "q": q},
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def report_history(request):
    account_id = (request.GET.get("account") or "").strip()
    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()
    q = (request.GET.get("q") or "").strip()
    tx = Transaction.objects.select_related("actor", "payment_gateway").order_by("-created_at")
    if account_id:
        tx = tx.filter(reference__icontains=account_id)
    if from_date:
        tx = tx.filter(created_at__date__gte=from_date)
    if to_date:
        tx = tx.filter(created_at__date__lte=to_date)
    if q:
        tx = tx.filter(Q(reference__icontains=q) | Q(actor__email__icontains=q) | Q(notes__icontains=q))
    paginator = Paginator(tx, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    summary = {
        "deposit": tx.filter(tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]).aggregate(v=Sum("amount"))["v"] or 0,
        "withdrawal": tx.filter(tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]).aggregate(v=Sum("amount"))["v"] or 0,
        "swap": 0,
        "commission": tx.filter(tx_type=Transaction.TxType.IB_WITHDRAW).aggregate(v=Sum("amount"))["v"] or 0,
    }
    return render(request, "admin_panel/report_history.html", {"page_obj": page_obj, "filters": {"account": account_id, "from": from_date, "to": to_date, "q": q}, "summary": summary})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def report_user_lot(request):
    q = (request.GET.get("q") or "").strip()
    users = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).annotate(total_lots=Count("mt5_accounts")).order_by("-total_lots", "email")
    if q:
        users = users.filter(Q(email__icontains=q) | Q(first_name__icontains=q) | Q(last_name__icontains=q))
    paginator = Paginator(users, 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(request, "admin_panel/report_user_lot.html", {"page_obj": page_obj, "filters": {"q": q}})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def admin_ib_withdrawals(request):
    from django.db import transaction as db_transaction
    from django.core.paginator import Paginator
    from transactions.models import Transaction

    if request.method == "POST":
        tx_id = request.POST.get("tx_id")
        action = request.POST.get("action")
        reject_reason = (request.POST.get("reject_reason") or "").strip()

        try:
            with db_transaction.atomic():
                tx = Transaction.objects.select_for_update().filter(
                    id=tx_id, 
                    tx_type=Transaction.TxType.PENDING_IB_WITHDRAW, 
                    status=Transaction.Status.PENDING
                ).first()

                if not tx:
                    messages.error(request, "Pending transaction not found or already processed.")
                elif action == "approve":
                    tx.status = Transaction.Status.COMPLETED
                    tx.processed_by = request.user
                    tx.processed_at = timezone.now()
                    tx.save(update_fields=["status", "processed_by", "processed_at"])
                    
                    messages.success(request, f"Withdrawal request of ${tx.amount} approved.")
                    log_audit(
                        action="IB_WITHDRAW_APPROVE",
                        entity_type="Transaction",
                        entity_id=str(tx.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"amount": str(tx.amount), "ib_user_id": tx.actor_id},
                    )
                elif action == "reject":
                    from transactions.utils import ensure_unique_action
                    try:
                        ensure_unique_action(f"IB_WITHDRAW_REJ_{tx.id}", "IB_WITHDRAW_REJECT")
                    except ValueError as e:
                        messages.error(request, str(e))
                        return redirect(back_url)

                    tx.status = Transaction.Status.REJECTED
                    tx.reject_reason = reject_reason or "Rejected by Admin."
                    tx.processed_by = request.user
                    tx.processed_at = timezone.now()
                    tx.save(update_fields=["status", "reject_reason", "processed_by", "processed_at"])
                    
                    messages.success(request, f"Withdrawal request of ${tx.amount} rejected.")
                    log_audit(
                        action="IB_WITHDRAW_REJECT",
                        entity_type="Transaction",
                        entity_id=str(tx.id),
                        actor=request.user,
                        channel=AuditLogChannel.ADMIN,
                        request=request,
                        ip=get_client_ip(request),
                        metadata={"amount": str(tx.amount), "ib_user_id": tx.actor_id, "reason": reject_reason},
                    )
        except Exception as e:
            messages.error(request, f"Failed to process request: {e}")
        return redirect("admin-ib-withdrawals")

    qs = Transaction.objects.filter(tx_type=Transaction.TxType.PENDING_IB_WITHDRAW).select_related("actor").order_by("-created_at")
    
    # Filter by status
    status_filter = (request.GET.get("status") or "PENDING").strip().upper()
    if status_filter in {"PENDING", "APPROVED", "COMPLETED", "REJECTED"}:
        if status_filter == "APPROVED":
            qs = qs.filter(status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])
        else:
            qs = qs.filter(status=status_filter)

    paginator = Paginator(qs, 20)
    page_obj = paginator.get_page(request.GET.get("page"))

    return render(
        request,
        "admin_panel/admin_ib_withdrawals.html",
        {
            "page_obj": page_obj,
            "status_filter": status_filter,
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def admin_manual_rebate_adjustment(request):
    from transactions.models import Transaction

    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")

    if request.method == "POST":
        ib_user_id = request.POST.get("ib_user_id")
        amount_str = (request.POST.get("amount") or "").strip()
        adj_type = request.POST.get("adjustment_type")
        notes = (request.POST.get("notes") or "").strip()

        ib_user = User.objects.filter(id=ib_user_id, role=User.Roles.IB).first()
        try:
            amount = Decimal(amount_str)
        except Exception:
            amount = Decimal("0")

        if not ib_user:
            messages.error(request, "Selected user is not a valid Introducing Broker.")
        elif amount <= 0:
            messages.error(request, "Please enter a positive amount for adjustment.")
        elif adj_type not in ("credit", "debit"):
            messages.error(request, "Invalid adjustment type selected.")
        else:
            if adj_type == "credit":
                tx = Transaction.objects.create(
                    tx_type=Transaction.TxType.IB_WITHDRAW,
                    status=Transaction.Status.COMPLETED,
                    actor=ib_user,
                    amount=amount,
                    currency="USD",
                    notes=f"Manual Adjustment Credit | {notes}",
                    processed_by=request.user,
                    processed_at=timezone.now(),
                )
            else:
                tx = Transaction.objects.create(
                    tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
                    status=Transaction.Status.COMPLETED,
                    actor=ib_user,
                    amount=amount,
                    currency="USD",
                    notes=f"Manual Adjustment Debit | {notes}",
                    processed_by=request.user,
                    processed_at=timezone.now(),
                )

            messages.success(request, f"Successfully processed manual {adj_type} of ${amount:.2f} for {ib_user.email}.")
            log_audit(
                action=f"IB_MANUAL_ADJUSTMENT_{adj_type.upper()}",
                entity_type="Transaction",
                entity_id=str(tx.id),
                actor=request.user,
                channel=AuditLogChannel.ADMIN,
                request=request,
                ip=get_client_ip(request),
                metadata={"ib_user_id": ib_user.id, "amount": str(amount), "notes": notes},
            )
            return redirect("admin-manual-rebate-adjustment")

    recent_adjustments = Transaction.objects.filter(
        tx_type__in=[Transaction.TxType.IB_WITHDRAW, Transaction.TxType.PENDING_IB_WITHDRAW],
        notes__icontains="Manual Adjustment"
    ).select_related("actor").order_by("-created_at")[:20]

    return render(
        request,
        "admin_panel/admin_ib_adjustments.html",
        {
            "ib_users": ib_users,
            "recent_adjustments": recent_adjustments,
        }
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def admin_trigger_rebate_sync(request):
    from ib.services import sync_mt5_deals_and_calculate_rebates

    res = sync_mt5_deals_and_calculate_rebates()
    
    if res.get("status") == "success":
        messages.success(request, f"Rebate sync completed. Processed {res.get('processed_count', 0)} deals.")
    else:
        messages.error(request, f"Rebate sync failed/skipped: {res.get('reason') or res.get('message') or 'Unknown error'}")
        
    log_audit(
        action="IB_REBATE_SYNC_TRIGGERED",
        entity_type="System",
        actor=request.user,
        channel=AuditLogChannel.ADMIN,
        request=request,
        ip=get_client_ip(request),
        metadata=res,
    )
    return redirect(request.META.get("HTTP_REFERER") or "admin-ib-requests")

@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def admin_ib_tree(request, ib_id):
    ib_user = get_object_or_404(User, id=ib_id)
    
    # 1. Get level 1 clients (direct)
    direct_ids = list(IBRequest.objects.filter(ib_user=ib_user, status=IBRequest.Status.APPROVED).values_list("client_user_id", flat=True))
    level1_ids = [cid for cid in direct_ids if cid != ib_user.id]
    
    # 2. Get level 2 clients
    level2_ids = list(IBRequest.objects.filter(ib_user_id__in=level1_ids, status=IBRequest.Status.APPROVED).values_list("client_user_id", flat=True))
    
    # 3. Get level 3 clients
    level3_ids = list(IBRequest.objects.filter(ib_user_id__in=level2_ids, status=IBRequest.Status.APPROVED).values_list("client_user_id", flat=True))
    
    def annotate_deposits(user_ids):
        users = User.objects.filter(id__in=user_ids)
        # Sum of CLIENT_DEPOSIT and WALLET_DEPOSIT
        users = users.annotate(
            total_deposit=Sum(
                "transactions_as_actor__amount",
                filter=Q(
                    transactions_as_actor__tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                    transactions_as_actor__status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
                )
            ),
            total_withdrawal=Sum(
                "transactions_as_actor__amount",
                filter=Q(
                    transactions_as_actor__tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW, Transaction.TxType.IB_WITHDRAW],
                    transactions_as_actor__status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
                )
            )
        )
        return users

    level1 = annotate_deposits(level1_ids)
    level2 = annotate_deposits(level2_ids)
    level3 = annotate_deposits(level3_ids)

    return render(request, "admin_panel/ib_tree.html", {
        "ib_user": ib_user,
        "level1": level1,
        "level2": level2,
        "level3": level3
    })
