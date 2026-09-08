from __future__ import annotations

from collections import defaultdict
from datetime import timedelta
from decimal import Decimal
import logging

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.paginator import Paginator
from django.db.models import Count, Q
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from mt5_integration.models import MT5Deal
from enterprise.models import LoginEvent
from accounts.models import MT5Account

from .models import RiskMonitorSettings

logger = logging.getLogger(__name__)

def _as_decimal(v) -> Decimal:
    try:
        return Decimal(str(v or 0))
    except Exception:
        return Decimal("0")

def get_country_from_ip(ip):
    # IP/Country detection empty as per user requirement
    return ""

@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def risk_monitor_dashboard(request):
    settings_obj = RiskMonitorSettings.get_solo()
    if request.method == "POST":
        def get_int(k, d):
            val = (request.POST.get(k) or "").strip()
            return int(val) if val.isdigit() else d
            
        def get_dec(k, d):
            val = (request.POST.get(k) or "").strip()
            try: return Decimal(val)
            except: return d
            
        settings_obj.short_duration_max_seconds = get_int("short_duration_max_seconds", settings_obj.short_duration_max_seconds)
        settings_obj.high_profit_threshold = get_dec("high_profit_threshold", settings_obj.high_profit_threshold)
        settings_obj.large_lot_threshold = get_dec("large_lot_threshold", settings_obj.large_lot_threshold)
        settings_obj.hft_trades_per_minute = get_int("hft_trades_per_minute", settings_obj.hft_trades_per_minute)
        settings_obj.single_symbol_monitoring_days = get_int("single_symbol_monitoring_days", settings_obj.single_symbol_monitoring_days)
        settings_obj.hedging_time_window_minutes = get_int("hedging_time_window_minutes", settings_obj.hedging_time_window_minutes)
        settings_obj.multiple_ip_monitoring_days = get_int("multiple_ip_monitoring_days", settings_obj.multiple_ip_monitoring_days)
        settings_obj.enable_country_mismatch = request.POST.get("enable_country_mismatch") == "on"
        
        settings_obj.save()
        messages.success(request, "Risk Monitor settings updated.")
        return redirect("admin-risk-monitor")

    now = timezone.now()
    today = timezone.localdate()
    
    recent_deals = MT5Deal.objects.filter(time__gte=now - timedelta(days=1))
    
    short_duration_count = 0
    high_profit_count = 0
    large_lot_count = 0
    
    out_deals = recent_deals.filter(entry_type=1)
    
    for deal in out_deals:
        if abs(deal.profit) >= settings_obj.high_profit_threshold:
            high_profit_count += 1
            
        if deal.lots > float(settings_obj.large_lot_threshold):
            large_lot_count += 1
            
        in_deal = MT5Deal.objects.filter(position_ticket=deal.position_ticket, entry_type=0).first()
        if in_deal:
            duration = (deal.time - in_deal.time).total_seconds()
            if 0 <= duration < settings_obj.short_duration_max_seconds:
                short_duration_count += 1
                
    hft_count = 0
    minute_deal_counts = defaultdict(int)
    for t in recent_deals.filter(time__date=today).only("client_id", "time"):
        if t.client_id:
            minute = timezone.localtime(t.time).strftime("%Y-%m-%d %H:%M")
            minute_deal_counts[(t.client_id, minute)] += 1
    
    hft_users = set()
    for (cid, min_str), count in minute_deal_counts.items():
        if count > settings_obj.hft_trades_per_minute:
            hft_users.add(cid)
    hft_count = len(hft_users)
    
    single_sym_count = 0
    sym_days = settings_obj.single_symbol_monitoring_days
    sym_from = now - timedelta(days=sym_days)
    user_symbols = defaultdict(set)
    for t in MT5Deal.objects.filter(time__gte=sym_from).only("client_id", "symbol"):
        if t.client_id and t.symbol:
            user_symbols[t.client_id].add(t.symbol)
    for cid, syms in user_symbols.items():
        if len(syms) == 1:
            single_sym_count += 1
            
    hedge_pairs = 0
    
    multi_ip_days = settings_obj.multiple_ip_monitoring_days
    ip_from = now - timedelta(days=multi_ip_days)
    user_ips = defaultdict(set)
    for log in LoginEvent.objects.filter(created_at__gte=ip_from, success=True).only("user_id", "ip"):
        if log.user_id and log.ip:
            user_ips[log.user_id].add(log.ip)
            
    multi_ip_count = sum(1 for ips in user_ips.values() if len(ips) > 1)
    
    country_mismatch_count = 0
    if settings_obj.enable_country_mismatch:
        recent_logins = LoginEvent.objects.filter(created_at__gte=now - timedelta(days=1), success=True).select_related("user")
        checked_users = set()
        for log in recent_logins:
            if log.user and log.user.id not in checked_users:
                checked_users.add(log.user.id)
                reg_country = log.user.country or ""
                ip_country = get_country_from_ip(log.ip)
                if ip_country and reg_country.lower() != ip_country.lower():
                    country_mismatch_count += 1

    ctx = {
        "title": "Risk Monitor",
        "settings_obj": settings_obj,
        "metrics": {
            "short_duration": short_duration_count,
            "high_profit": high_profit_count,
            "large_lot": large_lot_count,
            "hft_accounts": hft_count,
            "single_symbol": single_sym_count,
            "same_ip_hedge": hedge_pairs,
            "multiple_ip": multi_ip_count,
            "country_mismatch": country_mismatch_count,
        },
        "now": now,
    }
    return render(request, "admin_panel/risk_monitor/dashboard.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def risk_monitor_positions(request):
    rule = (request.GET.get("rule") or "").strip()
    account = (request.GET.get("account") or "").strip()
    user_q = (request.GET.get("user") or "").strip()
    symbol = (request.GET.get("symbol") or "").strip().upper()
    status = (request.GET.get("status") or "closed").strip().lower()

    if status == "open":
        from mt5_integration.services import _mt5_client, is_mt5_configured
        
        acc_qs = MT5Account.objects.select_related("user").all()
        if account:
            acc_qs = acc_qs.filter(login_id__icontains=account)
        if user_q:
            acc_qs = acc_qs.filter(
                Q(user__email__icontains=user_q)
                | Q(user__first_name__icontains=user_q)
                | Q(user__last_name__icontains=user_q)
            )

        open_positions = []
        if is_mt5_configured():
            try:
                with _mt5_client() as client:
                    for acc in acc_qs[:100]:
                        try:
                            raw = client.position_get_page(int(acc.login_id), 0, 100)
                            for pos in raw:
                                if symbol and symbol not in (pos.get("Symbol") or "").upper():
                                    continue
                                open_positions.append({
                                    "account_number": acc.login_id,
                                    "client": acc.user,
                                    "symbol": pos.get("Symbol"),
                                    "type": "Sell" if pos.get("Action") == 1 else "Buy",
                                    "lots": round(pos.get("Volume", 0) / 10000.0, 2),
                                    "open_price": pos.get("PriceOpen"),
                                    "close_price": pos.get("PriceCurrent"),
                                    "profit_display": pos.get("Profit"),
                                    "created_at": timezone.datetime.fromtimestamp(pos.get("TimeCreate", 0), tz=timezone.utc),
                                    "duration": f"{int(timezone.now().timestamp() - pos.get('TimeCreate', 0))}s",
                                    "is_live_open": True,
                                })
                        except Exception as e:
                            logger.warning("Failed to fetch positions for %s: %s", acc.login_id, e)
            except Exception as exc:
                logger.warning("MT5 connection failed during risk positions check: %s", exc)

        paginator = Paginator(open_positions, 30)
        page_obj = paginator.get_page(request.GET.get("page"))
    else:
        rows = MT5Deal.objects.select_related("client").all()
        
        if account:
            rows = rows.filter(login__icontains=account)
        if user_q:
            rows = rows.filter(
                Q(client__email__icontains=user_q)
                | Q(client__first_name__icontains=user_q)
                | Q(client__last_name__icontains=user_q)
            )
        if symbol:
            rows = rows.filter(symbol__icontains=symbol)

        settings_obj = RiskMonitorSettings.get_solo()
        if rule == "high_profit":
            rows = rows.filter(entry_type=1).exclude(profit__gt=-settings_obj.high_profit_threshold, profit__lt=settings_obj.high_profit_threshold)
        elif rule == "large_lot":
            vol_threshold = settings_obj.large_lot_threshold * Decimal("10000")
            rows = rows.filter(volume__gt=vol_threshold)
            
        paginator = Paginator(rows.order_by("-time"), 30)
        page_obj = paginator.get_page(request.GET.get("page"))

    return render(
        request,
        "admin_panel/risk_monitor/positions.html",
        {
            "title": f"Risk Monitor - {rule.replace('_', ' ').title()}" if rule else "All Deals",
            "page_obj": page_obj,
            "rule": rule,
            "filters": {
                "account": account,
                "user": user_q,
                "symbol": symbol,
                "status": status,
            },
        },
    )
