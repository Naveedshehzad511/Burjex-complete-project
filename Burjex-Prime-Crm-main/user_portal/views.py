from decimal import Decimal, ROUND_HALF_UP
from datetime import date, datetime, timedelta
from calendar import monthrange
from typing import Optional
import json
import logging
import uuid

from django import forms
from django.contrib.auth.decorators import login_required
from django.views.decorators.http import require_http_methods
from django.db import transaction
from django.db import transaction as db_transaction
from django.db.models import Count, Q, Sum
from django.urls import reverse
from django.shortcuts import redirect, render
from django.http import HttpResponse, JsonResponse
import csv
from django.core.paginator import Paginator
from django.utils import timezone
from django.contrib import messages
from django.core.exceptions import ValidationError

from enterprise.models import EnterpriseSecuritySettings, AuditLogChannel
from enterprise.audit import get_client_ip, log_audit
from enterprise.risk import adjust_risk_score
from enterprise.tasks import send_withdrawal_security_email_task
from enterprise.upload_security import validate_document_upload

from accounts.kyc_policy import (
    kyc_blocks_deposit,
    kyc_blocks_ib_request,
    kyc_blocks_internal_transfer,
    kyc_blocks_withdraw,
)
from accounts.models import (
    Document,
    KYCAddress,
    KYCIdentity,
    MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
    MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
    MT5Account,
    MT5Group,
    User,
    VerifiedBankAccount,
    VerifiedCryptoAddress,
)
from accounts.permissions import role_required
from accounts.restrictions import restriction_for_user
from ib.models import IBPlan, IBProfile, IBRequest
from ib.referral import build_register_referral_url, ensure_profile_referral_url
from transactions.internal_transfer_execution import apply_internal_transfer_balances, validate_internal_transfer_route
from transactions.models import BalanceLedger, InternalTransfer, Match2PayTransaction, PaymentGateway, Transaction
from transactions.services.match2pay_client import (
    ALLOWED_NETWORKS,
    NETWORK_DISPLAY_ORDER,
    create_crypto_deposit,
)
from transactions.real_ledger import filter_real_internal_transfers, filter_real_ledger_transactions, real_ledger_q
from admin_panel.models import (
    BankField,
    ComplianceSettings,
    CryptoNetwork,
    DashboardSettings,
    DemoAccountSettings,
    LegalAgreementSettings,
    LegalDocument,
    LegalAgreementsSettings,
    Match2PayIntegrationSettings,
    MatchTraderSettings,
    MatchTraderUserSnapshot,
    OrganizationProfileSettings,
    RequiredDocument,
    TradingPlatform,
    MatchTraderBrokerGroup,
    TradingAccount,
    TradingAccountType,
    TradingPlatformIntegration,
    TransferTreasurySettings,
    WalletTreasurySettings,
)
from admin_panel.email_service import send_dynamic_email
from admin_panel.services.kyc import recalc_user_kyc
from admin_panel.services.kyc_mail import send_kyc_event_email
from admin_panel.templated_mail import send_event_email
from django.utils.crypto import get_random_string


PORTAL_ROLES = [User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER, User.Roles.IB]
logger = logging.getLogger(__name__)


def _create_kyc_staff_notification_once(user: User) -> None:
    pass # from django.urls import reverse

    from enterprise.staff_notify import broadcast_staff_notification

    token = f"[kyc_user:{user.id}]"
    broadcast_staff_notification(
        "New KYC submission",
        f"{token} Client {user.display_name()} submitted KYC documents for review.",
        action_url=reverse("admin-docs-pending"),
        dedupe_body_contains=token,
    )


def _match_trader_portal_widget(user: User):
    """Client dashboard Match-Trader card when integration is live."""
    try:
        TradingPlatformIntegration.ensure_defaults()
        row = TradingPlatformIntegration.objects.filter(
            platform=TradingPlatformIntegration.Platform.MATCH_TRADER
        ).first()
        mt = MatchTraderSettings.get_solo()
        if not row or not row.enabled or not mt.is_active:
            return None
        snap, _ = MatchTraderUserSnapshot.objects.get_or_create(user=user)
        return {"mt": mt, "snap": snap}
    except Exception:
        return None


def _trading_portal_blocked_message(user: User) -> Optional[str]:
    """Align portal trading access with UserRestriction and per-account MT5 trading_enabled."""
    r = restriction_for_user(user)
    if r and r.disable_trading:
        return "Trading is disabled for your account. Please contact support."
    active_accounts = MT5Account.objects.filter(user=user, status=MT5Account.Status.ACTIVE)
    if active_accounts.exists() and not active_accounts.filter(trading_enabled=True).exists():
        return "Trading is disabled on all your trading accounts. Please contact support."
    return None


def _demo_server_name() -> str:
    integration = (
        TradingPlatformIntegration.objects.filter(enabled=True)
        .exclude(server_name="")
        .order_by("platform")
        .first()
    )
    if not integration:
        return "Demo-Server"
    display = integration.get_platform_display() or integration.platform
    return f"{display}-Demo"


def _internal_transfer_blocked_message(r, transfer_type: str) -> Optional[str]:
    """If this transfer type is disallowed by admin restrictions, return user-facing message."""
    if not r:
        return None
    tt = InternalTransfer.TransferType
    if transfer_type == tt.WALLET_TO_TRADING and r.disable_wallet_to_mt5:
        return "Wallet to trading account transfers are disabled for your account. Please contact support."
    if transfer_type == tt.TRADING_TO_WALLET and r.disable_mt5_to_wallet:
        return "Trading account to wallet transfers are disabled for your account. Please contact support."
    if transfer_type == tt.TRADING_TO_TRADING and r.disable_transfer:
        return "Transfers between trading accounts are disabled for your account. Please contact support."
    if transfer_type in (tt.IB_TO_TRADING, tt.IB_TO_WALLET) and r.disable_ib_withdraw:
        return "IB wallet transfers are disabled for your account. Please contact support."
    return None


def _gateway_profile(gateway: PaymentGateway) -> str:
    if gateway.gateway_type == PaymentGateway.GatewayType.THIRD_PARTY:
        return "MATCH2PAY"
    if gateway.payment_method == PaymentGateway.PaymentMethod.CRYPTO:
        return "CRYPTO"
    return "MANUAL"


def _match2pay_checkout_url(parsed: dict) -> str:
    if not isinstance(parsed, dict):
        return ""
    direct = (parsed.get("checkout_url") or "").strip()
    if direct.lower().startswith(("http://", "https://")):
        return direct
    raw = parsed.get("raw") or {}
    if not isinstance(raw, dict):
        return ""
    for key in (
        "checkout_url",
        "checkoutUrl",
        "payment_url",
        "paymentUrl",
        "redirect_url",
        "redirectUrl",
        "cashier_url",
        "cashierUrl",
        "url",
    ):
        value = (raw.get(key) or "").strip()
        if value.lower().startswith(("http://", "https://")):
            return value
    return ""


def _crypto_method_label(network: str) -> str:
    labels = {
        "TRC20": "USDT TRC20",
        "ERC20": "USDT ERC20",
        "BEP20": "USDT BEP20",
        "BSC": "USDT BEP20",
        "POLYGON": "USDT Polygon",
    }
    return labels.get((network or "").upper(), (network or "").upper())


def _wallet_balance_for_user(user):
    return Decimal(str(user.wallet_balance or 0))


def _ib_wallet_balance_for_user(user):
    # Basic IB wallet approximation from approved/completed IB transactions.
    ib_credit = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=user,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        ).aggregate(total=Sum("amount"))["total"]
    )
    ib_transfer_out = InternalTransfer.objects.filter(
        user=user,
        status=InternalTransfer.Status.APPROVED,
        from_account="IB_WALLET",
    ).aggregate(total=Sum("amount"))["total"]

    # Deduct pending and completed withdrawals from the available IB balance
    ib_withdraw_out = Transaction.objects.filter(
        actor=user,
        tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
        status__in=[Transaction.Status.PENDING, Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
    ).aggregate(total=Sum("amount"))["total"]

    return (
        Decimal(str(ib_credit or 0)) -
        Decimal(str(ib_transfer_out or 0)) -
        Decimal(str(ib_withdraw_out or 0))
    )


def _team_client_ids(user):
    direct = list(IBRequest.objects.filter(ib_user=user, status=IBRequest.Status.APPROVED).values_list("client_user_id", flat=True))
    # Exclude self to avoid IB own-trade counting.
    return [cid for cid in direct if cid != user.id]


def _sum_mt5_decimal(rows, attr: str) -> Decimal:
    def _get_val(x):
        if attr == "balance" and getattr(x, "mt5_account", None):
            return x.mt5_account.balance
        return getattr(x, attr, None) or 0

    return sum(
        (Decimal(str(_get_val(x))) for x in rows),
        start=Decimal("0"),
    )


def _fmt_money_2(value) -> str:
    try:
        d = Decimal(str(value))
    except Exception:
        d = Decimal("0")
    q = d.quantize(Decimal("0.00"), rounding=ROUND_HALF_UP)
    return format(q, "f")


@login_required
@role_required(PORTAL_ROLES)
def dashboard(request):
    settings_obj = DashboardSettings.get_solo()
    ws_treasury = WalletTreasurySettings.get_solo()
    wallet_only_withdrawal_ui = bool(ws_treasury.wallet_system_enabled and settings_obj.enforce_wallet_only_withdrawal)
    show_transfer_to_wallet_cta = bool(wallet_only_withdrawal_ui and ws_treasury.allow_trading_to_wallet)
    tab = (request.GET.get("tab") or "real").lower()
    if tab not in ("real", "demo"):
        tab = "real"

    request.user.refresh_from_db(fields=["wallet_balance", "pending_withdraw"])
    wallet_balance = _wallet_balance_for_user(request.user)
    ib_balance = _ib_wallet_balance_for_user(request.user)
    reserved_withdraw = Decimal(str(request.user.pending_withdraw or 0))
    wallet_available_after_reservations = max(Decimal("0"), wallet_balance - reserved_withdraw)
    total_deposit = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    pending_withdraw = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW, Transaction.TxType.PENDING_WITHDRAW],
                status=Transaction.Status.PENDING,
            )
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    recent_transactions = list(
        filter_real_ledger_transactions(
            Transaction.objects.filter(actor=request.user).select_related("payment_gateway").order_by("-created_at")
        )[:8]
    )

    from admin_panel.models import TradingAccount
    mt5_qs = (
        TradingAccount.objects.filter(user=request.user)
        .select_related("mt5_account", "mt5_account__group")
        .order_by("-created_at")
    )
    live_qs = [a for a in mt5_qs if a.base_account_type == 'LIVE']
    sum_live_bal_all = sum((Decimal(str(a.mt5_account.balance if a.mt5_account else a.balance or 0)) for a in live_qs), start=Decimal("0"))
    demo_qs = [a for a in mt5_qs if a.base_account_type == 'DEMO']
    sum_demo_bal_all = sum((Decimal(str(a.mt5_account.balance if a.mt5_account else a.balance or 0)) for a in demo_qs), start=Decimal("0"))
    dashboard_tabs_enabled = bool(settings_obj.enable_real_demo_tabs)

    if dashboard_tabs_enabled:
        accounts = list(mt5_qs[:48])
        live_rows = [a for a in accounts if a.base_account_type == 'LIVE']
        demo_rows = [a for a in accounts if a.base_account_type == 'DEMO']
        sum_live_bal = _sum_mt5_decimal(live_rows, "balance")
        sum_demo_bal = _sum_mt5_decimal(demo_rows, "balance")
        total_balance_real = sum_live_bal_all
        total_balance_demo = sum_demo_bal_all
        avail_real = max(Decimal("0"), _sum_mt5_decimal(live_rows, "free_margin"))
        withdraw_metric_real = (
            _fmt_money_2(wallet_available_after_reservations) if wallet_only_withdrawal_ui else _fmt_money_2(avail_real)
        )
        tab_metrics = {
            "real": {
                "total_balance": _fmt_money_2(total_balance_real),
                "available_to_withdraw": withdraw_metric_real,
                "total_credit": _fmt_money_2(_sum_mt5_decimal(live_rows, "credit")),
                "open_pnl": _fmt_money_2(_sum_mt5_decimal(live_rows, "unrealized_pnl")),
                "total_equity": _fmt_money_2(total_balance_real + _sum_mt5_decimal(live_rows, "unrealized_pnl")),
            },
            "demo": {
                "total_balance": _fmt_money_2(total_balance_demo),
                "available_to_withdraw": "0.00",
                "total_credit": _fmt_money_2(_sum_mt5_decimal(demo_rows, "credit")),
                "open_pnl": _fmt_money_2(_sum_mt5_decimal(demo_rows, "unrealized_pnl")),
                "total_equity": _fmt_money_2(total_balance_demo + _sum_mt5_decimal(demo_rows, "unrealized_pnl")),
            },
        }
        sel = tab_metrics["demo" if tab == "demo" else "real"]
        total_balance = sel["total_balance"]
        total_credit = sel["total_credit"]
        available_to_withdraw = sel["available_to_withdraw"]
        open_pnl = sel["open_pnl"]
        total_equity = sel["total_equity"]
        total_margin = sum(
            (Decimal(str((x.equity or 0) - (x.free_margin or 0))) for x in accounts),
            start=Decimal("0"),
        )
        total_free_margin = _sum_mt5_decimal(accounts, "free_margin")
        live_accounts_count = len(live_rows)
        demo_accounts_count = len(demo_rows)
    else:
        accounts = list(mt5_qs[:12])
        total_balance = _fmt_money_2(sum_live_bal_all)
        total_credit = sum((Decimal(str(a.credit or 0)) for a in accounts))
        open_pnl = sum((Decimal(str(a.unrealized_pnl or 0)) for a in accounts))
        total_equity = _fmt_money_2(Decimal(total_balance.replace(',', '')) + open_pnl)
        total_margin = sum(
            (Decimal(str((a.equity or 0) - (a.free_margin or 0))) for a in accounts),
            start=Decimal("0"),
        )
        total_free_margin = _sum_mt5_decimal(accounts, "free_margin")
        available_to_withdraw = (
            _fmt_money_2(wallet_available_after_reservations)
            if wallet_only_withdrawal_ui
            else max(Decimal("0"), total_free_margin)
        )
        tab_metrics = None
        live_accounts_count = sum(1 for a in accounts if a.base_account_type == 'LIVE')
        demo_accounts_count = sum(1 for a in accounts if a.base_account_type == 'DEMO')
    id_verified = KYCIdentity.objects.filter(user=request.user, status=KYCIdentity.Status.APPROVED).exists()
    address_verified = KYCAddress.objects.filter(user=request.user, status=KYCAddress.Status.APPROVED).exists()
    compliance_settings = ComplianceSettings.get_solo()
    address_required = bool(compliance_settings.enable_address_verification)

    if request.user.kyc_status == request.user.KYCStatus.APPROVED:
        id_verified = True
        if address_required:
            address_verified = True
    selfie_rows = Document.objects.filter(
        user=request.user,
        doc_type__in=[Document.DocType.SELFIE],
    )
    selfie_applicable = selfie_rows.exists()
    selfie_verified = selfie_rows.filter(status=Document.Status.APPROVED).exists()

    # Smart alert logic for My Accounts
    kyc_alert = None
    if not id_verified:
        kyc_alert = "KYC Incomplete - Please complete Identity verification"
    elif address_required and not address_verified:
        kyc_alert = "Proof of address required to complete verification"

    all_core_verified = id_verified and ((not address_required) or address_verified)
    kyc = request.user.kyc_status
    if all_core_verified and kyc == User.KYCStatus.APPROVED:
        kyc_badge_class = "bg-emerald-100 text-emerald-800"
        kyc_badge_label = "KYC Approved"
    elif kyc == User.KYCStatus.REJECTED:
        kyc_badge_class = "bg-rose-100 text-rose-800"
        kyc_badge_label = "KYC Rejected"
    else:
        kyc_badge_class = "bg-amber-100 text-amber-900"
        kyc_badge_label = "KYC Pending"
    match_trader_portal = _match_trader_portal_widget(request.user)
    return render(
        request,
        "user_portal/dashboard.html",
        {
            "dashboard_settings": settings_obj,
            "tab": tab,
            "wallet_balance": wallet_balance,
            "accounts": accounts,
            "total_deposit": total_deposit,
            "pending_withdraw": pending_withdraw,
            "recent_transactions": recent_transactions,
            "total_balance": total_balance,
            "total_credit": total_credit,
            "available_to_withdraw": available_to_withdraw,
            "open_pnl": open_pnl,
            "total_equity": total_equity,
            "total_margin": total_margin,
            "total_free_margin": total_free_margin,
            "kyc_alert": kyc_alert,
            "id_verified": id_verified,
            "address_verified": address_verified,
            "selfie_applicable": selfie_applicable,
            "selfie_verified": selfie_verified,
            "kyc_badge_class": kyc_badge_class,
            "kyc_badge_label": kyc_badge_label,
            "dashboard_tabs_enabled": dashboard_tabs_enabled,
            "tab_metrics": tab_metrics,
            "live_accounts_count": live_accounts_count,
            "demo_accounts_count": demo_accounts_count,
            "match_trader_portal": match_trader_portal,
            "wallet_only_withdrawal_ui": wallet_only_withdrawal_ui,
            "show_transfer_to_wallet_cta": show_transfer_to_wallet_cta,
        },
    )


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET"])
def account_live_metrics(request, login_id: str):
    mt5 = MT5Account.objects.filter(user=request.user, login_id=login_id).first()
    if not mt5:
        return JsonResponse({"ok": False, "error": "Account not found"}, status=404)

    if mt5.status == MT5Account.Status.ACTIVE and mt5.group and mt5.group.platform == "MT5":
        try:
            from mt5_integration.services import is_mt5_configured
            from mt5_integration.tasks import mt5_single_account_sync_task
            from django.utils import timezone
            # Trigger background sync if MT5 is configured and hasn't synced in last 10s
            if is_mt5_configured():
                if not mt5.last_sync_at or (timezone.now() - mt5.last_sync_at).total_seconds() > 10:
                    mt5_single_account_sync_task.delay(int(mt5.login_id))
        except Exception as e:
            logger.warning("Live sync trigger failed for login_id %s: %s", login_id, e)

    margin = Decimal(str(mt5.equity or 0)) - Decimal(str(mt5.free_margin or 0))
    return JsonResponse(
        {
            "ok": True,
            "balance": str(mt5.balance or 0),
            "credit": str(mt5.credit or 0),
            "equity": str(mt5.equity or 0),
            "margin": str(margin),
            "free_margin": str(mt5.free_margin or 0),
            "currency": "USD",
        }
    )


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET"])
def dashboard_open_positions_api(request):
    """Fetch open positions across all active trading accounts for the current user."""
    from mt5_integration.services import is_mt5_configured

    # Fast-fail: if MT5 is not configured/reachable, return empty immediately
    # instead of blocking the worker thread for 10+ seconds on a TCP timeout.
    if not is_mt5_configured():
        return JsonResponse({"ok": True, "positions": [], "mt5_unavailable": True})

    accounts = MT5Account.objects.filter(user=request.user, status=MT5Account.Status.ACTIVE)
    positions = []
    try:
        from mt5_integration.services import _mt5_client
        with _mt5_client() as client:
            for acc in accounts:
                try:
                    total = client.position_get_total(int(acc.login_id))
                    if total > 0:
                        raw_pos = client.position_get_page(int(acc.login_id), 0, total)
                        for p in raw_pos:
                            vol = float(p.get("Volume") or 0) / 10000.0  # standard MT5 scaling
                            action = "Buy" if str(p.get("Action") or "0") == "0" else "Sell"
                            positions.append({
                                "login_id": acc.login_id,
                                "symbol": p.get("Symbol") or "-",
                                "type": action,
                                "volume": f"{vol:.2f}",
                                "price_open": f"{float(p.get('PriceOpen') or 0):.5f}",
                                "price_current": f"{float(p.get('PriceCurrent') or 0):.5f}",
                                "profit": float(p.get('Profit') or 0)
                            })
                except Exception as ex:
                    logger.warning("Failed to fetch positions for %s: %s", acc.login_id, ex)
    except Exception as e:
        # MT5 unreachable â€” return empty positions instead of a 500 error
        # so the dashboard page still loads properly.
        logger.warning("dashboard_open_positions_api: MT5 unavailable: %s", e)
        return JsonResponse({"ok": True, "positions": [], "mt5_unavailable": True})

    # Sort positions by profit descending
    positions.sort(key=lambda x: x["profit"], reverse=True)

    # Format profit to string after sorting
    for p in positions:
        p["profit"] = f"{p['profit']:.2f}"

    return JsonResponse({"ok": True, "positions": positions})


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET"])
def account_information_page(request, login_id: str):
    mt5 = MT5Account.objects.select_related("group").filter(user=request.user, login_id=login_id).first()
    if not mt5:
        messages.error(request, "Account not found.")
        return redirect("user-dashboard")
    trading = TradingAccount.objects.filter(user=request.user, mt5_account=mt5).first()
    margin = Decimal(str(mt5.equity or 0)) - Decimal(str(mt5.free_margin or 0))
    return render(
        request,
        "user_portal/account_information.html",
        {"mt5": mt5, "trading": trading, "margin": margin},
    )


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET"])
def account_statement_page(request, login_id: str):
    mt5 = MT5Account.objects.filter(user=request.user, login_id=login_id).first()
    if not mt5:
        messages.error(request, "Account not found.")
        return redirect("user-dashboard")
    period = (request.GET.get("period") or "7d").lower()
    now = timezone.now()
    if period == "today":
        since = timezone.make_aware(datetime.combine(timezone.localdate(), datetime.min.time()))
        until = now
    elif period == "30d":
        since = now - timedelta(days=30)
        until = now
    elif period == "custom":
        from_raw = (request.GET.get("from") or "").strip()
        to_raw = (request.GET.get("to") or "").strip()
        since = timezone.make_aware(datetime.strptime(from_raw, "%Y-%m-%d")) if from_raw else now - timedelta(days=7)
        until = timezone.make_aware(datetime.strptime(to_raw, "%Y-%m-%d")) + timedelta(days=1) if to_raw else now
    else:
        since = now - timedelta(days=7)
        until = now
    if mt5.account_type == MT5Account.AccountType.DEMO:
        rows = []
    else:
        rows = list(
            filter_real_ledger_transactions(
                Transaction.objects.filter(actor=request.user, created_at__gte=since, created_at__lte=until).order_by(
                    "-created_at"
                )
            )[:100]
        )
    return render(request, "user_portal/account_statement.html", {"mt5": mt5, "rows": rows, "period": period})


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET", "POST"])
def account_leverage_page(request, login_id: str):
    mt5 = MT5Account.objects.filter(user=request.user, login_id=login_id).first()
    if not mt5:
        messages.error(request, "Account not found.")
        return redirect("user-dashboard")
    if not mt5.trading_enabled:
        messages.error(request, "Leverage cannot be changed while trading is disabled on this account.")
        return redirect("user-dashboard")
    trading = TradingAccount.objects.filter(user=request.user, mt5_account=mt5).first()
    max_allowed = 1000
    if trading and trading.account_type:
        at = TradingAccountType.objects.filter(account_name__iexact=trading.account_type, is_active=True).first()
        if at:
            max_allowed = int(at.max_leverage or 1000)
    preferred_options = [100, 200, 500, 1000, 1500, 2000]
    leverage_options = [x for x in preferred_options if x <= max_allowed]
    if max_allowed not in leverage_options:
        leverage_options.append(max_allowed)
    if mt5.leverage not in leverage_options:
        leverage_options.append(int(mt5.leverage or 100))
    leverage_options = sorted(set([x for x in leverage_options if x >= 1]))
    if request.method == "POST":
        try:
            new_lev = int(request.POST.get("leverage") or 0)
        except Exception:
            new_lev = 0
        if new_lev not in leverage_options:
            messages.error(request, f"Allowed leverage range is 1 to {max_allowed}.")
        else:
            mt5.leverage = new_lev
            mt5.save(update_fields=["leverage", "updated_at"])
            if trading:
                trading.leverage = new_lev
                trading.save(update_fields=["leverage", "updated_at"])
            messages.success(request, "Leverage updated successfully.")
            return redirect("user-dashboard")
    return render(
        request,
        "user_portal/account_leverage.html",
        {"mt5": mt5, "max_allowed": max_allowed, "leverage_options": leverage_options},
    )


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET", "POST"])
def account_credential_page(request, login_id: str, mode: str):
    mt5 = MT5Account.objects.filter(user=request.user, login_id=login_id).first()
    if not mt5 or mode not in {"trading", "investor"}:
        messages.error(request, "Account not found.")
        return redirect("user-dashboard")
    session_key = f"acct_cred_otp_{request.user.id}_{login_id}_{mode}"
    otp_state = request.session.get(session_key) or {}
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "request_otp":
            new_pass = (request.POST.get("new_password") or "").strip()
            confirm_pass = (request.POST.get("confirm_password") or "").strip()
            if len(new_pass) < 6:
                messages.error(request, "Password must be at least 6 characters.")
                return redirect("user-account-credential", login_id=login_id, mode=mode)
            if new_pass != confirm_pass:
                messages.error(request, "Password confirmation does not match.")
                return redirect("user-account-credential", login_id=login_id, mode=mode)
            otp = get_random_string(6, allowed_chars="0123456789")
            request.session[session_key] = {"otp": otp, "new_password": new_pass, "otp_requested": True}
            if request.user.email:
                send_dynamic_email(request.user.email, "Account Security OTP", f"Your OTP is: {otp}", user=request.user)
            messages.success(request, "OTP sent to your email.")
            return redirect("user-account-credential", login_id=login_id, mode=mode)
        if action == "verify_otp":
            otp = (request.POST.get("otp_code") or "").strip()
            state = request.session.get(session_key) or {}
            if not otp or otp != (state.get("otp") or ""):
                messages.error(request, "Invalid OTP.")
                return redirect("user-account-credential", login_id=login_id, mode=mode)
            new_pass = (state.get("new_password") or "").strip()
            if len(new_pass) < 6:
                messages.error(request, "Password must be at least 6 characters.")
                return redirect("user-account-credential", login_id=login_id, mode=mode)
            if mode == "trading":
                try:
                    from mt5_integration.services import mt5_change_password
                    mt5_change_password(int(mt5.login_id), new_pass, pass_type="MAIN")
                    mt5.set_mt5_password(new_pass)
                    mt5.save(update_fields=["mt5_password_encrypted", "updated_at"])
                except Exception as e:
                    logger.error("Failed to change MT5 password for login %s: %s", mt5.login_id, e)
                    messages.error(request, "Failed to update password on MT5 server.")
                    return redirect("user-account-credential", login_id=login_id, mode=mode)
            else:
                try:
                    from mt5_integration.services import mt5_change_password
                    mt5_change_password(int(mt5.login_id), new_pass, pass_type="INVESTOR")
                    mt5.set_investor_password(new_pass)
                    mt5.save(update_fields=["investor_password_encrypted", "updated_at"])
                except Exception as e:
                    logger.error("Failed to change MT5 investor password for login %s: %s", mt5.login_id, e)
                    messages.error(request, "Failed to update password on MT5 server.")
                    return redirect("user-account-credential", login_id=login_id, mode=mode)
            request.session.pop(session_key, None)
            messages.success(request, "Password changed successfully.")
            return redirect("user-dashboard")
    return render(request, "user_portal/account_credential.html", {"mt5": mt5, "mode": mode, "otp_requested": bool(otp_state.get("otp_requested"))})


class DepositForm(forms.Form):
    gateway = forms.ModelChoiceField(queryset=PaymentGateway.objects.none())
    amount = forms.DecimalField(max_digits=20, decimal_places=2, min_value=Decimal("0.01"))
    currency = forms.CharField(max_length=10, initial="USD")
    reference = forms.CharField(max_length=200, required=False)
    notes = forms.CharField(widget=forms.Textarea(attrs={"rows": 3}), required=False)
    payment_screenshot = forms.FileField(
        required=False,
        widget=forms.FileInput(attrs={
            "class": "block w-full text-sm text-slate-500 cursor-pointer"
        })
    )

    def clean_payment_screenshot(self):
        f = self.cleaned_data.get("payment_screenshot")
        err = validate_document_upload(f, required=False)
        if err:
            raise ValidationError(err)
        return f

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["gateway"].queryset = PaymentGateway.objects.filter(
            PaymentGateway.client_visible_q(),
        ).filter(
            Q(scope=PaymentGateway.Scope.DEPOSIT) | Q(scope=PaymentGateway.Scope.BOTH)
        ).order_by("display_order", "name")


class WithdrawForm(forms.Form):
    gateway = forms.ModelChoiceField(queryset=PaymentGateway.objects.none())
    amount = forms.DecimalField(max_digits=20, decimal_places=2, min_value=Decimal("0.01"))
    currency = forms.CharField(max_length=10, initial="USD")
    reference = forms.CharField(max_length=200, required=False)
    account_details = forms.CharField(widget=forms.Textarea(attrs={"rows": 3}), required=False)
    bank_account = forms.ModelChoiceField(queryset=VerifiedBankAccount.objects.none(), required=False)
    crypto_address = forms.ModelChoiceField(queryset=VerifiedCryptoAddress.objects.none(), required=False)
    
    # Manual fields
    manual_crypto_address = forms.CharField(max_length=255, required=False, label="Wallet Address")
    manual_crypto_network = forms.CharField(max_length=80, required=False, label="Crypto Network (e.g. TRC20, ERC20)")
    
    manual_bank_name = forms.CharField(max_length=120, required=False, label="Bank Name")
    manual_account_name = forms.CharField(max_length=120, required=False, label="Account Name")
    manual_account_number = forms.CharField(max_length=120, required=False, label="Account Number")
    manual_iban = forms.CharField(max_length=120, required=False, label="IBAN")
    manual_swift_code = forms.CharField(max_length=40, required=False, label="SWIFT Code")

    notes = forms.CharField(widget=forms.Textarea(attrs={"rows": 3}), required=False)

    def __init__(self, *args, **kwargs):
        user = kwargs.pop("user", None)
        super().__init__(*args, **kwargs)
        self.fields["gateway"].queryset = PaymentGateway.objects.filter(
            PaymentGateway.client_visible_q(),
        ).filter(
            Q(scope=PaymentGateway.Scope.WITHDRAW) | Q(scope=PaymentGateway.Scope.BOTH)
        ).order_by("display_order", "name")
        if user:
            self.fields["bank_account"].queryset = VerifiedBankAccount.objects.filter(
                user=user, status=VerifiedBankAccount.Status.APPROVED
            ).order_by("-created_at")
            self.fields["crypto_address"].queryset = VerifiedCryptoAddress.objects.filter(
                user=user, status=VerifiedCryptoAddress.Status.APPROVED
            ).order_by("-created_at")

            def _bank_label(obj: VerifiedBankAccount) -> str:
                ref = (obj.iban or obj.account_number or "").strip()
                tail = ref[-4:] if len(ref) >= 4 else ref
                suffix = f" Â·Â·Â·{tail}" if tail else ""
                return f"{obj.bank_name}{suffix} ({obj.account_name})"

            def _crypto_label(obj: VerifiedCryptoAddress) -> str:
                short = (
                    f"{obj.wallet_address[:8]}â€¦{obj.wallet_address[-4:]}"
                    if len(obj.wallet_address) > 16
                    else obj.wallet_address
                )
                label = (obj.wallet_name or "").strip()
                if label:
                    return f"{label} â€” {obj.network} ({short})"
                return f"{obj.network} ({short})"

            self.fields["bank_account"].label_from_instance = _bank_label
            self.fields["crypto_address"].label_from_instance = _crypto_label

        for name, field in self.fields.items():
            if not isinstance(field.widget, forms.FileInput):
                field.widget.attrs.update({"class": "portal-input"})


@login_required
@role_required(PORTAL_ROLES)
def deposit_feature(request):
    r = restriction_for_user(request.user)
    ws = WalletTreasurySettings.get_solo()
    if not ws.wallet_system_enabled:
        messages.error(request, "Wallet is not available.")
        return redirect("user-dashboard")
    if not ws.allow_deposits_to_wallet:
        messages.error(request, "Deposits are disabled. Please contact support.")
        return redirect("user-dashboard")
    if ws.wallet_deposit_maintenance:
        messages.error(request, "Deposits are temporarily under maintenance.")
        return redirect("user-dashboard")
    if r and r.disable_deposit:
        messages.error(request, "Deposits are disabled for your account. Please contact support.")
        return redirect("user-dashboard")
    if kyc_blocks_deposit(request.user, ComplianceSettings.get_solo()):
        messages.error(request, "KYC approval is required before you can deposit.")
        return redirect("user-compliance")
    m2p_settings = Match2PayIntegrationSettings.get_solo()
    gateway_qs = PaymentGateway.objects.filter(
        PaymentGateway.client_visible_q(),
    ).filter(
        Q(scope=PaymentGateway.Scope.DEPOSIT) | Q(scope=PaymentGateway.Scope.BOTH)
    ).order_by("display_order", "name")
    if not m2p_settings.enabled:
        gateway_qs = gateway_qs.exclude(gateway_type=PaymentGateway.GatewayType.THIRD_PARTY)
    selected_gateway_id = request.GET.get("gateway") or request.POST.get("gateway") or ""
    selected_gateway = gateway_qs.filter(id=selected_gateway_id).first() if selected_gateway_id else None

    if (
        selected_gateway
        and selected_gateway.gateway_type == PaymentGateway.GatewayType.THIRD_PARTY
        and not m2p_settings.enabled
    ):
        messages.error(request, "This deposit method is not available.")
        return redirect("user-deposit")

    m2p_action = (request.POST.get("m2p_action") or "").strip() if request.method == "POST" else ""
    if request.method == "POST" and m2p_action == "create_crypto_session":
        gw_id = request.POST.get("gateway") or ""
        gateway = gateway_qs.filter(id=gw_id).first()
        if not gateway or not gateway.client_can_use():
            messages.error(request, "Invalid deposit method.")
            return redirect("user-deposit")
        if _gateway_profile(gateway) != "MATCH2PAY" or not m2p_settings.enabled:
            messages.error(request, "Invalid deposit method.")
            return redirect("user-deposit")
        network = (request.POST.get("crypto_network") or "").strip().upper()
        if network not in ALLOWED_NETWORKS:
            messages.error(request, "Unsupported network.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
        
        acc_str = (request.POST.get("trading_account") or "").strip()
        selected_account = None
        if acc_str != "wallet":
            selected_account = (
                TradingAccount.objects.select_related("mt5_account")
                .filter(
                    account_number=acc_str,
                    user=request.user,
                    status=TradingAccount.Status.ACTIVE,
                    mt5_account__account_type=MT5Account.AccountType.LIVE,
                    mt5_account__deposit_enabled=True,
                )
                .first()
            )
            if not selected_account:
                messages.error(request, "Select a valid live account.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
        try:
            amt = Decimal(str(request.POST.get("amount") or "0"))
        except Exception:
            amt = Decimal("0")
        if amt <= 0:
            messages.error(request, "Enter a valid amount.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&network={network}")
        if ws.wallet_min_deposit > 0 and amt < ws.wallet_min_deposit:
            messages.error(request, f"Minimum deposit amount is {ws.wallet_min_deposit}.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&network={network}")
        if ws.wallet_max_deposit > 0 and amt > ws.wallet_max_deposit:
            messages.error(request, f"Maximum deposit amount is {ws.wallet_max_deposit}.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&network={network}")
        currency = (gateway.currency or "USD").strip().upper()[:10] or "USD"
        ok, result = create_crypto_deposit(
            m2p_settings,
            user=request.user,
            gateway=gateway,
            amount=amt,
            currency=currency,
            network=network,
            trading_account_login=selected_account.account_number if selected_account else "",
        )
        if not ok:
            logger.warning("Match2Pay create_crypto_deposit failed user=%s detail=%s", request.user.id, result)
            try:
                from admin_panel.models import IntegrationConnectionLog

                IntegrationConnectionLog.objects.create(
                    integration_slug="match2pay_create",
                    category="PAYMENTS",
                    success=False,
                    message=json.dumps(
                        {
                            "user_id": request.user.id,
                            "gateway_id": gateway.id,
                            "amount": str(amt),
                            "currency": currency,
                            "network": network,
                            "api_url": (m2p_settings.api_url or "")[:500],
                            "callback_url": (m2p_settings.webhook_url or "")[:500],
                            "detail": str(result)[:1000],
                        },
                        default=str,
                    )[:4000],
                )
            except Exception:
                logger.exception("Match2Pay create failure log failed", extra={"user_id": request.user.id})
            messages.error(request, result if isinstance(result, str) else "Unable to generate payment address, please try again.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&network={network}")
        parsed = result
        try:
            with transaction.atomic():
                Match2PayTransaction.objects.create(
                    user=request.user,
                    payment_gateway=gateway,
                    amount=amt,
                    currency=currency,
                    network=network,
                    payment_id=parsed["payment_id"][:120],
                    address=(parsed.get("address") or "")[:255],
                    qr_code_data=parsed.get("qr_code_data") or "",
                    raw_create_response={
                        **(parsed.get("raw") or {}),
                        "checkout_url": _match2pay_checkout_url(parsed),
                        "trading_account": selected_account.account_number if selected_account else "wallet",
                    },
                )
        except Exception:
            logger.exception("Match2Pay session save failed", extra={"user_id": request.user.id})
            messages.error(request, result if isinstance(result, str) else "Unable to generate payment address, please try again.")
            return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&network={network}")
        messages.success(request, "Send USDT to the generated address. After confirmation, funds credit to your selected account automatically.")
        return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}&pid={parsed['payment_id']}")

    if request.method == "POST":
        form = DepositForm(request.POST, request.FILES)
        if form.is_valid():
            gateway = form.cleaned_data["gateway"]
            if _gateway_profile(gateway) == "MATCH2PAY":
                if not m2p_settings.enabled:
                    messages.error(request, "This deposit method is not available.")
                    return redirect("user-deposit")
                messages.error(request, "Use the cryptocurrency deposit steps for this method.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            if not gateway.client_can_use():
                messages.error(request, "This deposit method is temporarily under maintenance.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            amt = form.cleaned_data["amount"]
            if ws.wallet_min_deposit > 0 and amt < ws.wallet_min_deposit:
                messages.error(request, f"Minimum deposit amount is {ws.wallet_min_deposit}.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            if ws.wallet_max_deposit > 0 and amt > ws.wallet_max_deposit:
                messages.error(request, f"Maximum deposit amount is {ws.wallet_max_deposit}.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            profile = _gateway_profile(gateway)
            need_proof = gateway.require_payment_proof or profile == "MANUAL"
            if need_proof and not form.cleaned_data.get("payment_screenshot"):
                messages.error(request, "Payment proof upload is required for this method.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            auto_wallet_ref = form.cleaned_data.get("reference", "") or ""

            trading_account_selection = (request.POST.get("trading_account") or "").strip()
            if trading_account_selection and trading_account_selection != "wallet":
                base_notes = f"Target Account: {trading_account_selection}\nManual deposit request from client portal."
            else:
                base_notes = "Target Account: Wallet\nManual deposit request from client portal."
            
            client_notes = (form.cleaned_data.get("notes") or "").strip()
            if client_notes:
                base_notes += f"\n\nClient Notes:\n{client_notes}"

            try:
                with transaction.atomic():
                    tx = Transaction.objects.create(
                        tx_type=Transaction.TxType.CLIENT_DEPOSIT,
                        status=Transaction.Status.PENDING,
                        actor=request.user,
                        amount=form.cleaned_data["amount"],
                        currency=form.cleaned_data["currency"],
                        reference=auto_wallet_ref,
                        payment_gateway=gateway,
                        payment_screenshot=form.cleaned_data.get("payment_screenshot"),
                        notes=base_notes,
                    )
            except Exception:
                logger.exception("Deposit request create failed", extra={"user_id": request.user.id})
                messages.error(request, "Unable to submit deposit request. Please try again.")
                return redirect(f"{reverse('user-deposit')}?gateway={gateway.id}")
            if tx.status in (Transaction.Status.COMPLETED, Transaction.Status.APPROVED):
                try:
                    from ib.level_progress import bump_team_deposit_from_transaction, maybe_queue_level_upgrade

                    bump_team_deposit_from_transaction(request.user.id, tx.amount)
                    lk = IBRequest.objects.filter(
                        client_user_id=request.user.id, status=IBRequest.Status.APPROVED
                    ).first()
                    if lk:
                        maybe_queue_level_upgrade(lk.ib_user)
                except Exception:
                    pass
            if tx.status == Transaction.Status.PENDING:
                try:
                    pass # from django.urls import reverse

                    from enterprise.staff_notify import broadcast_staff_notification

                    dep_tok = f"[deposit_tx:{tx.id}]"
                    gw_label = gateway.name if gateway else "â€”"
                    method_label = gateway.get_payment_method_display() if gateway else "â€”"
                    submitted_local = timezone.localtime(timezone.now()).strftime("%Y-%m-%d %H:%M")
                    broadcast_staff_notification(
                        "New deposit request",
                        f"{dep_tok} {request.user.display_name()} Â· {tx.amount} {tx.currency} Â· {method_label} ({gw_label}) Â· {submitted_local} Â· Ref #{tx.id}",
                        action_url=reverse("admin-pending-deposit"),
                        dedupe_body_contains=dep_tok,
                    )
                except Exception:
                    pass
            try:
                log_audit(
                    action="DEPOSIT_SUBMIT",
                    entity_type="Transaction",
                    entity_id=str(tx.id),
                    actor=request.user,
                    channel=AuditLogChannel.CLIENT,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"amount": str(tx.amount), "currency": tx.currency, "profile": profile},
                )
            except Exception:
                logger.exception("Deposit audit log failed", extra={"tx_id": tx.id, "user_id": request.user.id})
            try:
                ok, reason = send_event_email(
                    "deposit_submitted",
                    to_email=request.user.email,
                    user=request.user,
                    extra_context={"amount": f"{form.cleaned_data['amount']} {form.cleaned_data['currency']}"},
                )
                if not ok:
                    logger.info(
                        "deposit_submitted email skipped user_id=%s reason=%s",
                        request.user.id,
                        reason,
                    )
            except Exception:
                logger.exception("Deposit submitted email failed", extra={"tx_id": tx.id, "user_id": request.user.id})
            messages.success(request, "Your deposit request submitted successfully")
            return redirect("user-deposit-report")
    else:
        initial = {}
        if selected_gateway:
            initial["gateway"] = selected_gateway.id
            initial["currency"] = selected_gateway.currency
        form = DepositForm(initial=initial)
    gateways = gateway_qs
    crypto_network = (request.GET.get("network") or "").strip().upper()
    trading_accounts = list(
        TradingAccount.objects.select_related("mt5_account")
        .filter(
            user=request.user,
            status=TradingAccount.Status.ACTIVE,
            mt5_account__account_type=MT5Account.AccountType.LIVE,
            mt5_account__deposit_enabled=True,
        )
        .order_by("-created_at")[:50]
    )
    gw_currency = (selected_gateway.currency or "USDT").upper() if selected_gateway else "USDT"
    if gw_currency == "USDT":
        valid_networks = {"TRC20", "ERC20", "BEP20"}
    else:
        valid_networks = ALLOWED_NETWORKS

    allowed_crypto_methods = [
        {"network": n, "label": _crypto_method_label(n)}
        for n in NETWORK_DISPLAY_ORDER
        if n in valid_networks
    ]
    m2p_payment_id = (request.GET.get("pid") or "").strip()
    m2p_session = None
    if (
        m2p_payment_id
        and selected_gateway
        and _gateway_profile(selected_gateway) == "MATCH2PAY"
    ):
        m2p_session = Match2PayTransaction.objects.filter(
            payment_id=m2p_payment_id,
            user=request.user,
        ).first()
    return render(
        request,
        "user_portal/deposit.html",
        {
            "form": form,
            "title": "Deposit",
            "gateways": gateways,
            "selected_gateway": selected_gateway,
            "selected_profile": _gateway_profile(selected_gateway) if selected_gateway else "",
            "m2p_integration_enabled": m2p_settings.enabled,
            "allowed_crypto_networks": [n for n in NETWORK_DISPLAY_ORDER if n in ALLOWED_NETWORKS],
            "allowed_crypto_methods": allowed_crypto_methods,
            "crypto_network": crypto_network,
            "m2p_session": m2p_session,
            "trading_accounts": trading_accounts,
            "wallet_balance": _wallet_balance_for_user(request.user),
        },
    )


@login_required
@role_required(PORTAL_ROLES)
def withdraw_feature(request):
    r = restriction_for_user(request.user)
    ws = WalletTreasurySettings.get_solo()
    if not ws.wallet_system_enabled:
        messages.error(request, "Wallet is not available.")
        return redirect("user-dashboard")
    if not ws.allow_withdrawals_from_wallet:
        messages.error(request, "Withdrawals are disabled. Please contact support.")
        return redirect("user-dashboard")
    if ws.wallet_withdraw_maintenance:
        messages.error(request, "Withdrawals are temporarily under maintenance.")
        return redirect("user-dashboard")
    if r and r.disable_withdraw:
        messages.error(request, "Withdrawals are disabled for your account. Please contact support.")
        return redirect("user-dashboard")
    if kyc_blocks_withdraw(request.user, ComplianceSettings.get_solo()):
        messages.error(request, "KYC required before withdrawal.")
        return redirect("user-compliance")
    gateway_qs = PaymentGateway.objects.filter(
        PaymentGateway.client_visible_q(),
    ).filter(
        Q(scope=PaymentGateway.Scope.WITHDRAW) | Q(scope=PaymentGateway.Scope.BOTH)
    ).order_by("display_order", "name")
    selected_gateway_id = request.GET.get("gateway") or request.POST.get("gateway") or ""
    selected_gateway = gateway_qs.filter(id=selected_gateway_id).first() if selected_gateway_id else None

    if request.method == "POST":
        form = WithdrawForm(request.POST, user=request.user)
        if form.is_valid():
            compliance_settings = ComplianceSettings.get_solo()
            gateway = form.cleaned_data["gateway"]
            if not gateway.client_can_use():
                messages.error(request, "This withdrawal method is temporarily under maintenance.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            withdraw_from = (request.POST.get("withdraw_from") or "").strip().lower()
            if withdraw_from != "wallet":
                messages.error(
                    request,
                    "Withdrawals are only allowed from Wallet. Please transfer funds to Wallet first.",
                )
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            if (
                compliance_settings.withdrawal_requires_compliance
                or gateway.requires_kyc_for_method
                or ws.require_kyc_wallet_withdraw
            ):
                from accounts.kyc_policy import is_effective_kyc_approved

                if not is_effective_kyc_approved(request.user, compliance_settings):
                    messages.error(request, "Complete KYC identity approval before withdrawal.")
                    return redirect("user-compliance")
            request_uid = (request.POST.get("request_uid") or "").strip()
            if not request_uid:
                messages.error(request, "Invalid request token.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            method = gateway.payment_method
            if method == PaymentGateway.PaymentMethod.BANK:
                selected_bank = form.cleaned_data.get("bank_account")
                has_approved_banks = VerifiedBankAccount.objects.filter(
                    user=request.user, status=VerifiedBankAccount.Status.APPROVED
                ).exists()
                if selected_bank:
                    account_details = (
                        f"Type: BANK\nAccount Name: {selected_bank.account_name}\nBank Name: {selected_bank.bank_name}\n"
                        f"Account Number: {selected_bank.account_number}\nIBAN: {selected_bank.iban}\nVerified Bank ID: {selected_bank.id}"
                    )
                elif has_approved_banks:
                    messages.error(request, "Please select a bank account from your KYC verified accounts.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                elif gateway.whitelist_required:
                    messages.error(request, "Add and verify a bank account before requesting withdrawal.")
                    return redirect("user-compliance")
                else:
                    manual_bank = form.cleaned_data.get("manual_bank_name")
                    manual_acc_name = form.cleaned_data.get("manual_account_name")
                    manual_acc_num = form.cleaned_data.get("manual_account_number")
                    manual_iban = form.cleaned_data.get("manual_iban")
                    manual_swift = form.cleaned_data.get("manual_swift_code")
                    if not manual_bank or not manual_acc_name or (not manual_acc_num and not manual_iban):
                        messages.error(request, "Please fill in all required bank details. Alternatively, select a verified bank account.")
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                    account_details = (
                        f"Type: BANK (Manual)\nAccount Name: {manual_acc_name}\nBank Name: {manual_bank}\n"
                        f"Account Number: {manual_acc_num}\nIBAN: {manual_iban}\nSWIFT Code: {manual_swift}"
                    )
            elif method == PaymentGateway.PaymentMethod.CRYPTO:
                selected_crypto = form.cleaned_data.get("crypto_address")
                has_approved_crypto = VerifiedCryptoAddress.objects.filter(
                    user=request.user, status=VerifiedCryptoAddress.Status.APPROVED
                ).exists()
                if selected_crypto:
                    wn = (selected_crypto.wallet_name or "").strip()
                    account_details = (
                        f"Type: CRYPTO\n"
                        + (f"Wallet Name: {wn}\n" if wn else "")
                        + f"Wallet Address: {selected_crypto.wallet_address}\nNetwork: {selected_crypto.network}\n"
                        f"Verified Crypto ID: {selected_crypto.id}"
                    )
                elif has_approved_crypto:
                    messages.error(request, "Please select a crypto address from your KYC verified accounts.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                elif gateway.whitelist_required:
                    messages.error(request, "Add and verify a crypto wallet before requesting withdrawal.")
                    return redirect("user-compliance")
                else:
                    manual_addr = form.cleaned_data.get("manual_crypto_address")
                    manual_net = form.cleaned_data.get("manual_crypto_network")
                    if not manual_addr or not manual_net:
                        messages.error(request, "Please fill in all required manual crypto details. Alternatively, select a verified crypto address.")
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                    account_details = (
                        f"Type: CRYPTO (Manual)\n"
                        f"Wallet Address: {manual_addr}\n"
                        f"Network: {manual_net}"
                    )
            else:
                messages.error(request, "Unsupported withdrawal method. Use Bank or Crypto only.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")

            amount = form.cleaned_data["amount"]
            
            # Gateway-specific limits validation
            if gateway.min_amount > 0 and amount < gateway.min_amount:
                messages.error(request, f"Minimum withdrawal amount for this method is {gateway.min_amount} {gateway.currency}.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            if gateway.max_amount > 0 and amount > gateway.max_amount:
                messages.error(request, f"Maximum withdrawal amount for this method is {gateway.max_amount} {gateway.currency}.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")

            # Global limits validation
            if ws.wallet_min_withdraw > 0 and amount < ws.wallet_min_withdraw:
                messages.error(request, f"Minimum withdrawal amount is {ws.wallet_min_withdraw}.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            if ws.wallet_max_withdraw > 0 and amount > ws.wallet_max_withdraw:
                messages.error(request, f"Maximum withdrawal amount is {ws.wallet_max_withdraw}.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            if ws.wallet_daily_withdraw_limit > 0:
                today_sum = (
                    filter_real_ledger_transactions(
                        Transaction.objects.filter(
                            actor=request.user,
                            tx_type__in=[
                                Transaction.TxType.CLIENT_WITHDRAW,
                                Transaction.TxType.WALLET_WITHDRAW,
                                Transaction.TxType.PENDING_WITHDRAW,
                            ],
                            created_at__date=timezone.localdate(),
                            status__in=[
                                Transaction.Status.PENDING,
                                Transaction.Status.APPROVED,
                                Transaction.Status.COMPLETED,
                            ],
                        )
                    ).aggregate(s=Sum("amount"))["s"]
                    or 0
                )
                if Decimal(str(today_sum)) + amount > ws.wallet_daily_withdraw_limit:
                    messages.error(request, "Daily withdrawal limit reached.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            if ws.wallet_max_pending_withdrawals > 0:
                pend_n = filter_real_ledger_transactions(
                    Transaction.objects.filter(
                        actor=request.user,
                        tx_type__in=[
                            Transaction.TxType.CLIENT_WITHDRAW,
                            Transaction.TxType.WALLET_WITHDRAW,
                            Transaction.TxType.PENDING_WITHDRAW,
                        ],
                        status=Transaction.Status.PENDING,
                    )
                ).count()
                if pend_n >= ws.wallet_max_pending_withdrawals:
                    messages.error(request, "Maximum pending withdrawals reached. Please wait for processing.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            otp_required = (
                compliance_settings.otp_email_enabled
                or compliance_settings.otp_sms_enabled
                or gateway.requires_2fa_for_method
                or ws.require_2fa_wallet_withdraw
            )
            if otp_required:
                session_key = f"withdraw_otp_{request.user.id}_{gateway.id}"
                submitted_otp = (request.POST.get("otp_code") or "").strip()
                if not submitted_otp:
                    otp = get_random_string(6, allowed_chars="0123456789")
                    request.session[session_key] = otp
                    if compliance_settings.otp_email_enabled and request.user.email:
                        try:
                            send_dynamic_email(
                                request.user.email,
                                "Withdrawal OTP",
                                f"Your withdrawal OTP is: {otp}",
                                user=request.user,
                            )
                        except Exception:
                            logger.exception("Withdrawal OTP email failed", extra={"user_id": request.user.id})
                    messages.info(request, "OTP sent. Enter OTP to submit withdrawal.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}&otp=1")
                expected_otp = request.session.get(session_key, "")
                if not expected_otp or submitted_otp != expected_otp:
                    messages.error(request, "Invalid OTP.")
                    return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}&otp=1")
                request.session.pop(session_key, None)
            try:
                with transaction.atomic():
                    locked_user = User.objects.select_for_update().get(id=request.user.id)
                    if filter_real_ledger_transactions(
                        Transaction.objects.select_for_update().filter(
                            actor=locked_user,
                            request_uid=request_uid,
                        )
                    ).exists():
                        messages.error(request, "Duplicate withdrawal request blocked.")
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                    duplicate_cutoff = timezone.now() - timedelta(seconds=8)
                    if filter_real_ledger_transactions(
                        Transaction.objects.filter(
                            actor=locked_user,
                            tx_type=Transaction.TxType.CLIENT_WITHDRAW,
                            status=Transaction.Status.PENDING,
                            amount=amount,
                            payment_gateway=gateway,
                            created_at__gte=duplicate_cutoff,
                        )
                    ).exists():
                        messages.error(request, "Duplicate withdrawal blocked. Please wait a moment.")
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                    wallet_bal = Decimal(str(locked_user.wallet_balance or 0))
                    pending_before = Decimal(str(locked_user.pending_withdraw or 0))
                    if amount <= 0:
                        messages.error(request, "Withdrawal amount must be greater than zero.")
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
                    available = wallet_bal - pending_before
                    if available < amount:
                        messages.error(
                            request,
                            "Insufficient wallet balance for this withdrawal (pending requests reduce available funds).",
                        )
                        return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")

                    # Reserve in pending_withdraw only; wallet is deducted when admin approves.
                    locked_user.pending_withdraw = pending_before + amount
                    locked_user.save(update_fields=["pending_withdraw"])
                    refreshed = User.objects.select_for_update().get(id=locked_user.id)

                    tx = Transaction.objects.create(
                        tx_type=Transaction.TxType.CLIENT_WITHDRAW,
                        status=Transaction.Status.PENDING,
                        actor=locked_user,
                        amount=amount,
                        currency=form.cleaned_data["currency"],
                        reference=form.cleaned_data.get("reference", "") or "",
                        account_details=account_details,
                        payment_gateway=gateway,
                        notes=form.cleaned_data.get("notes", "") or "Withdraw request from client portal.",
                        request_uid=request_uid,
                        balance_snapshot_wallet=refreshed.wallet_balance,
                        balance_snapshot_pending=refreshed.pending_withdraw,
                    )
                    if refreshed.wallet_balance != wallet_bal:
                        raise ValueError("Wallet balance changed unexpectedly during withdrawal submit")
                    if refreshed.pending_withdraw != pending_before + amount:
                        raise ValueError("Pending withdrawal reservation mismatch")

                    BalanceLedger.objects.create(
                        user=locked_user,
                        entry_type=BalanceLedger.EntryType.WITHDRAW_HOLD,
                        amount=amount,
                        currency=tx.currency,
                        wallet_before=wallet_bal,
                        wallet_after=refreshed.wallet_balance,
                        pending_before=pending_before,
                        pending_after=refreshed.pending_withdraw,
                        reference=str(tx.id),
                        note="Withdrawal requested â€” amount reserved until admin approval (wallet not debited yet)",
                    )
            except Exception:
                logger.exception(
                    "Withdrawal request create failed",
                    extra={"user_id": request.user.id, "gateway_id": getattr(gateway, "id", None)},
                )
                messages.error(request, "Unable to create withdrawal request. Please retry.")
                return redirect(f"{reverse('user-withdraw')}?gateway={gateway.id}")
            try:
                log_audit(
                    action="WITHDRAW_SUBMIT",
                    entity_type="Transaction",
                    entity_id=str(tx.id),
                    actor=request.user,
                    channel=AuditLogChannel.CLIENT,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={
                        "amount": str(amount),
                        "currency": str(tx.currency),
                        "gateway": gateway.name,
                        "balance_snapshot_wallet": str(tx.balance_snapshot_wallet or ""),
                        "balance_snapshot_pending": str(tx.balance_snapshot_pending or ""),
                    },
                )
            except Exception:
                logger.exception("Withdrawal audit log failed", extra={"tx_id": tx.id, "user_id": request.user.id})
            try:
                from enterprise.staff_notify import broadcast_staff_notification

                wdr_tok = f"[withdraw_tx:{tx.id}]"
                submitted_local = timezone.localtime(timezone.now()).strftime("%Y-%m-%d %H:%M")
                client_label = request.user.display_name()
                method_label = gateway.get_payment_method_display() if gateway else "â€”"
                gw_name = (gateway.name or "").strip() or "â€”"
                broadcast_staff_notification(
                    "New Withdrawal Request",
                    f"{wdr_tok} {client_label} Â· {amount} {tx.currency} Â· {method_label} ({gw_name}) Â· {submitted_local} Â· Ref #{tx.id}",
                    action_url=reverse("admin-pending-withdraw"),
                    dedupe_body_contains=wdr_tok,
                )
            except Exception:
                logger.exception("Withdrawal staff notification failed", extra={"tx_id": tx.id, "user_id": request.user.id})
            sec_ent = EnterpriseSecuritySettings.get_solo()
            if sec_ent.withdrawal_submitted_alert:
                try:
                    send_withdrawal_security_email_task.delay(
                        request.user.id, str(amount), str(tx.currency)
                    )
                except Exception:
                    logger.exception(
                        "Withdrawal security alert task failed",
                        extra={"tx_id": tx.id, "user_id": request.user.id},
                    )
            adjust_risk_score(request.user, 1, "Withdrawal request submitted")
            try:
                ok, reason = send_event_email(
                    "withdrawal_submitted",
                    to_email=request.user.email,
                    user=request.user,
                    extra_context={
                        "amount": f"{amount} {form.cleaned_data['currency']}",
                        "status": "Pending",
                    },
                )
                if not ok:
                    logger.info(
                        "withdrawal_submitted email skipped user_id=%s reason=%s",
                        request.user.id,
                        reason,
                    )
            except Exception:
                logger.exception("Withdrawal submitted email failed", extra={"tx_id": tx.id, "user_id": request.user.id})
            messages.success(request, "Your withdrawal request has been successfully submitted")
            return redirect("user-withdraw-report")
    else:
        initial = {}
        if selected_gateway:
            initial["gateway"] = selected_gateway.id
            initial["currency"] = selected_gateway.currency
        form = WithdrawForm(initial=initial, user=request.user)
    gateways = gateway_qs
    comp_ctx = ComplianceSettings.get_solo()
    ws_ctx = WalletTreasurySettings.get_solo()
    otp_required_ctx = (
        comp_ctx.otp_email_enabled
        or comp_ctx.otp_sms_enabled
        or (selected_gateway.requires_2fa_for_method if selected_gateway else False)
        or ws_ctx.require_2fa_wallet_withdraw
    )
    return render(
        request,
        "user_portal/withdraw.html",
        {
            "form": form,
            "title": "Withdrawal",
            "gateways": gateways,
            "selected_gateway": selected_gateway,
            "selected_profile": _gateway_profile(selected_gateway) if selected_gateway else "",
            "selected_method": selected_gateway.payment_method if selected_gateway else "",
            "request_uid": uuid.uuid4().hex,
            "approved_bank_accounts": VerifiedBankAccount.objects.filter(
                user=request.user, status=VerifiedBankAccount.Status.APPROVED
            ).order_by("-created_at"),
            "approved_crypto_addresses": VerifiedCryptoAddress.objects.filter(
                user=request.user, status=VerifiedCryptoAddress.Status.APPROVED
            ).order_by("-created_at"),
            "otp_required": otp_required_ctx,
            "otp_mode": request.GET.get("otp") == "1",
        },
    )


@login_required
@role_required(PORTAL_ROLES)
def internal_transfer_feature(request):
    r = restriction_for_user(request.user)
    ws = WalletTreasurySettings.get_solo()
    ts = TransferTreasurySettings.get_solo()
    if not ws.wallet_system_enabled:
        messages.error(request, "Wallet is not available.")
        return redirect("user-dashboard")
    if not ts.internal_transfers_enabled:
        messages.error(request, "Internal transfers are disabled.")
        return redirect("user-dashboard")
    if ts.internal_maintenance_mode:
        messages.error(request, "Internal transfer temporarily unavailable.")
        return redirect("user-dashboard")
    if r and r.disable_internal_transfer:
        messages.error(request, "Internal transfers are disabled for your account. Please contact support.")
        return redirect("user-dashboard")

    tt = InternalTransfer.TransferType
    transfer_types = []
    if ws.allow_wallet_to_trading:
        transfer_types.append(tt.WALLET_TO_TRADING)
    if ws.allow_trading_to_wallet:
        transfer_types.append(tt.TRADING_TO_WALLET)
    transfer_types.append(tt.TRADING_TO_TRADING)
    if ws.allow_p2p_transfers:
        transfer_types.append(tt.IB_TO_TRADING)
        transfer_types.append(tt.IB_TO_WALLET)

    trading_accounts = (
        TradingAccount.objects.filter(
            user=request.user,
            status=TradingAccount.Status.ACTIVE,
            mt5_account__account_type=MT5Account.AccountType.LIVE,
        )
        .order_by("-created_at")
    )

    if request.method == "POST":
        transfer_type = request.POST.get("transfer_type") or ""
        from_account = request.POST.get("from_account") or ""
        to_account = request.POST.get("to_account") or ""
        amount_raw = request.POST.get("amount") or "0"
        request_uid = (request.POST.get("request_uid") or "").strip()
        try:
            amount = Decimal(amount_raw)
        except Exception:
            amount = Decimal("0")

        if transfer_type not in transfer_types:
            messages.error(request, "Invalid transfer type.")
            return redirect("user-internal-transfer")

        def _trading_row_kind(tid: int):
            row = (
                TradingAccount.objects.select_related("mt5_account")
                .filter(id=tid, user=request.user, status=TradingAccount.Status.ACTIVE)
                .first()
            )
            if not row or not row.mt5_account:
                return None
            return row.mt5_account.account_type

        for acct_str in (from_account, to_account):
            if not str(acct_str).startswith("TRADING:"):
                continue
            try:
                tid = int(str(acct_str).split(":", 1)[1])
            except Exception:
                tid = 0
            k = _trading_row_kind(tid)
            if k == MT5Account.AccountType.DEMO:
                messages.error(request, "Demo accounts cannot send or receive internal transfers.")
                return redirect("user-internal-transfer")

        blocked_msg = _internal_transfer_blocked_message(r, transfer_type)
        if blocked_msg:
            messages.error(request, blocked_msg)
            return redirect("user-internal-transfer")
        if amount <= 0:
            messages.error(request, "Amount must be greater than zero.")
            return redirect("user-internal-transfer")
        if not request_uid:
            messages.error(request, "Invalid transfer token.")
            return redirect("user-internal-transfer")

        route_err = validate_internal_transfer_route(transfer_type, from_account, to_account)
        if route_err:
            messages.error(request, route_err)
            return redirect("user-internal-transfer")

        compliance_settings = ComplianceSettings.get_solo()
        if kyc_blocks_internal_transfer(request.user, compliance_settings):
            messages.error(request, "KYC approval is required before internal transfers.")
            return redirect("user-compliance")

        if ts.internal_min_amount > 0 and amount < ts.internal_min_amount:
            messages.error(request, f"Minimum transfer amount is {ts.internal_min_amount}.")
            return redirect("user-internal-transfer")
        if ts.internal_max_amount > 0 and amount > ts.internal_max_amount:
            messages.error(request, f"Maximum transfer amount is {ts.internal_max_amount}.")
            return redirect("user-internal-transfer")

        # Withdrawal-protection style rule for trading-origin transfers:
        # transferable amount cannot exceed account equity/free margin.
        if transfer_type in {tt.TRADING_TO_WALLET, tt.TRADING_TO_TRADING} and str(from_account).startswith("TRADING:"):
            try:
                acc_id = int(str(from_account).split(":", 1)[1])
            except Exception:
                acc_id = 0
            src = (
                TradingAccount.objects.select_related("mt5_account")
                .filter(
                    id=acc_id,
                    user=request.user,
                    status=TradingAccount.Status.ACTIVE,
                    mt5_account__account_type=MT5Account.AccountType.LIVE,
                )
                .first()
            )
            if not src or not src.mt5_account:
                messages.error(request, "Source trading account not found.")
                return redirect("user-internal-transfer")
            from btrader_integration.services import validate_trading_debit_amount

            debit_err = validate_trading_debit_amount(src, amount)
            if debit_err:
                messages.error(request, debit_err)
                return redirect("user-internal-transfer")
            src.mt5_account.refresh_from_db()

        if ts.internal_daily_limit > 0:
            today_sum = (
                InternalTransfer.objects.filter(
                    user=request.user,
                    created_at__date=timezone.localdate(),
                    status=InternalTransfer.Status.APPROVED,
                ).aggregate(s=Sum("amount"))["s"]
                or 0
            )
            if Decimal(str(today_sum)) + amount > ts.internal_daily_limit:
                messages.error(request, "Daily internal transfer limit reached.")
                return redirect("user-internal-transfer")

        if ts.internal_cooldown_minutes > 0:
            last_it = InternalTransfer.objects.filter(user=request.user).order_by("-created_at").first()
            if last_it and last_it.created_at + timedelta(minutes=ts.internal_cooldown_minutes) > timezone.now():
                messages.error(request, "Please wait before submitting another transfer.")
                return redirect("user-internal-transfer")

        if ts.transfer_max_pending > 0:
            pend_n = InternalTransfer.objects.filter(user=request.user, status=InternalTransfer.Status.PENDING).count()
            if pend_n >= ts.transfer_max_pending:
                messages.error(request, "Maximum pending transfers reached.")
                return redirect("user-internal-transfer")

        from transactions.utils import ensure_unique_action
        try:
            ensure_unique_action(f"TRANSFER_{request_uid}", "INTERNAL_TRANSFER")
        except ValueError as e:
            messages.error(request, str(e))
            return redirect("user-internal-transfer")

        if ts.internal_processing_mode == TransferTreasurySettings.ProcessingMode.MANUAL:
            try:
                with db_transaction.atomic():
                    locked_user = User.objects.select_for_update().get(id=request.user.id)
                    if InternalTransfer.objects.select_for_update().filter(
                        user=locked_user,
                        note__icontains=request_uid,
                    ).exists():
                        messages.error(request, "Duplicate transfer blocked.")
                        return redirect("user-internal-transfer")
                    it = InternalTransfer.objects.create(
                        user=locked_user,
                        transfer_type=transfer_type,
                        from_account=from_account,
                        to_account=to_account,
                        amount=amount,
                        status=InternalTransfer.Status.PENDING,
                        note=f"request_uid={request_uid}",
                    )
            except Exception:
                messages.error(request, "Transfer request failed. Please try again.")
                return redirect("user-internal-transfer")
            log_audit(
                action="INTERNAL_TRANSFER_PENDING",
                entity_type="InternalTransfer",
                entity_id=str(it.id),
                actor=request.user,
                channel=AuditLogChannel.CLIENT,
                request=request,
                ip=get_client_ip(request),
                metadata={"amount": str(amount), "type": transfer_type},
            )
            messages.success(request, "Transfer submitted for admin approval.")
            return redirect("user-internal-transfer")

        try:
            with db_transaction.atomic():
                locked_user = User.objects.select_for_update().get(id=request.user.id)
                if InternalTransfer.objects.select_for_update().filter(
                    user=locked_user,
                    note__icontains=request_uid,
                ).exists():
                    messages.error(request, "Duplicate transfer blocked.")
                    return redirect("user-internal-transfer")

                duplicate_cutoff = timezone.now() - timedelta(seconds=8)
                duplicate_exists = InternalTransfer.objects.filter(
                    user=locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    status=InternalTransfer.Status.APPROVED,
                    created_at__gte=duplicate_cutoff,
                ).exists()
                if duplicate_exists:
                    messages.error(request, "Duplicate transfer detected. Please wait a moment.")
                    return redirect("user-internal-transfer")

                err = apply_internal_transfer_balances(
                    locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    request_uid=request_uid,
                )
                if err:
                    messages.error(request, err)
                    return redirect("user-internal-transfer")

                row = InternalTransfer.objects.create(
                    user=locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    status=InternalTransfer.Status.APPROVED,
                    processed_at=timezone.now(),
                    processed_by=locked_user,
                    note=f"request_uid={request_uid}",
                )
                if row.amount <= 0:
                    raise ValueError("Transfer verification failed")
        except Exception:
            messages.error(request, "Transfer failed. Please try again.")
            return redirect("user-internal-transfer")

        log_audit(
            action="INTERNAL_TRANSFER_COMPLETED",
            entity_type="InternalTransfer",
            entity_id=str(row.id),
            actor=request.user,
            channel=AuditLogChannel.CLIENT,
            request=request,
            ip=get_client_ip(request),
            metadata={"amount": str(amount), "type": transfer_type},
        )
        messages.success(request, "Transfer completed successfully.")
        return redirect("user-internal-transfer")

    history_qs = filter_real_internal_transfers(
        InternalTransfer.objects.filter(user=request.user).order_by("-created_at"),
        request.user,
    )
    history = list(history_qs[:100])
    preselect_from = (request.GET.get("from_account") or "").strip()
    return render(
        request,
        "user_portal/internal_transfer.html",
        {
            "title": "Internal Transfer",
            "transfer_types": transfer_types,
            "trading_accounts": trading_accounts,
            "wallet_balance": _wallet_balance_for_user(request.user),
            "ib_wallet_balance": _ib_wallet_balance_for_user(request.user),
            "history": history,
            "request_uid": uuid.uuid4().hex,
            "transfer_settings": ts,
            "wallet_settings": ws,
            "preselect_from": preselect_from,
        },
    )


class UnifiedTx:
    def __init__(self, obj):
        self.is_transfer = hasattr(obj, "transfer_type")
        self.obj = obj
        self.amount = obj.amount
        self.currency = getattr(obj, "currency", "USD")
        self.status = obj.status
        self.created_at = obj.created_at

    @property
    def reference(self):
        return f"TRF-{self.obj.id}" if self.is_transfer else self.obj.reference

    @property
    def payment_gateway(self):
        if self.is_transfer:
            class DummyPG:
                name = "Internal"
            return DummyPG()
        return self.obj.payment_gateway

    @property
    def notes(self):
        if self.is_transfer:
            tt_display = self.obj.get_transfer_type_display() if hasattr(self.obj, "get_transfer_type_display") else "Internal Transfer"
            n = getattr(self.obj, "note", "")
            return f"{tt_display}: {n}" if n else tt_display
        return self.obj.notes

    @property
    def account_details(self):
        return "" if self.is_transfer else getattr(self.obj, "account_details", "")


@login_required
@role_required(PORTAL_ROLES)
def wallet_page(request):
    tx_qs = filter_real_ledger_transactions(
        Transaction.objects.filter(
            actor=request.user,
            tx_type__in=[
                Transaction.TxType.CLIENT_DEPOSIT,
                Transaction.TxType.CLIENT_WITHDRAW,
                Transaction.TxType.WALLET_DEPOSIT,
                Transaction.TxType.WALLET_WITHDRAW,
                Transaction.TxType.PENDING_DEPOSIT,
                Transaction.TxType.PENDING_WITHDRAW,
            ]
        ).select_related("payment_gateway")
    )
    
    it_qs = filter_real_internal_transfers(
        InternalTransfer.objects.filter(user=request.user),
        request.user
    )

    q = (request.GET.get("q") or "").strip()
    status = (request.GET.get("status") or "").strip().upper()
    method = (request.GET.get("method") or "").strip()
    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()

    if q:
        tx_qs = tx_qs.filter(Q(reference__icontains=q) | Q(notes__icontains=q) | Q(payment_gateway__name__icontains=q))
        it_qs = it_qs.filter(Q(from_account__icontains=q) | Q(to_account__icontains=q) | Q(note__icontains=q))
    if status in {"PENDING", "APPROVED", "COMPLETED", "REJECTED"}:
        tx_qs = tx_qs.filter(status=status)
        it_qs = it_qs.filter(status=status)
    if method:
        tx_qs = tx_qs.filter(payment_gateway__name__icontains=method)
        if "internal" not in method.lower():
            it_qs = it_qs.none()
    if from_date:
        tx_qs = tx_qs.filter(created_at__date__gte=from_date)
        it_qs = it_qs.filter(created_at__date__gte=from_date)
    if to_date:
        tx_qs = tx_qs.filter(created_at__date__lte=to_date)
        it_qs = it_qs.filter(created_at__date__lte=to_date)

    combined = [UnifiedTx(t) for t in tx_qs] + [UnifiedTx(t) for t in it_qs]
    combined.sort(key=lambda x: x.created_at, reverse=True)
    if (request.GET.get("export") or "").lower() == "excel":
        log_audit(
            action="WALLET_EXPORT",
            entity_type="Wallet",
            entity_id=str(request.user.id),
            actor=request.user,
            channel=AuditLogChannel.CLIENT,
            request=request,
            ip=get_client_ip(request),
        )
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="wallet_history.csv"'
        w = csv.writer(response)
        w.writerow(["MT5 ID/Ref", "Amount", "Payment Method", "Note", "Comment", "Status", "Date"])
        for t in combined[:5000]:
            pg_name = t.payment_gateway.name if t.payment_gateway else "-"
            w.writerow([t.reference or "-", t.amount, pg_name, t.notes or "-", t.account_details or "-", t.status, timezone.localtime(t.created_at).strftime("%Y-%m-%d %H:%M")])
        return response
    paginator = Paginator(combined, 20)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "user_portal/wallet.html",
        {
            "wallet_balance": _wallet_balance_for_user(request.user),
            "page_obj": page_obj,
            "filters": {"q": q, "status": status, "method": method, "from": from_date, "to": to_date},
        },
    )


def _ib_chart_month_dates():
    today = timezone.localdate()
    y, m = today.year, today.month
    months = []
    for _ in range(6):
        months.append(date(y, m, 1))
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    months.reverse()
    return months



def _month_bucket_count_new_clients(team_ids: list, y: int, m: int) -> int:
    if not team_ids:
        return 0
    last = monthrange(y, m)[1]
    start = timezone.make_aware(datetime(y, m, 1, 0, 0, 0))
    end = timezone.make_aware(datetime(y, m, last, 23, 59, 59))
    return User.objects.filter(id__in=team_ids, date_joined__gte=start, date_joined__lte=end).count()


@login_required
@require_http_methods(["GET", "POST"])
def ib_dashboard_page(request):
    now = timezone.localtime(timezone.now())
    month_start = now.date().replace(day=1)
    team_ids = _team_client_ids(request.user)
    team_tx = filter_real_ledger_transactions(
        Transaction.objects.filter(actor_id__in=team_ids, status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED])
    )
    monthly_commission = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                created_at__date__gte=month_start,
            )
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    total_commission = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    ib_profile = IBProfile.objects.filter(user=request.user).first()
    if ib_profile and request.user.role == User.Roles.IB and not (ib_profile.ib_code or "").strip():
        ensure_profile_referral_url(request, ib_profile)
        ib_profile.save(update_fields=["ib_code", "referral_link"])

    referral_link = ""
    if ib_profile and (ib_profile.ib_code or "").strip():
        referral_link = build_register_referral_url(request, ib_profile.ib_code)

    pending_ib = IBRequest.objects.filter(client_user=request.user, status=IBRequest.Status.PENDING).first()

    live_qs = MT5Account.objects.filter(user_id__in=team_ids, account_type=MT5Account.AccountType.LIVE)
    live_total = live_qs.count()
    live_active = live_qs.filter(status=MT5Account.Status.ACTIVE).count()

    team_dep = team_tx.filter(
        tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    ).aggregate(total=Sum("amount"))["total"] or Decimal("0")
    team_wdr = team_tx.filter(
        tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
    ).aggregate(total=Sum("amount"))["total"] or Decimal("0")
    team_net = team_dep - team_wdr

    month_labels = []
    chart_clients = []
    for md in _ib_chart_month_dates():
        month_labels.append(md.strftime("%b %Y"))
        chart_clients.append(_month_bucket_count_new_clients(team_ids, md.year, md.month))

    ib_progress = None
    try:
        from ib.level_progress import build_ib_portal_progress, refresh_referral_count
        refresh_referral_count(request.user)
        ib_progress = build_ib_portal_progress(request.user)
    except Exception:
        ib_progress = None

    # Compute wallet statistics
    ib_wallet_available = _ib_wallet_balance_for_user(request.user)
    ib_wallet_earned = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        ).aggregate(total=Sum("amount"))["total"]
        or Decimal("0")
    )
    ib_wallet_withdrawn = (
        Transaction.objects.filter(
            actor=request.user,
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        ).aggregate(total=Sum("amount"))["total"]
        or Decimal("0")
    )
    ib_wallet_pending = (
        Transaction.objects.filter(
            actor=request.user,
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
            status=Transaction.Status.PENDING,
        ).aggregate(total=Sum("amount"))["total"]
        or Decimal("0")
    )

    # Compute referral statistics
    referral_clicks = ib_profile.link_clicks if ib_profile else 0
    referral_registrations = len(team_ids)
    
    # KYC Approved Referrals
    referral_kyc_approved = User.objects.filter(id__in=team_ids, kyc_status="APPROVED").count()

    # Depositors
    referral_depositors = Transaction.objects.filter(
        actor_id__in=team_ids,
        tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
    ).values_list("actor_id", flat=True).distinct().count()

    # Active Traders (with trades registered in ProcessedMT5Deal)
    from ib.models import ProcessedMT5Deal
    referral_active_traders = ProcessedMT5Deal.objects.filter(
        login_id__in=MT5Account.objects.filter(user_id__in=team_ids).values_list("login_id", flat=True)
    ).values_list("login_id", flat=True).distinct().count()

    context = {
        "month_name": now.strftime("%B %Y"),
        "monthly_commission": monthly_commission,
        "total_commission": total_commission,
        "total_clients": len(team_ids),
        "ib_profile": ib_profile,
        "ib_progress": ib_progress,
        "pending_ib": pending_ib,
        "live_total": live_total,
        "live_active": live_active,
        "team_dep": team_dep,
        "team_wdr": team_wdr,
        "team_net": team_net,
        "chart_labels": month_labels,
        "chart_clients": chart_clients,
        "chart_labels_json": json.dumps(month_labels),
        "chart_clients_json": json.dumps(chart_clients),
        "referral_link": referral_link,
        
        # Real wallet and referral metrics
        "ib_wallet_available": ib_wallet_available,
        "ib_wallet_earned": ib_wallet_earned,
        "ib_wallet_withdrawn": ib_wallet_withdrawn,
        "ib_wallet_pending": ib_wallet_pending,
        "referral_clicks": referral_clicks,
        "referral_registrations": referral_registrations,
        "referral_kyc_approved": referral_kyc_approved,
        "referral_depositors": referral_depositors,
        "referral_active_traders": referral_active_traders,
    }
    return render(request, "user_portal/ib_dashboard.html", context)


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET"])
def ib_progress_api(request):
    from ib.level_progress import build_ib_portal_progress, refresh_referral_count
    
    refresh_referral_count(request.user)
    data = build_ib_portal_progress(request.user)
    if not data:
        return JsonResponse({"ok": False})

    def _d(x, is_int=False):
        if x is None:
            return "0"
        v = Decimal(str(x))
        if is_int:
            return str(v.to_integral_value())
        return f"{v:.2f}"

    is_ref = data["primary_label"] == "Referrals"
    return JsonResponse(
        {
            "ok": True,
            "progress_percent": data["progress_percent"],
            "primary_label": data["primary_label"],
            "current_value": _d(data["current_value"], is_ref),
            "required_value": _d(data["required_value"], is_ref),
            "remaining_value": _d(data["remaining_value"], is_ref),
            "lots_cur": _d(data.get("lots_cur")), "lots_req": _d(data.get("lots_req")), "lots_pct": data.get("lots_pct", 100),
            "dep_cur": _d(data.get("dep_cur")), "dep_req": _d(data.get("dep_req")), "dep_pct": data.get("dep_pct", 100),
            "refs_cur": _d(data.get("refs_cur"), is_int=True), "refs_req": _d(data.get("refs_req"), is_int=True), "refs_pct": data.get("refs_pct", 100),
            "commission_rate": data["commission_rate"],
            "next_reward_title": data["next_reward_title"],
            "next_reward_remaining_label": data["next_reward_remaining_label"],
            "current_level": data["current_level"].name if data["current_level"] else "",
            "next_level": data["next_level"].name if data["next_level"] else "",
            "at_top_tier": data["next_level"] is None,
        }
    )


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET", "POST"])
def ib_apply_request(request):
    """
    Dynamic IB application. Answers are stored on IBRequest.application_data.
    """
    if kyc_blocks_ib_request(request.user, ComplianceSettings.get_solo()):
        messages.error(request, "KYC approval is required before you can apply for the IB programme.")
        return redirect("user-compliance")
    if IBProfile.objects.filter(user=request.user).exists():
        messages.info(request, "You are already registered as an IB.")
        return redirect("user-ib-dashboard")

    pending = IBRequest.objects.filter(client_user=request.user, status=IBRequest.Status.PENDING).first()
    if pending:
        messages.warning(request, "You already have a pending IB application.")
        return redirect("user-ib-dashboard")

    from ib.models import IBApplicationQuestion
    questions = IBApplicationQuestion.objects.filter(is_active=True).order_by("sort_order")

    if request.method == "GET":
        return render(request, "user_portal/ib_apply_form.html", {"questions": questions})

    application_data = {}
    missing_required = False

    for q in questions:
        field_name = f"question_{q.id}"
        if q.input_type == IBApplicationQuestion.InputType.MULTI:
            ans = request.POST.getlist(field_name)
            answer_val = ", ".join(ans) if ans else ""
            q.posted_val = ans # pass list for multi
        else:
            answer_val = request.POST.get(field_name, "").strip()
            q.posted_val = answer_val
        
        application_data[q.label] = answer_val

        if q.required and not answer_val:
            missing_required = True

    if missing_required:
        messages.error(request, "Please complete all required fields.")
        return render(request, "user_portal/ib_apply_form.html", {"questions": questions})

    plan = IBPlan.objects.filter(is_active=True).order_by("id").first()
    full_name = (request.user.display_name() or "").strip()
    email = (getattr(request.user, "email", None) or "").strip()
    country = (getattr(request.user, "country", None) or "").strip()

    with db_transaction.atomic():
        req = IBRequest.objects.create(
            ib_user=request.user,
            client_user=request.user,
            plan=plan,
            status=IBRequest.Status.PENDING,
            full_name=full_name,
            email=email,
            trading_account="",
            country=country,
            notes="IB application (dynamic form)",
            application_data=application_data,
        )
        try:
            pass # from django.urls import reverse

            from enterprise.staff_notify import broadcast_staff_notification

            ib_tok = f"[ib_request:{req.id}]"
            broadcast_staff_notification(
                "New IB request",
                f"{ib_tok} {full_name} ({email}) submitted an IB application.",
                action_url=reverse("admin-ib-requests"),
                dedupe_body_contains=ib_tok,
            )
        except Exception:
            pass

    messages.success(request, "IB application submitted successfully.")
    return redirect("user-ib-dashboard")


@login_required
@role_required(PORTAL_ROLES)
def ib_my_clients(request):
    ib_profile = IBProfile.objects.filter(user=request.user).first()
    team_ids = _team_client_ids(request.user)
    clients = User.objects.filter(id__in=team_ids).order_by("id")
    rows = []
    
    import re
    LOT_RE = re.compile(r"lots=([\d.]+)", re.I)

    for c in clients:
        dep = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=c,
                    tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )
        wdr = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=c,
                    tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )
        payouts = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                from_user=c,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        )
        client_comm = payouts.aggregate(total=Sum("amount"))["total"] or Decimal("0")
        client_lots = Decimal("0")
        for tx in payouts:
            m = LOT_RE.search(tx.notes or "")
            if m:
                try:
                    client_lots += Decimal(m.group(1))
                except Exception:
                    pass

        rows.append(
            {
                "client": c,
                "mt5": MT5Account.objects.filter(user=c).order_by("-updated_at").first(),
                "lot": client_lots,
                "commission": client_comm,
                "deposit": dep,
                "withdraw": wdr,
            }
        )
    cards = {
        "commission": sum(r["commission"] for r in rows),
        "deposit": sum(r["deposit"] for r in rows),
        "withdraw": sum(r["withdraw"] for r in rows),
        "lot": sum(r["lot"] for r in rows),
    }
    return render(request, "user_portal/ib_my_clients.html", {"rows": rows, "cards": cards})


@login_required
@role_required(PORTAL_ROLES)
def ib_tree_chart(request):
    level1_ids = _team_client_ids(request.user)
    level1 = User.objects.filter(id__in=level1_ids)
    level2 = User.objects.filter(referred_by_id__in=level1_ids)[:50]
    level3 = User.objects.filter(referred_by_id__in=list(level2.values_list("id", flat=True)))[:50]
    return render(request, "user_portal/ib_tree.html", {"level1": level1, "level2": level2, "level3": level3})


def _filtered_amount_report(request, tx_types, template, title):
    from_date = request.GET.get("from") or ""
    to_date = request.GET.get("to") or ""
    q = (request.GET.get("q") or "").strip()
    status = (request.GET.get("status") or "").strip().upper()
    method = (request.GET.get("method") or "").strip()
    qs = filter_real_ledger_transactions(
        Transaction.objects.filter(actor=request.user, tx_type__in=tx_types).select_related("payment_gateway").order_by(
            "-created_at"
        )
    )
    if from_date:
        qs = qs.filter(created_at__date__gte=from_date)
    if to_date:
        qs = qs.filter(created_at__date__lte=to_date)
    if q:
        qs = qs.filter(Q(reference__icontains=q) | Q(notes__icontains=q) | Q(account_details__icontains=q))
    if status in {"PENDING", "APPROVED", "COMPLETED", "REJECTED"}:
        qs = qs.filter(status=status)
    if method:
        qs = qs.filter(payment_gateway__name__icontains=method)
    if (request.GET.get("export") or "").lower() == "excel":
        role_chk = request.user.role if hasattr(request.user, "role") else ""
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = f'attachment; filename="{title.lower().replace(" ", "_")}.csv"'
        w = csv.writer(response)
        w.writerow(["MT5 ID/Ref", "Amount", "Payment Method", "Note", "Comment", "Status", "Date"])
        for t in qs[:5000]:
            w.writerow([t.reference or "-", t.amount, (t.payment_gateway.name if t.payment_gateway else "-"), t.notes or "-", t.account_details or "-", t.status, timezone.localtime(t.created_at).strftime("%Y-%m-%d %H:%M")])
        return response
    paginator = Paginator(qs, 20)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        template,
        {
            "title": title,
            "page_obj": page_obj,
            "rows": page_obj.object_list,
            "filters": {"from": from_date, "to": to_date, "q": q, "status": status, "method": method},
        },
    )


@login_required
@role_required(PORTAL_ROLES)
def ib_commission(request):
    from django.db.models import Sum
    from django.db.models.functions import TruncDate, TruncWeek, TruncMonth
    from ib.models import ProcessedMT5Deal
    from accounts.models import MT5Account
    
    # Get all referred client IDs
    team_ids = _team_client_ids(request.user)
    
    # Map login_id to client User object
    client_accounts = MT5Account.objects.filter(user_id__in=team_ids).select_related("user")
    login_to_client = {str(acc.login_id): acc.user for acc in client_accounts}
    
    # Query all ProcessedMT5Deal for this IB
    deals = ProcessedMT5Deal.objects.filter(ib_user=request.user).order_by("-close_time")
    
    # 1. Rebate History with pagination
    paginator = Paginator(deals, 50)
    page_number = request.GET.get("page")
    page_obj = paginator.get_page(page_number)
    
    history_rows = []
    for d in page_obj.object_list:
        client_user = login_to_client.get(str(d.login_id))
        history_rows.append({
            "deal_id": d.deal_id,
            "login_id": d.login_id,
            "client_email": client_user.email if client_user else f"Login {d.login_id}",
            "symbol": d.symbol,
            "volume_lots": d.volume_lots,
            "rebate_rate": d.rebate_rate,
            "rebate_amount": d.rebate_amount,
            "close_time": d.close_time,
        })
        
    # 2. Earnings Summary (Daily/Weekly/Monthly)
    daily_earnings = (
        deals.annotate(date=TruncDate("close_time"))
        .values("date")
        .annotate(total_amount=Sum("rebate_amount"), total_lots=Sum("volume_lots"))
        .order_by("-date")[:30]
    )
    weekly_earnings = (
        deals.annotate(week=TruncWeek("close_time"))
        .values("week")
        .annotate(total_amount=Sum("rebate_amount"), total_lots=Sum("volume_lots"))
        .order_by("-week")[:12]
    )
    monthly_earnings = (
        deals.annotate(month=TruncMonth("close_time"))
        .values("month")
        .annotate(total_amount=Sum("rebate_amount"), total_lots=Sum("volume_lots"))
        .order_by("-month")[:12]
    )

    # 3. Client-wise Volume
    client_aggregates = (
        deals.values("login_id")
        .annotate(total_amount=Sum("rebate_amount"), total_lots=Sum("volume_lots"))
        .order_by("-total_amount")
    )
    client_rows = []
    for ca in client_aggregates:
        client_user = login_to_client.get(str(ca["login_id"]))
        client_rows.append({
            "login_id": ca["login_id"],
            "client_email": client_user.email if client_user else f"Login {ca['login_id']}",
            "client_name": client_user.display_name() if client_user else "Unknown",
            "total_lots": ca["total_lots"],
            "total_amount": ca["total_amount"],
        })

    context = {
        "page_obj": page_obj,
        "history_rows": history_rows,
        "daily_earnings": daily_earnings,
        "weekly_earnings": weekly_earnings,
        "monthly_earnings": monthly_earnings,
        "client_rows": client_rows,
    }
    return render(request, "user_portal/ib_commission.html", context)


@login_required
@role_required(PORTAL_ROLES)
def ib_withdraw_request(request):
    from ib.models import IBCommissionSettings, IBProfile
    from django.contrib import messages
    from decimal import Decimal
    from accounts.models import VerifiedBankAccount, VerifiedCryptoAddress

    ib_profile = IBProfile.objects.filter(user=request.user).first()
    if not ib_profile or request.user.role != User.Roles.IB:
        messages.error(request, "You must be an approved Introducing Broker to access this page.")
        return redirect("user-dashboard")

    settings_obj = IBCommissionSettings.get_solo()
    available_balance = _ib_wallet_balance_for_user(request.user)

    if request.method == "POST":
        method_raw = (request.POST.get("method") or "").strip().lower()
        amount_str = (request.POST.get("amount") or "").strip()
        account_details = (request.POST.get("account_details") or "").strip()
        notes = (request.POST.get("notes") or "").strip()

        bank_id = None
        crypto_id = None
        
        if method_raw == "internal":
            method = "internal"
        elif method_raw.startswith("bank_"):
            method = "bank"
            bank_id = method_raw.split("_")[1]
        elif method_raw.startswith("crypto_"):
            method = "crypto"
            crypto_id = method_raw.split("_")[1]
        else:
            method = method_raw

        # Check amount
        try:
            amount = Decimal(amount_str)
        except Exception:
            amount = Decimal("0")

        if amount <= 0:
            messages.error(request, "Please enter a valid positive withdrawal amount.")
        elif amount > available_balance:
            messages.error(request, "Insufficient available commission balance.")
        elif method not in ("internal", "bank", "crypto", "manual"):
            messages.error(request, "Invalid withdrawal method selected.")
        else:
            # Check if method is enabled
            is_enabled = False
            if method == "internal" and settings_obj.enable_withdraw_internal:
                is_enabled = True
            elif method == "bank" and settings_obj.enable_withdraw_bank:
                is_enabled = True
            elif method == "crypto" and settings_obj.enable_withdraw_crypto:
                is_enabled = True
            elif method == "manual" and settings_obj.enable_withdraw_manual:
                is_enabled = True

            if not is_enabled:
                messages.error(request, f"Withdrawal method '{method.capitalize()}' is currently disabled.")
            else:
                if method == "internal":
                    messages.info(request, "Please submit your internal transfer from the IB Wallet here.")
                    return redirect(reverse("user-internal-transfer") + "?from_account=IB_WALLET")
                
                if method == "bank":
                    if not bank_id:
                        messages.error(request, "Please select a verified bank account.")
                        return redirect("user-ib-withdraw-request")
                    selected_bank = VerifiedBankAccount.objects.filter(user=request.user, status=VerifiedBankAccount.Status.APPROVED, id=bank_id).first()
                    if not selected_bank:
                        messages.error(request, "Invalid verified bank account.")
                        return redirect("user-ib-withdraw-request")
                    account_details = (
                        f"Type: BANK\nAccount Name: {selected_bank.account_name}\nBank Name: {selected_bank.bank_name}\n"
                        f"Account Number: {selected_bank.account_number}\nIBAN: {selected_bank.iban}\nVerified Bank ID: {selected_bank.id}"
                    )
                elif method == "crypto":
                    if not crypto_id:
                        messages.error(request, "Please select a verified crypto address.")
                        return redirect("user-ib-withdraw-request")
                    selected_crypto = VerifiedCryptoAddress.objects.filter(user=request.user, status=VerifiedCryptoAddress.Status.APPROVED, id=crypto_id).first()
                    if not selected_crypto:
                        messages.error(request, "Invalid verified crypto address.")
                        return redirect("user-ib-withdraw-request")
                    wn = (selected_crypto.wallet_name or "").strip()
                    account_details = (
                        f"Type: CRYPTO\n"
                        + (f"Wallet Name: {wn}\n" if wn else "")
                        + f"Wallet Address: {selected_crypto.wallet_address}\nNetwork: {selected_crypto.network}\n"
                        f"Verified Crypto ID: {selected_crypto.id}"
                    )
                
                # Atomic re-check under user lock so concurrent IB withdraws
                # cannot both pass the pre-lock available_balance check.
                from django.db import transaction as db_transaction

                with db_transaction.atomic():
                    locked_user = User.objects.select_for_update().get(pk=request.user.pk)
                    live_available = _ib_wallet_balance_for_user(locked_user)
                    if amount > live_available:
                        messages.error(request, "Insufficient available commission balance.")
                        return redirect("user-ib-withdraw-request")
                    tx = Transaction.objects.create(
                        tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
                        status=Transaction.Status.PENDING,
                        actor=locked_user,
                        amount=amount,
                        currency="USD",
                        reference=f"Withdrawal: {method.upper()}",
                        account_details=account_details,
                        notes=notes,
                    )

                log_audit(
                    action="IB_WITHDRAW_REQUEST_CREATED",
                    entity_type="Transaction",
                    entity_id=str(tx.id),
                    actor=request.user,
                    channel=AuditLogChannel.CLIENT,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"amount": str(amount), "method": method},
                )
                messages.success(request, f"Withdrawal request of ${amount:.2f} via {method.capitalize()} submitted successfully.")
                return redirect("user-ib-dashboard")

    # Get recent pending and completed withdrawals to display
    recent_withdrawals = Transaction.objects.filter(
        actor=request.user,
        tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
    ).order_by("-created_at")[:20]

    approved_bank_accounts = VerifiedBankAccount.objects.filter(user=request.user, status=VerifiedBankAccount.Status.APPROVED)
    approved_crypto_addresses = VerifiedCryptoAddress.objects.filter(user=request.user, status=VerifiedCryptoAddress.Status.APPROVED)

    context = {
        "ib_profile": ib_profile,
        "settings": settings_obj,
        "available_balance": available_balance,
        "recent_withdrawals": recent_withdrawals,
        "approved_bank_accounts": approved_bank_accounts,
        "approved_crypto_addresses": approved_crypto_addresses,
    }
    return render(request, "user_portal/ib_withdraw.html", context)


@login_required
@role_required(PORTAL_ROLES)
def ib_withdraw_report(request):
    return _filtered_amount_report(
        request,
        [Transaction.TxType.IB_WITHDRAW, Transaction.TxType.PENDING_IB_WITHDRAW],
        "user_portal/report_cards.html",
        "IB Withdraw Report",
    )


@login_required
@role_required(PORTAL_ROLES)
def team_deposit_report(request):
    team_ids = _team_client_ids(request.user)
    qs = filter_real_ledger_transactions(
        Transaction.objects.filter(
            actor_id__in=team_ids,
            tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        ).order_by("-created_at")
    )
    return render(request, "user_portal/report_cards.html", {"title": "Team Deposit Report", "rows": qs[:200], "filters": {"from": "", "to": ""}})


@login_required
@role_required(PORTAL_ROLES)
def team_withdraw_report(request):
    team_ids = _team_client_ids(request.user)
    qs = filter_real_ledger_transactions(
        Transaction.objects.filter(
            actor_id__in=team_ids,
            tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW],
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        ).order_by("-created_at")
    )
    return render(request, "user_portal/report_cards.html", {"title": "Team Withdraw Report", "rows": qs[:200], "filters": {"from": "", "to": ""}})


@login_required
@role_required(PORTAL_ROLES)
def deposit_report(request):
    return _filtered_amount_report(
        request,
        [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT, Transaction.TxType.PENDING_DEPOSIT],
        "user_portal/report_cards.html",
        "Deposit Report",
    )


@login_required
@role_required(PORTAL_ROLES)
def withdraw_report(request):
    return _filtered_amount_report(
        request,
        [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW, Transaction.TxType.PENDING_WITHDRAW],
        "user_portal/report_cards.html",
        "Withdraw Report",
    )


@login_required
@role_required(PORTAL_ROLES)
def internal_transfer_report(request):
    return _filtered_amount_report(
        request,
        [Transaction.TxType.INTERNAL_TRANSFER],
        "user_portal/report_cards.html",
        "Internal Transfer Report",
    )


@login_required
@role_required(PORTAL_ROLES)
def deal_report(request):
    blocked = _trading_portal_blocked_message(request.user)
    if blocked:
        messages.error(request, "Trading reports are unavailable. " + blocked)
        return redirect("user-dashboard")
    account_id = request.GET.get("account") or ""
    from_date = request.GET.get("from") or ""
    to_date = request.GET.get("to") or ""
    q = (request.GET.get("q") or "").strip()
    accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
    
    deals = []
    summary = {
        "balance": Decimal("0.00"),
        "equity": Decimal("0.00"),
        "profit": Decimal("0.00"),
        "free_margin": Decimal("0.00"),
    }
    
    for acc in accounts:
        summary["balance"] += Decimal(str(acc.balance or 0))
        summary["equity"] += Decimal(str(acc.equity or 0))
        summary["profit"] += Decimal(str(acc.unrealized_pnl or 0))
        summary["free_margin"] += Decimal(str(acc.free_margin or 0))
        
    from mt5_integration.services import _mt5_client, is_mt5_configured
    import time
    if is_mt5_configured():
        try:
            with _mt5_client() as client:
                target_accounts = accounts
                if account_id:
                    target_accounts = accounts.filter(id=account_id)
                for acc in target_accounts:
                    try:
                        from_ts = 0
                        if from_date:
                            from_ts = int(timezone.datetime.strptime(from_date, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
                        to_ts = int(time.time()) + 86400
                        if to_date:
                            to_ts = int(timezone.datetime.strptime(to_date, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()) + 86400
                        total_deals = client.deal_get_total(int(acc.login_id), from_ts, to_ts)
                        raw = []
                        offset = 0
                        while offset < total_deals:
                            chunk = client.deal_get_page(int(acc.login_id), from_ts, to_ts, offset, 5000)
                            if not chunk:
                                break
                            raw.extend(chunk)
                            offset += 5000
                        for d in raw:
                            symbol_name = d.get("Symbol") or ""
                            login_str = str(d.get("Login") or "")
                            if q and q.lower() not in symbol_name.lower() and q.lower() not in login_str:
                                continue
                            action_val = d.get("Action", 0)
                            if action_val == 0:
                                action_str = "Buy"
                            elif action_val == 1:
                                action_str = "Sell"
                            elif action_val == 2:
                                action_str = "Balance"
                            else:
                                action_str = str(action_val)
                            
                            entry_val = d.get("Entry", 0)
                            open_price = "-"
                            close_price = "-"
                            trade_status = "-"
                            
                            if action_val == 2:
                                trade_status = "Balance"
                            elif entry_val == 0:
                                open_price = d.get("Price")
                                trade_status = "Open"
                            elif entry_val in (1, 3):
                                open_price = d.get("PricePosition")
                                close_price = d.get("Price")
                                trade_status = "Closed"
                            elif entry_val == 2:
                                open_price = d.get("PricePosition")
                                close_price = d.get("Price")
                                trade_status = "Reversed"
                            
                            deals.append({
                                "login_id": d.get("Login"),
                                "symbol": symbol_name,
                                "ticket": d.get("Deal"),
                                "time": timezone.datetime.fromtimestamp(d.get("Time", 0), tz=timezone.utc),
                                "type": action_str,
                                "volume": round(d.get("Volume", 0) / 10000.0, 2),
                                "open_price": open_price,
                                "close_price": close_price,
                                "commission": d.get("Commission"),
                                "swap": d.get("Storage"),
                                "profit": d.get("Profit"),
                                "status": trade_status,
                            })
                    except Exception as e:
                        logger.warning("Failed to fetch deals for account %s: %s", acc.login_id, e)
        except Exception as exc:
            logger.warning("MT5 integration client failure in deal_report: %s", exc)

    deals.sort(key=lambda x: x["time"], reverse=True)

    return render(
        request,
        "user_portal/deal_report.html",
        {
            "accounts": accounts,
            "deals": deals,
            "summary": summary,
            "filters": {"account": account_id, "from": from_date, "to": to_date, "q": q},
        },
    )


@login_required
@role_required(PORTAL_ROLES)
def summary_report(request):
    accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
    
    summary = {
        "net_profit": Decimal("0.00"),
        "total_orders": 0,
        "total_volume": Decimal("0.00"),
        "total_deposits": Decimal("0.00"),
        "total_withdrawals": Decimal("0.00"),
    }
    
    from mt5_integration.services import _mt5_client, is_mt5_configured
    import time
    if is_mt5_configured():
        try:
            with _mt5_client() as client:
                to_ts = int(time.time()) + 86400
                from_ts = 0
                for acc in accounts:
                    try:
                        total_deals = client.deal_get_total(int(acc.login_id), from_ts, to_ts)
                        raw = []
                        offset = 0
                        while offset < total_deals:
                            chunk = client.deal_get_page(int(acc.login_id), from_ts, to_ts, offset, 5000)
                            if not chunk:
                                break
                            raw.extend(chunk)
                            offset += 5000
                        for d in raw:
                            action_val = d.get("Action", 0)
                            if action_val in (0, 1): # Buy/Sell
                                summary["net_profit"] += Decimal(str(d.get("Profit", 0)))
                                summary["total_orders"] += 1
                                summary["total_volume"] += Decimal(str(round(d.get("Volume", 0) / 10000.0, 2)))
                            elif action_val == 2: # Balance
                                profit = d.get("Profit", 0)
                                if profit > 0:
                                    summary["total_deposits"] += Decimal(str(profit))
                                elif profit < 0:
                                    summary["total_withdrawals"] += Decimal(str(abs(profit)))
                    except Exception as e:
                        logger.warning("Failed to fetch summary deals for account %s: %s", acc.login_id, e)
        except Exception as exc:
            logger.warning("MT5 integration client failure in summary_report: %s", exc)

    return render(request, "user_portal/summary_report.html", {"summary": summary})


@login_required
@role_required(PORTAL_ROLES)
def trading_page(request):
    blocked = _trading_portal_blocked_message(request.user)
    if blocked:
        messages.error(request, blocked)
        return redirect("user-dashboard")
    return render(request, "user_portal/trading.html")


@login_required
@role_required(PORTAL_ROLES)
def compliance_page(request):
    compliance_settings = ComplianceSettings.get_solo()
    recalc_user_kyc(request.user)
    request.user.refresh_from_db()
    identity_latest = KYCIdentity.objects.filter(user=request.user).order_by("-created_at").first()
    address_latest = KYCAddress.objects.filter(user=request.user).order_by("-created_at").first()
    selfie_latest = Document.objects.filter(
        user=request.user,
        doc_type=Document.DocType.SELFIE,
    ).order_by("-uploaded_at").first()
    bank_latest = VerifiedBankAccount.objects.filter(user=request.user).order_by("-created_at").first()
    crypto_latest = VerifiedCryptoAddress.objects.filter(user=request.user).order_by("-created_at").first()

    def _section_state(row):
        if not row:
            return "NOT_SUBMITTED"
        st = (getattr(row, "status", "") or "").upper()
        if st == "APPROVED":
            return "APPROVED"
        if st == "REJECTED":
            return "REJECTED"
        return "PENDING"

    identity_state = _section_state(identity_latest)
    address_state = _section_state(address_latest)
    bank_state = _section_state(bank_latest)
    crypto_state = _section_state(crypto_latest)

    U = User.KYCComponentStatus
    identity_under_review = bool(
        identity_latest
        and identity_latest.status == KYCIdentity.Status.PENDING
        and identity_latest.front_file
        and identity_latest.back_file
    )
    address_under_review = bool(
        address_latest
        and address_latest.status == KYCAddress.Status.PENDING
        and address_latest.document_file
    )
    is_globally_approved = request.user.kyc_status == User.KYCStatus.APPROVED
    identity_both_verified = is_globally_approved or (
        request.user.kyc_identity_front_status == U.VERIFIED
        and request.user.kyc_identity_back_status == U.VERIFIED
    )
    address_verified_component = is_globally_approved or (request.user.kyc_address_status == U.VERIFIED)


    identity_can_upload = (
        not identity_both_verified
        and not identity_under_review
        and (
            not identity_latest
            or identity_latest.status == KYCIdentity.Status.REJECTED
            or (
                identity_latest.status == KYCIdentity.Status.PENDING
                and not (identity_latest.front_file and identity_latest.back_file)
            )
        )
    )
    identity_can_delete = bool(
        identity_latest
        and not identity_both_verified
        and not identity_under_review
        and identity_latest.status != KYCIdentity.Status.APPROVED
    )

    address_required = bool(compliance_settings.enable_address_verification)
    address_can_upload = (
        address_required
        and not address_verified_component
        and not address_under_review
        and (
            not address_latest
            or address_latest.status == KYCAddress.Status.REJECTED
            or (
                address_latest.status == KYCAddress.Status.PENDING
                and not address_latest.document_file
            )
        )
    )
    address_can_delete = bool(
        address_required
        and address_latest
        and not address_verified_component
        and not address_under_review
        and address_latest.status != KYCAddress.Status.APPROVED
    )

    all_kyc_approved = identity_both_verified and (
        (not address_required) or address_verified_component
    )

    def _ui_status(row):
        if not row:
            return "Not Submitted"
        if row.status == "APPROVED":
            return "Approved"
        if row.status == "REJECTED":
            return "Rejected"
        return "Pending"

    if request.method == "POST":
        action = request.POST.get("action") or ""
        if action == "delete_identity":
            if not identity_can_delete:
                messages.error(request, "You cannot delete identity documents in the current status.")
                return redirect("user-compliance")
            row = KYCIdentity.objects.filter(user=request.user, id=request.POST.get("id")).first()
            if row and row.status != KYCIdentity.Status.APPROVED:
                Document.objects.filter(
                    user=request.user,
                    status=Document.Status.PENDING,
                    doc_type__in=(
                        Document.DocType.ID_DOCUMENT_FRONT,
                        Document.DocType.ID_DOCUMENT_BACK,
                        Document.DocType.NATIONAL_ID,
                        Document.DocType.PASSPORT,
                    ),
                ).delete()
                row.delete()
                recalc_user_kyc(request.user)
                messages.success(request, "Identity record deleted.")
            return redirect("user-compliance")
        if action == "delete_address":
            if not address_can_delete:
                messages.error(request, "You cannot delete address documents in the current status.")
                return redirect("user-compliance")
            row = KYCAddress.objects.filter(user=request.user, id=request.POST.get("id")).first()
            if row and row.status != KYCAddress.Status.APPROVED:
                Document.objects.filter(
                    user=request.user,
                    status=Document.Status.PENDING,
                    doc_type=Document.DocType.PROOF_OF_ADDRESS,
                ).delete()
                row.delete()
                recalc_user_kyc(request.user)
                messages.success(request, "Address record deleted.")
            return redirect("user-compliance")
        if action == "delete_bank":
            row = VerifiedBankAccount.objects.filter(user=request.user, id=request.POST.get("id")).first()
            if row and row.status != VerifiedBankAccount.Status.APPROVED:
                row.delete()
                messages.success(request, "Bank record deleted.")
            return redirect("user-compliance")
        if action == "delete_crypto":
            row = VerifiedCryptoAddress.objects.filter(user=request.user, id=request.POST.get("id")).first()
            if row and row.status != VerifiedCryptoAddress.Status.APPROVED:
                row.delete()
                messages.success(request, "Crypto record deleted.")
            return redirect("user-compliance")

        if action == "upload_identity":
            if not identity_can_upload:
                messages.error(request, "Identity verification cannot be updated right now.")
                return redirect("user-compliance")
            if (
                compliance_settings.identity_lock_after_approval
                and KYCIdentity.objects.filter(user=request.user, status=KYCIdentity.Status.APPROVED).exists()
            ):
                messages.error(request, "Identity already verified.")
                return redirect("user-compliance")
            front = request.FILES.get("identity_front")
            back = request.FILES.get("identity_back")
            err = validate_document_upload(front) or validate_document_upload(back)
            if err:
                messages.error(request, err)
                return redirect("user-compliance")
            document_type = request.POST.get("identity_document_type") or "Passport"
            try:
                with transaction.atomic():
                    Document.objects.filter(
                        user=request.user,
                        status=Document.Status.PENDING,
                        doc_type__in=(
                            Document.DocType.ID_DOCUMENT_FRONT,
                            Document.DocType.ID_DOCUMENT_BACK,
                            Document.DocType.NATIONAL_ID,
                            Document.DocType.PASSPORT,
                        ),
                    ).delete()
                    if compliance_settings.identity_allow_multiple_documents:
                        KYCIdentity.objects.create(
                            user=request.user,
                            document_type=document_type,
                            expiry_date=None,
                            front_file=front,
                            back_file=back,
                            status=KYCIdentity.Status.PENDING,
                        )
                    else:
                        row = KYCIdentity.objects.filter(user=request.user).order_by("-created_at").first()
                        if row and row.status != KYCIdentity.Status.APPROVED:
                            row.document_type = document_type
                            row.expiry_date = None
                            row.front_file = front
                            row.back_file = back
                            row.status = KYCIdentity.Status.PENDING
                            row.save()
                        else:
                            KYCIdentity.objects.create(
                                user=request.user,
                                document_type=document_type,
                                expiry_date=None,
                                front_file=front,
                                back_file=back,
                                status=KYCIdentity.Status.PENDING,
                            )
                    request.user.kyc_status = User.KYCStatus.PENDING
                    request.user.kyc_reject_reason = ""
                    request.user.kyc_identity_front_status = User.KYCComponentStatus.PENDING
                    request.user.kyc_identity_back_status = User.KYCComponentStatus.PENDING
                    request.user.save(
                        update_fields=[
                            "kyc_status",
                            "kyc_reject_reason",
                            "kyc_identity_front_status",
                            "kyc_identity_back_status",
                        ]
                    )
                    recalc_user_kyc(request.user)
                    Document.objects.create(
                        user=request.user,
                        doc_type=Document.DocType.ID_DOCUMENT_FRONT,
                        file=front,
                        uploaded_by=request.user,
                        status=Document.Status.PENDING,
                    )
                    Document.objects.create(
                        user=request.user,
                        doc_type=Document.DocType.ID_DOCUMENT_BACK,
                        file=back,
                        uploaded_by=request.user,
                        status=Document.Status.PENDING,
                    )
            except Exception:
                logger.exception("Identity upload failed", extra={"user_id": request.user.id})
                messages.error(request, "Unable to submit identity documents. Please try again.")
                return redirect("user-compliance")
            verify_url = request.build_absolute_uri(reverse("user-compliance"))
            try:
                send_kyc_event_email(
                    "identity_submitted",
                    user=request.user,
                    extra_context={"verify_url": verify_url, "upload_url": verify_url},
                    dedupe_seconds=120,
                )
            except Exception:
                logger.exception("Identity submitted email failed", extra={"user_id": request.user.id})
            try:
                _create_kyc_staff_notification_once(request.user)
            except Exception:
                logger.exception("KYC staff notify failed (identity)", extra={"user_id": request.user.id})
            messages.success(request, "Request submitted successfully.")
            return redirect("user-compliance")
        elif action == "upload_address":
            if not address_can_upload:
                messages.error(request, "Address verification cannot be updated right now.")
                return redirect("user-compliance")
            if (
                compliance_settings.address_lock_after_approval
                and KYCAddress.objects.filter(user=request.user, status=KYCAddress.Status.APPROVED).exists()
            ):
                messages.error(request, "Address already verified.")
                return redirect("user-compliance")
            address_file = request.FILES.get("address_file")
            address_type = request.POST.get("address_document_type") or "Utility Bill"
            err = validate_document_upload(address_file)
            if err:
                messages.error(request, err)
                return redirect("user-compliance")
            try:
                with transaction.atomic():
                    Document.objects.filter(
                        user=request.user,
                        status=Document.Status.PENDING,
                        doc_type=Document.DocType.PROOF_OF_ADDRESS,
                    ).delete()
                    row = KYCAddress.objects.filter(user=request.user).order_by("-created_at").first()
                    if row and row.status != KYCAddress.Status.APPROVED:
                        row.document_type = address_type
                        row.document_file = address_file
                        row.status = KYCAddress.Status.PENDING
                        row.save()
                    else:
                        KYCAddress.objects.create(
                            user=request.user,
                            document_type=address_type,
                            document_file=address_file,
                            status=KYCAddress.Status.PENDING,
                        )
                    request.user.kyc_status = User.KYCStatus.PENDING
                    request.user.kyc_reject_reason = ""
                    request.user.kyc_address_status = User.KYCComponentStatus.PENDING
                    request.user.save(
                        update_fields=[
                            "kyc_status",
                            "kyc_reject_reason",
                            "kyc_address_status",
                        ]
                    )
                    recalc_user_kyc(request.user)
                    Document.objects.create(
                        user=request.user,
                        doc_type=Document.DocType.PROOF_OF_ADDRESS,
                        file=address_file,
                        uploaded_by=request.user,
                        status=Document.Status.PENDING,
                    )
            except Exception:
                logger.exception("Address upload failed", extra={"user_id": request.user.id})
                messages.error(request, "Unable to submit address document. Please try again.")
                return redirect("user-compliance")
            verify_url = request.build_absolute_uri(reverse("user-compliance"))
            try:
                send_kyc_event_email(
                    "address_submitted",
                    user=request.user,
                    extra_context={"verify_url": verify_url, "upload_url": verify_url},
                    dedupe_seconds=120,
                )
            except Exception:
                logger.exception("Address submitted email failed", extra={"user_id": request.user.id})
            try:
                _create_kyc_staff_notification_once(request.user)
            except Exception:
                logger.exception("KYC staff notify failed (address)", extra={"user_id": request.user.id})
            messages.success(request, "Request submitted successfully.")
            return redirect("user-compliance")
        elif action == "submit_bank":
            bank_fields = {f.field_key: f for f in BankField.objects.filter(is_enabled=True)}
            required_keys = {k for k, v in bank_fields.items() if v.is_required}
            posted = {
                "account_name": request.POST.get("account_name", "").strip(),
                "account_number": request.POST.get("account_number", "").strip(),
                "iban": request.POST.get("iban", "").strip(),
                "swift_code": request.POST.get("swift_code", "").strip(),
                "bank_name": request.POST.get("bank_name", "").strip(),
                "bank_address": request.POST.get("bank_address", "").strip(),
                "branch": request.POST.get("branch", "").strip(),
                "country": (request.POST.get("bank_country", "").strip() or request.user.country),
            }
            for key in required_keys:
                if not posted.get(key):
                    messages.error(request, f"{bank_fields[key].label} is required.")
                    return redirect("user-compliance")
            if not posted["account_number"] and not posted["iban"]:
                messages.error(request, "Provide either an account number or an IBAN.")
                return redirect("user-compliance")
            bank_count = VerifiedBankAccount.objects.filter(user=request.user).count()
            row = VerifiedBankAccount.objects.filter(user=request.user).order_by("-created_at").first()
            if row and row.status != VerifiedBankAccount.Status.APPROVED:
                row.account_name = posted["account_name"]
                row.account_number = posted["account_number"] or (posted["iban"][:120] if posted["iban"] else "")
                row.iban = posted["iban"]
                row.swift_code = posted["swift_code"]
                row.bank_name = posted["bank_name"]
                row.bank_address = posted["bank_address"]
                row.branch = posted["branch"]
                row.country = posted["country"]
                row.status = VerifiedBankAccount.Status.APPROVED
                row.save()
                messages.success(request, "Bank details updated successfully.")
            elif bank_count >= MAX_VERIFIED_BANK_ACCOUNTS_PER_USER:
                messages.error(
                    request,
                    f"You can store at most {MAX_VERIFIED_BANK_ACCOUNTS_PER_USER} bank accounts.",
                )
                return redirect("user-compliance")
            else:
                acct_num = posted["account_number"] or (posted["iban"][:120] if posted["iban"] else "")
                VerifiedBankAccount.objects.create(
                    user=request.user,
                    account_name=posted["account_name"],
                    account_number=acct_num,
                    iban=posted["iban"],
                    swift_code=posted["swift_code"],
                    bank_name=posted["bank_name"],
                    bank_address=posted["bank_address"],
                    branch=posted["branch"],
                    country=posted["country"],
                    status=VerifiedBankAccount.Status.APPROVED,
                )
                messages.success(request, "Bank details added successfully.")
        elif action == "submit_crypto":
            network = request.POST.get("crypto_network", "").strip()
            wallet_address = request.POST.get("wallet_address", "").strip()
            wallet_name = request.POST.get("wallet_name", "").strip()
            if not network or not wallet_address:
                messages.error(request, "Network and wallet address are required.")
                return redirect("user-compliance")
            crypto_count = VerifiedCryptoAddress.objects.filter(user=request.user).count()
            row = VerifiedCryptoAddress.objects.filter(user=request.user).order_by("-created_at").first()
            if row and row.status != VerifiedCryptoAddress.Status.APPROVED:
                row.network = network
                row.wallet_address = wallet_address
                row.wallet_name = wallet_name[:120]
                row.status = VerifiedCryptoAddress.Status.APPROVED
                row.save()
                messages.success(request, "Crypto details updated successfully.")
            elif crypto_count >= MAX_VERIFIED_CRYPTO_WALLETS_PER_USER:
                messages.error(
                    request,
                    f"You can store at most {MAX_VERIFIED_CRYPTO_WALLETS_PER_USER} crypto wallets.",
                )
                return redirect("user-compliance")
            else:
                VerifiedCryptoAddress.objects.create(
                    user=request.user,
                    network=network,
                    wallet_address=wallet_address,
                    wallet_name=wallet_name[:120],
                    status=VerifiedCryptoAddress.Status.APPROVED,
                )
                messages.success(request, "Crypto details added successfully.")
        return redirect("user-compliance")
    bank_count = VerifiedBankAccount.objects.filter(user=request.user).count()
    crypto_count = VerifiedCryptoAddress.objects.filter(user=request.user).count()
    bank_slots_left = max(0, MAX_VERIFIED_BANK_ACCOUNTS_PER_USER - bank_count)
    crypto_slots_left = max(0, MAX_VERIFIED_CRYPTO_WALLETS_PER_USER - crypto_count)
    bank_form_row = (
        bank_latest
        if bank_latest and bank_latest.status != VerifiedBankAccount.Status.APPROVED
        else None
    )
    crypto_form_row = (
        crypto_latest
        if crypto_latest and crypto_latest.status != VerifiedCryptoAddress.Status.APPROVED
        else None
    )
    bank_can_submit = bank_form_row is not None or bank_slots_left > 0
    crypto_can_submit = crypto_form_row is not None or crypto_slots_left > 0
    context = {
        "compliance_settings": compliance_settings,
        "identity_rows": KYCIdentity.objects.filter(user=request.user).order_by("-created_at")[:20],
        "address_rows": KYCAddress.objects.filter(user=request.user).order_by("-created_at")[:20],
        "bank_rows": VerifiedBankAccount.objects.filter(user=request.user).order_by("-created_at")[:20],
        "crypto_rows": VerifiedCryptoAddress.objects.filter(user=request.user).order_by("-created_at")[:20],
        "max_verified_banks": MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
        "max_verified_crypto": MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
        "bank_count": bank_count,
        "crypto_count": crypto_count,
        "bank_slots_left": bank_slots_left,
        "crypto_slots_left": crypto_slots_left,
        "bank_form_row": bank_form_row,
        "crypto_form_row": crypto_form_row,
        "bank_can_submit": bank_can_submit,
        "crypto_can_submit": crypto_can_submit,
        "identity_document_options": RequiredDocument.objects.filter(
            category=RequiredDocument.Category.IDENTITY, is_enabled=True
        ).order_by("name"),
        "address_document_options": RequiredDocument.objects.filter(
            category=RequiredDocument.Category.ADDRESS, is_enabled=True
        ).order_by("name"),
        "crypto_network_options": CryptoNetwork.objects.filter(is_enabled=True).order_by("label"),
        "bank_field_settings": BankField.objects.filter(is_enabled=True).order_by("id"),
        "identity_status_ui": _ui_status(identity_latest),
        "address_status_ui": _ui_status(address_latest),
        "bank_status_ui": _ui_status(bank_latest),
        "crypto_status_ui": _ui_status(crypto_latest),
        "identity_state": "APPROVED" if is_globally_approved else identity_state,
        "address_state": "APPROVED" if is_globally_approved else address_state,
        "identity_front_status": "verified" if is_globally_approved else request.user.kyc_identity_front_status,
        "identity_back_status": "verified" if is_globally_approved else request.user.kyc_identity_back_status,
        "address_component_status": "verified" if is_globally_approved else request.user.kyc_address_status,
        "kyc_final_status": request.user.kyc_final_status,
        "bank_state": bank_state,
        "crypto_state": crypto_state,
        "identity_can_upload": identity_can_upload,
        "identity_can_delete": identity_can_delete,
        "address_can_upload": address_can_upload,
        "address_can_delete": address_can_delete,
        "all_kyc_approved": all_kyc_approved,
        "identity_latest": identity_latest,
        "address_latest": address_latest,
        "selfie_latest": selfie_latest,
        "bank_latest": bank_latest,
        "crypto_latest": crypto_latest,
    }
    return render(request, "user_portal/compliance.html", context)


@login_required
@role_required(PORTAL_ROLES)
def profile_page(request):
    r = restriction_for_user(request.user)
    if r and r.disable_profile_access:
        messages.error(request, "Profile access is disabled for your account. Please contact support.")
        return redirect("user-dashboard")
    return render(request, "user_portal/profile.html", {"u": request.user})


@login_required
@role_required(PORTAL_ROLES)
def legal_agreements_page(request):
    settings_obj = LegalAgreementSettings.get_solo()
    active_docs = LegalDocument.objects.filter(is_active=True).order_by("category", "order", "id")
    grouped_docs = {
        "ESSENTIAL": active_docs.filter(category=LegalDocument.Category.ESSENTIAL),
        "TRADING": active_docs.filter(category=LegalDocument.Category.TRADING),
        "REGIONAL": active_docs.filter(category=LegalDocument.Category.REGIONAL),
        "ADDITIONAL": active_docs.filter(category=LegalDocument.Category.ADDITIONAL),
        "CUSTOM": active_docs.filter(category=LegalDocument.Category.CUSTOM),
    }
    return render(
        request,
        "user_portal/legal_agreements.html",
        {"s": settings_obj, "grouped_docs": grouped_docs},
    )


@login_required
@role_required(PORTAL_ROLES)
def trading_platform_page(request):
    platforms = TradingPlatform.objects.filter(is_active=True)
    org = OrganizationProfileSettings.get_solo()
    return render(request, "user_portal/trading_platform.html", {"platforms": platforms, "org": org})

@login_required
@role_required(PORTAL_ROLES)
def my_documents_page(request):
    r = restriction_for_user(request.user)
    if r and r.disable_profile_access:
        messages.error(request, "Document access is disabled for your account. Please contact support.")
        return redirect("user-dashboard")
    list_status = (request.GET.get("status") or "pending").strip().lower()
    if list_status not in {"pending", "approved", "rejected"}:
        list_status = "pending"
    base = Document.objects.filter(user=request.user)
    status_counts = {
        "pending": base.filter(status=Document.Status.PENDING).count(),
        "approved": base.filter(status=Document.Status.APPROVED).count(),
        "rejected": base.filter(status=Document.Status.REJECTED).count(),
    }
    if list_status == "approved":
        docs = base.filter(status=Document.Status.APPROVED)
    elif list_status == "rejected":
        docs = base.filter(status=Document.Status.REJECTED)
    else:
        docs = base.filter(status=Document.Status.PENDING)
    docs = docs.order_by("-uploaded_at")[:100]
    return render(
        request,
        "user_portal/my_documents.html",
        {"documents": docs, "list_status": list_status, "status_counts": status_counts},
    )


@login_required
@role_required(PORTAL_ROLES)
def verification_page(request):
    r = restriction_for_user(request.user)
    if r and r.disable_profile_access:
        messages.error(request, "Verification pages are disabled for your account. Please contact support.")
        return redirect("user-dashboard")
    docs = Document.objects.filter(user=request.user).order_by("-uploaded_at")
    return render(
        request,
        "user_portal/verification.html",
        {"u": request.user, "documents_count": docs.count()},
    )


@login_required
@role_required(PORTAL_ROLES)
def change_password_page(request):
    if request.method == "POST":
        current_password = request.POST.get("current_password") or ""
        new_password = request.POST.get("new_password") or ""
        confirm_password = request.POST.get("confirm_password") or ""

        force = request.user.force_password_change
        if not force and not request.user.check_password(current_password):
            messages.error(request, "Current password is incorrect.")
        elif len(new_password) < 8:
            messages.error(request, "New password must be at least 8 characters.")
        elif new_password != confirm_password:
            messages.error(request, "New password and confirmation do not match.")
        else:
            request.user.set_password(new_password)
            request.user.force_password_change = False
            request.user.save(update_fields=["password", "force_password_change"])
            messages.success(request, "Password updated successfully.")
            return redirect("user-profile")

    return render(request, "user_portal/change_password.html", {"title": "Change Password"})


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["GET", "POST"])
def security_center(request):
    """Google Authenticator (TOTP) setup for client accounts."""
    import pyotp

    user = request.user
    if request.method == "POST":
        action = request.POST.get("action") or ""
        if action == "start_totp":
            secret = pyotp.random_base32()
            request.session["totp_setup_secret"] = secret
            messages.info(request, "Enter the setup code below to confirm, or scan the otpauth URI in your app.")
        elif action == "confirm_totp":
            secret = request.session.get("totp_setup_secret") or user.totp_secret
            code = (request.POST.get("code") or "").replace(" ", "").strip()
            if secret and pyotp.TOTP(secret).verify(code, valid_window=1):
                user.totp_secret = secret
                user.totp_enabled = True
                user.save(update_fields=["totp_secret", "totp_enabled"])
                request.session.pop("totp_setup_secret", None)
                log_audit(
                    action="TOTP_ENABLED",
                    entity_type="User",
                    entity_id=str(user.pk),
                    actor=user,
                    channel=AuditLogChannel.CLIENT,
                    request=request,
                    ip=get_client_ip(request),
                )
                messages.success(request, "Two-factor authentication is now enabled.")
            else:
                messages.error(request, "Invalid code. Try again.")
        elif action == "disable_totp":
            code = (request.POST.get("code") or "").replace(" ", "").strip()
            if user.totp_secret and pyotp.TOTP(user.totp_secret).verify(code, valid_window=1):
                user.totp_enabled = False
                user.totp_secret = ""
                user.save(update_fields=["totp_secret", "totp_enabled"])
                request.session.pop("totp_setup_secret", None)
                log_audit(
                    action="TOTP_DISABLED",
                    entity_type="User",
                    entity_id=str(user.pk),
                    actor=user,
                    channel=AuditLogChannel.CLIENT,
                    request=request,
                    ip=get_client_ip(request),
                )
                messages.success(request, "Two-factor authentication disabled.")
            else:
                messages.error(request, "Invalid code.")
        return redirect("user-security-center")
    setup_secret = request.session.get("totp_setup_secret")
    otp_uri = ""
    if setup_secret:
        otp_uri = pyotp.TOTP(setup_secret).provisioning_uri(
            name=user.email or user.username,
            issuer_name="Broker CRM",
        )
    return render(
        request,
        "user_portal/security_center.html",
        {
            "title": "Security",
            "totp_enabled": user.totp_enabled,
            "setup_secret": setup_secret,
            "otp_uri": otp_uri,
        },
    )


def _build_leverage_options_open_account(max_leverage_value, leverage_options=None):
    """Prefer AccountType.leverage_options when set; else derive from max leverage."""
    raw_opts = leverage_options if isinstance(leverage_options, (list, tuple)) else None
    if raw_opts:
        parsed = []
        for v in raw_opts:
            try:
                n = int(v)
            except Exception:
                continue
            if n >= 1:
                parsed.append(n)
        if parsed:
            return sorted(set(parsed))
    try:
        max_lv = int(max_leverage_value or 100)
    except Exception:
        max_lv = 100
    base_steps = [100, 200, 300, 400, 500, 1000, 1500, 2000]
    options = [step for step in base_steps if step <= max_lv]
    if max_lv > 0 and max_lv not in options:
        options.append(max_lv)
    if not options:
        options = [100]
    return sorted(set(options))


def _resolve_real_mt5_group(account_type: TradingAccountType) -> Optional[MT5Group]:
    if getattr(account_type, "crm_group_id", None):
        g = MT5Group.objects.filter(id=account_type.crm_group_id, is_active=True).first()
        if g:
            return g
    return MT5Group.objects.filter(is_active=True).order_by("id").first()


def _resolve_demo_mt5_group(account_type: TradingAccountType, demo_settings: DemoAccountSettings) -> Optional[MT5Group]:
    if getattr(account_type, "account_category", "LIVE") == "DEMO":
        if account_type.crm_group and account_type.crm_group.is_active:
            return account_type.crm_group
            
    if getattr(account_type, "demo_group_id", None):
        g = MT5Group.objects.filter(id=account_type.demo_group_id, is_active=True).first()
        if g:
            return g
    if getattr(demo_settings, "default_group_id", None):
        g = MT5Group.objects.filter(id=demo_settings.default_group_id, is_active=True).first()
        if g:
            return g
    g = (
        MT5Group.objects.filter(is_active=True)
        .filter(Q(crm_group_name__icontains="demo") | Q(name__icontains="demo"))
        .order_by("crm_group_name", "name")
        .first()
    )
    if g:
        return g
    return MT5Group.objects.filter(is_active=True).order_by("id").first()


def _parse_demo_opening_balance(request, demo_settings: DemoAccountSettings) -> Decimal:
    default_bal = Decimal(str(demo_settings.default_balance or 10000))
    mode = (request.POST.get("demo_balance_preset") or "default").strip().lower()
    custom_raw = (request.POST.get("demo_balance_custom") or "").strip()
    presets = {
        "10000": Decimal("10000"),
        "50000": Decimal("50000"),
        "100000": Decimal("100000"),
        "default": default_bal,
    }
    if mode == "custom" and custom_raw:
        try:
            bal = Decimal(custom_raw)
        except Exception:
            bal = default_bal
    else:
        bal = presets.get(mode, default_bal)
    if bal < Decimal("100"):
        bal = Decimal("100")
    if bal > Decimal("10000000"):
        bal = Decimal("10000000")
    return bal


def _count_mt5_same_kind(user, account_type: TradingAccountType, *, live: bool) -> int:
    want = MT5Account.AccountType.LIVE if live else MT5Account.AccountType.DEMO
    name_part = account_type.account_name or ""
    return MT5Account.objects.filter(
        user=user,
        account_type=want,
        account_label__icontains=name_part,
    ).count()


PORTAL_OPEN_ACCOUNT_CURRENCIES = frozenset({"USD", "EUR", "AED", "PKR"})


def _match_trader_client_open_enabled() -> bool:
    try:
        TradingPlatformIntegration.ensure_defaults()
        row = TradingPlatformIntegration.objects.filter(
            platform=TradingPlatformIntegration.Platform.MATCH_TRADER
        ).first()
        mt = MatchTraderSettings.get_solo()
        return bool(row and row.enabled and mt.is_active)
    except Exception:
        return False


def _btrader_client_open_enabled() -> bool:
    try:
        from btrader_integration.services import is_btrader_configured
        return is_btrader_configured()
    except Exception:
        return False


def _ensure_mt5_group_for_match_trader(broker_group: MatchTraderBrokerGroup) -> Optional[MT5Group]:
    from django.utils.text import slugify

    cg = getattr(broker_group, "crm_group", None)
    if cg is not None:
        return cg

    base = slugify(broker_group.name)[:40] or "group"
    unique_name = (f"MATCHTRADER-{broker_group.id}-{base}-auto")[:120]
    existing = MT5Group.objects.filter(name=unique_name).first()
    if existing:
        return existing
    return MT5Group.objects.create(
        name=unique_name[:120],
        crm_group_name=broker_group.name[:120],
        platform=MT5Group.BrokerPlatform.MATCH_TRADER,
        platform_group_name=broker_group.name[:120],
        match_trader_broker_group=broker_group,
        is_active=True,
        description="Auto-created for Match-Trader account type mapping.",
    )


def _open_account_type_supports_mt5(t: TradingAccountType) -> bool:
    cg = getattr(t, "crm_group", None)
    if cg is not None:
        return cg.platform == MT5Group.BrokerPlatform.MT5
    return t.platform in (TradingAccountType.Platform.MT5, TradingAccountType.Platform.MT4)


def _match_trader_broker_group_for_account_type(t: TradingAccountType):
    cg = getattr(t, "crm_group", None)
    if not cg:
        return None
    return getattr(cg, "match_trader_broker_group", None)


def _open_account_type_supports_match_trader(t: TradingAccountType) -> bool:
    return bool(_match_trader_broker_group_for_account_type(t)) and _match_trader_client_open_enabled()


def _open_account_type_supports_btrader(t: TradingAccountType) -> bool:
    cg = getattr(t, "crm_group", None)
    if cg is None:
        return False
    return cg.platform == MT5Group.BrokerPlatform.BTRADER and _btrader_client_open_enabled()


def _btrader_group_name_for_account_type(t: TradingAccountType) -> str:
    cg = getattr(t, "crm_group", None)
    if not cg:
        return ""
    return (cg.platform_group_name or cg.name or "").strip()


def _resolve_btrader_group(account_type: TradingAccountType, *, is_demo: bool, demo_settings=None) -> Optional[MT5Group]:
    if is_demo:
        if getattr(account_type, "demo_group_id", None):
            g = MT5Group.objects.filter(
                id=account_type.demo_group_id,
                is_active=True,
                platform=MT5Group.BrokerPlatform.BTRADER,
            ).first()
            if g:
                return g
    cg = getattr(account_type, "crm_group", None)
    if cg and cg.is_active and cg.platform == MT5Group.BrokerPlatform.BTRADER:
        return cg
    return None


def _display_open_account_type_name(raw: str | None) -> str:
    """UI label without platform suffix, e.g. 'Standard (BTrader)' â†’ 'Standard'."""
    import re

    name = (raw or "").strip()
    if not name:
        return name
    name = re.sub(
        r"\s*\((?:b[\s-]?trader|mt5|mt4|match[\s-]?trader)\)\s*",
        "",
        name,
        flags=re.IGNORECASE,
    )
    name = re.sub(
        r"\s*[-â€“â€”]\s*(?:b[\s-]?trader|mt5|mt4)\s*$",
        "",
        name,
        flags=re.IGNORECASE,
    )
    return name.strip() or (raw or "").strip()


def _open_account_type_payload(t: TradingAccountType, *, demo_types_exist: bool, is_demo_flow: bool = False) -> dict:
    levs = _build_leverage_options_open_account(
        getattr(t, "max_leverage", 100),
        getattr(t, "leverage_options", None),
    )
    cat = getattr(t, "account_category", "LIVE")
    # Always expose both flags so mobile can filter Real vs Demo without
    # relying on the request kind (portal still uses is_demo_flow for UI).
    demo_sel = (cat == "DEMO") or (cat == "LIVE" and getattr(t, "demo_enabled", False))
    live_sel = cat == "LIVE"
    _ = is_demo_flow  # retained for call-site compatibility
    if t.pricing_type == TradingAccountType.PricingType.SPREAD:
        spread_txt = t.portal_pricing_spread_text()
    else:
        spread_txt = (t.spread or "").strip() or "â€”"
    if t.pricing_type == TradingAccountType.PricingType.COMMISSION:
        commission_txt = t.portal_pricing_commission_text()
    else:
        commission_txt = str(t.commission or 0)
    supports_mt5 = _open_account_type_supports_mt5(t)
    supports_match_trader = _open_account_type_supports_match_trader(t)
    supports_btrader = _open_account_type_supports_btrader(t)
    return {
        "id": t.id,
        "name": _display_open_account_type_name(t.account_name),
        "description": (t.description or "")[:4000],
        "min_deposit": str(t.min_deposit or 0),
        "spread": spread_txt,
        "commission": commission_txt,
        "swap": "Swap-free" if t.swap_free else "Standard",
        "margin_call": int(t.margin_call_level or 0),
        "stop_out": int(t.stop_out_level or 0),
        "max_leverage": int(t.max_leverage or 100),
        "leverage_options": levs,
        "default_currency": str(t.currency or "USD"),
        "supports_mt5": supports_mt5,
        "supports_match_trader": supports_match_trader,
        "supports_btrader": supports_btrader,
        "match_trader_group": (
            (_match_trader_broker_group_for_account_type(t).name or "")
            if _match_trader_broker_group_for_account_type(t)
            else ""
        ),
        "btrader_group": _btrader_group_name_for_account_type(t) if supports_btrader else "",
        "server_hint": (t.server_name or "").strip(),
        "demo_selectable": demo_sel,
        "live_selectable": live_sel,
        "suitable_for": getattr(t, "suitable_for", "All Traders"),
        "min_demo_balance": float(getattr(t, "min_demo_balance", 100)),
        "max_demo_balance": float(getattr(t, "max_demo_balance", 100000)),
        "account_category": cat,
    }


@login_required
@role_required(PORTAL_ROLES)
def open_live_account(request):
    account_type_field_names = {f.name for f in TradingAccountType._meta.get_fields()}
    account_types_qs = TradingAccountType.objects.select_related(
        "crm_group",
        "crm_group__match_trader_broker_group",
        "demo_group",
    ).all()
    if "status" in account_type_field_names:
        account_types_qs = account_types_qs.filter(status=True)
    elif "is_active" in account_type_field_names:
        account_types_qs = account_types_qs.filter(is_active=True)
    account_types_qs = account_types_qs.order_by("display_order", "account_name")
    raw_types = list(account_types_qs)
    demo_types_exist = any(getattr(t, "demo_enabled", False) for t in raw_types)
    account_types = [
        t
        for t in raw_types
        if (
            _open_account_type_supports_mt5(t)
            or _open_account_type_supports_match_trader(t)
            or _open_account_type_supports_btrader(t)
        )
    ]
    demo_settings = DemoAccountSettings.get_solo()
    initial_kind = (request.GET.get("kind") or "").strip().lower()
    if initial_kind not in {"demo", "real"}:
        initial_kind = "real"
        
    is_demo_flow = (initial_kind == "demo")
    account_types_payload = [_open_account_type_payload(t, demo_types_exist=demo_types_exist, is_demo_flow=is_demo_flow) for t in account_types]
    match_trader_enabled = _match_trader_client_open_enabled()
    btrader_enabled = _btrader_client_open_enabled()

    r = restriction_for_user(request.user)
    if r and r.disable_create_mt5:
        messages.error(request, "Creating new trading accounts is disabled for your account. Please contact support.")
        return redirect("user-dashboard")

    if request.method == "POST":
        kind = (request.POST.get("account_kind") or "real").strip().lower()
        is_demo = kind == "demo"
        account_type_id = request.POST.get("account_type")
        currency = (request.POST.get("currency") or "USD").strip().upper()
        leverage = request.POST.get("leverage") or "100"
        main_password = (request.POST.get("main_password") or "").strip()
        investor_password = (request.POST.get("investor_password") or "").strip()
        account_type = account_types_qs.filter(id=account_type_id).first()
        if not account_type:
            messages.error(request, "Selected account type is not available.")
            return redirect("user-open-live-account")
        if not (
            _open_account_type_supports_mt5(account_type)
            or _open_account_type_supports_match_trader(account_type)
            or _open_account_type_supports_btrader(account_type)
        ):
            messages.error(request, "Selected account type is not available.")
            return redirect("user-open-live-account")

        trading_platform = (request.POST.get("trading_platform") or "").strip().upper()
        if trading_platform not in ("MT5", "MATCH_TRADER", "BTRADER"):
            if _open_account_type_supports_btrader(account_type):
                trading_platform = "BTRADER"
            elif _open_account_type_supports_match_trader(account_type):
                trading_platform = "MATCH_TRADER"
            else:
                trading_platform = "MT5"

        if currency not in PORTAL_OPEN_ACCOUNT_CURRENCIES:
            messages.error(request, "Please choose a valid account currency.")
            return redirect("user-open-live-account")

        if trading_platform == "MATCH_TRADER" and not _open_account_type_supports_match_trader(account_type):
            messages.error(request, "Match-Trader is not available for this account type.")
            return redirect("user-open-live-account")
        if trading_platform == "BTRADER" and not _open_account_type_supports_btrader(account_type):
            messages.error(request, "BTrader is not available for this account type.")
            return redirect("user-open-live-account")
        if trading_platform == "MT5" and not _open_account_type_supports_mt5(account_type):
            messages.error(request, "MT5 is not available for this account type.")
            return redirect("user-open-live-account")

        if is_demo:
            cat = getattr(account_type, "account_category", "LIVE")
            demo_sel = (cat == "DEMO") or (cat == "LIVE" and getattr(account_type, "demo_enabled", False))
            if not demo_sel:
                messages.error(request, "This account type is not enabled for demo accounts.")
                return redirect("user-open-live-account")
            
            raw_initial_bal = request.POST.get("initial_demo_balance")
            try:
                opening_bal = Decimal(str(raw_initial_bal or "").strip() or "10000")
            except Exception:
                opening_bal = Decimal("10000")
                
            min_demo = Decimal(str(getattr(account_type, "min_demo_balance", "100.00")))
            max_demo = Decimal(str(getattr(account_type, "max_demo_balance", "100000.00")))
            if opening_bal < min_demo or opening_bal > max_demo:
                messages.error(request, f"Demo balance must be between {min_demo} and {max_demo}.")
                return redirect(f"{reverse('user-open-live-account')}?kind=demo")

            mt5_mode = MT5Account.AccountType.DEMO
            dep_ok = False
            wdr_ok = False
        else:
            mt5_mode = MT5Account.AccountType.LIVE
            opening_bal = Decimal("0")
            dep_ok = True
            wdr_ok = True
        try:
            leverage_val = int(leverage)
        except Exception:
            leverage_val = 100
        allowed_leverage_options = _build_leverage_options_open_account(
            getattr(account_type, "max_leverage", 100),
            getattr(account_type, "leverage_options", None),
        )
        if leverage_val not in allowed_leverage_options:
            leverage_val = allowed_leverage_options[0]

        if len(main_password) < 8 or len(investor_password) < 8:
            messages.error(request, "Trading and investor passwords must be at least 8 characters.")
            return redirect("user-open-live-account")

        max_n = (account_type.max_demo_accounts if is_demo else account_type.max_live_accounts) or 0
        if max_n > 0:
            cur = _count_mt5_same_kind(request.user, account_type, live=not is_demo)
            if cur >= max_n:
                messages.error(
                    request,
                    f"You have reached the maximum number of {'demo' if is_demo else 'live'} accounts for this type.",
                )
                return redirect("user-open-live-account")

        def _unique_digits(length=8):
            while True:
                candidate = get_random_string(length, allowed_chars="0123456789")
                if not MT5Account.objects.filter(login_id=candidate).exists():
                    return candidate

        account_number = _unique_digits(8)

        if is_demo:
            opening_bal = _parse_demo_opening_balance(request, demo_settings)
            mt5_mode = MT5Account.AccountType.DEMO
            dep_ok = False
            wdr_ok = False
            if trading_platform == "MATCH_TRADER":
                brg = _match_trader_broker_group_for_account_type(account_type)
                if not brg:
                    messages.error(
                        request,
                        "Match-Trader is not mapped for this account typeâ€™s CRM group. Configure it in Admin â†’ Group Management.",
                    )
                    return redirect("user-open-live-account")
                group = _ensure_mt5_group_for_match_trader(brg)
                if not group:
                    messages.error(request, "Could not prepare Match-Trader group mapping.")
                    return redirect("user-open-live-account")
                server_name = f"Match-Trader Demo â€” {brg.name}"
                account_label = f"Demo â€” {account_type.account_name}"
            elif trading_platform == "BTRADER":
                group = _resolve_btrader_group(account_type, is_demo=True, demo_settings=demo_settings)
                if not group:
                    messages.error(
                        request,
                        "BTrader is not mapped for this account typeâ€™s CRM group. Configure it in Admin â†’ Group Management.",
                    )
                    return redirect("user-open-live-account")
                from btrader_integration.services import get_btrader_settings
                bt_cfg = get_btrader_settings() or {}
                server_name = f"{bt_cfg.get('server_name') or 'BTrader'} Demo"
                account_label = f"Demo â€” {account_type.account_name}"
            else:
                group = _resolve_demo_mt5_group(account_type, demo_settings)
                if not group:
                    messages.error(request, "No MT5 group is configured for demo accounts. Please contact support.")
                    return redirect("user-open-live-account")
                server_name = _demo_server_name()
                account_label = f"Demo â€” {account_type.account_name}"
        else:
            mt5_mode = MT5Account.AccountType.LIVE
            opening_bal = Decimal("0")
            dep_ok = True
            wdr_ok = True
            if trading_platform == "MATCH_TRADER":
                brg = _match_trader_broker_group_for_account_type(account_type)
                if not brg:
                    messages.error(
                        request,
                        "BTrader is not mapped for this account typeâ€™s CRM group. Configure it in Admin â†’ Group Management.",
                    )
                    return redirect("user-open-live-account")
                group = _ensure_mt5_group_for_match_trader(brg)
                if not group:
                    messages.error(request, "Could not prepare Match-Trader group mapping.")
                    return redirect("user-open-live-account")
                server_name = f"Match-Trader â€” {brg.name}"
                account_label = f"Real â€” {account_type.account_name}"
            elif trading_platform == "BTRADER":
                group = _resolve_btrader_group(account_type, is_demo=False)
                if not group:
                    messages.error(
                        request,
                        "BTrader is not mapped for this account typeâ€™s CRM group. Configure it in Admin â†’ Group Management.",
                    )
                    return redirect("user-open-live-account")
                from btrader_integration.services import get_btrader_settings
                bt_cfg = get_btrader_settings() or {}
                server_name = (account_type.server_name or "").strip() or (bt_cfg.get("server_name") or "BTrader")
                account_label = f"Real â€” {account_type.account_name}"
            else:
                group = _resolve_real_mt5_group(account_type)
                if not group:
                    code = (account_type.account_code or "GRP").lower().replace(" ", "-")
                    group = MT5Group.objects.create(
                        crm_group_name=account_type.account_name,
                        platform=MT5Group.BrokerPlatform.MT5,
                        platform_group_name=f"{code}-default",
                        name=f"{code}-default",
                        is_active=True,
                        description="Auto-created fallback group (link a CRM group in Account Types).",
                    )
                    account_type.crm_group = group
                    account_type.save(update_fields=["crm_group", "updated_at"])
                server_name = (account_type.server_name or "").strip() or f"{account_type.platform}-Live"
                account_label = f"Real â€” {account_type.account_name}"

        mt5_login_str = account_number
        if trading_platform == "MT5":
            from mt5_integration.services import _mt5_client, is_mt5_configured
            if is_mt5_configured():
                try:
                    with _mt5_client() as client:
                        group_str = getattr(group, "platform_group_name", "") or getattr(group, "name", "")
                        full_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
                        country_val = getattr(request.user, "country", "")
                        phone_val = getattr(request.user, "phone", "")
                        new_mt5_login = client.user_add(
                            group=group_str,
                            name=full_name,
                            password=main_password,
                            investor_password=investor_password or main_password,
                            leverage=leverage_val,
                            email=request.user.email,
                            country=country_val,
                            phone=phone_val,
                        )
                        mt5_login_str = str(new_mt5_login)
                        if is_demo and opening_bal > 0:
                            try:
                                client.user_deposit_change(new_mt5_login, float(opening_bal), "Initial Deposit", deal_type=2)
                            except Exception as dep_err:
                                import logging
                                logging.getLogger(__name__).error("Failed to deposit demo balance to MT5: %s", dep_err)
                except Exception as e:
                    import logging
                    logging.getLogger(__name__).error("Failed to create MT5 account via API: %s", e)
                    err_str = str(e)
                    if "retcode 3006" in err_str:
                        messages.error(request, "Failed: Password does not meet MT5 security requirements (must contain uppercase, lowercase, and numbers).")
                    elif "retcode 8" in err_str:
                        messages.error(request, "Failed: Group not found on MT5 server. Please contact support.")
                    else:
                        messages.error(request, "Failed to create MT5 account on server. Please try again or contact support.")
                    return redirect("user-open-live-account")
            else:
                messages.error(request, "MT5 Integration is not configured. Cannot create MT5 account.")
                return redirect("user-open-live-account")
        elif trading_platform == "BTRADER":
            from btrader_integration.client import BTraderAPIError
            from btrader_integration.services import (
                create_btrader_account,
                deposit_btrader_balance,
                is_btrader_configured,
            )
            if not is_btrader_configured():
                messages.error(request, "BTrader integration is not configured. Cannot create trading account.")
                return redirect("user-open-live-account")
            try:
                group_str = getattr(group, "platform_group_name", "") or getattr(group, "name", "")
                full_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
                phone_val = getattr(request.user, "phone", "") or ""
                provisional_id = f"crm-{request.user.id}-{account_number}"
                created = create_btrader_account(
                    crm_user_id=str(request.user.id),
                    crm_account_id=provisional_id,
                    email=request.user.email or f"user{request.user.id}@crm.local",
                    name=full_name,
                    phone=phone_val,
                    password=main_password,
                    group=group_str,
                    currency=currency,
                    leverage=leverage_val,
                    is_demo=is_demo,
                )
                mt5_login_str = created["login"]
                if is_demo and opening_bal > 0:
                    try:
                        deposit_btrader_balance(
                            login=mt5_login_str,
                            amount=float(opening_bal),
                            comment="Initial demo deposit",
                            external_ref=f"crm-demo-{mt5_login_str}-{provisional_id}",
                        )
                    except Exception as dep_err:
                        import logging
                        logging.getLogger(__name__).error("Failed to deposit demo balance to BTrader: %s", dep_err)
            except BTraderAPIError as e:
                import logging
                logging.getLogger(__name__).error("Failed to create BTrader account: %s", e)
                messages.error(request, f"Failed to create BTrader account: {e}")
                return redirect("user-open-live-account")
            except Exception as e:
                import logging
                logging.getLogger(__name__).error("Failed to create BTrader account: %s", e)
                messages.error(request, "Failed to create BTrader account on server. Please try again or contact support.")
                return redirect("user-open-live-account")

        account_number = mt5_login_str

        mt5 = MT5Account(
            user=request.user,
            account_type=mt5_mode,
            login_id=account_number,
            server=server_name,
            group=group,
            leverage=leverage_val,
            account_label=account_label,
            balance=opening_bal,
            equity=opening_bal,
            free_margin=opening_bal,
            deposit_enabled=dep_ok,
            withdraw_enabled=wdr_ok,
        )
        mt5.set_mt5_password(main_password)
        mt5.set_investor_password(investor_password)
        mt5.save()

        TradingAccount.objects.create(
            user=request.user,
            account_number=account_number,
            account_type=account_label,
            leverage=leverage_val,
            currency=currency,
            status=TradingAccount.Status.ACTIVE,
            server=server_name,
            balance=opening_bal,
            mt5_account=mt5,
        )

        if is_demo:
            messages.success(
                request,
                f"{account_label} created with virtual balance {opening_bal} {currency}. Deposits, withdrawals, and transfers are not available on demo accounts.",
            )
            return redirect(f"{reverse('user-dashboard')}?tab=demo")

        messages.success(request, "Trading account created successfully.")
        my_accounts = TradingAccount.objects.filter(user=request.user).order_by("-created_at")[:20]
        return render(
            request,
            "user_portal/open_account.html",
            {
                "account_types": account_types_payload,
                "match_trader_enabled": match_trader_enabled,
                "btrader_enabled": btrader_enabled,
                "portal_currencies": sorted(PORTAL_OPEN_ACCOUNT_CURRENCIES),
                "my_accounts": my_accounts,
                "demo_settings": demo_settings,
                "demo_types_exist": demo_types_exist,
                "initial_kind": "real",
                "created_account": {
                    "account_number": account_number,
                    "login_id": account_number,
                    "main_password": main_password,
                    "investor_password": investor_password,
                    "server": server_name,
                    "leverage": leverage_val,
                    "platform": (
                        "BTrader"
                        if trading_platform == "BTRADER"
                        else ("Match-Trader" if trading_platform == "MATCH_TRADER" else "MT5")
                    ),
                },
            },
        )

    my_accounts = TradingAccount.objects.filter(user=request.user).order_by("-created_at")[:20]
    return render(
        request,
        "user_portal/open_account.html",
        {
            "account_types": account_types_payload,
            "match_trader_enabled": match_trader_enabled,
            "btrader_enabled": btrader_enabled,
            "portal_currencies": sorted(PORTAL_OPEN_ACCOUNT_CURRENCIES),
            "my_accounts": my_accounts,
            "demo_settings": demo_settings,
            "demo_types_exist": demo_types_exist,
            "initial_kind": initial_kind,
        },
    )


@login_required
@role_required(PORTAL_ROLES)
def open_demo_account(request):
    """Legacy URL: demo opening uses the same flow as live (unified layout)."""
    return redirect(f"{reverse('user-open-live-account')}?kind=demo")


@login_required
@role_required(PORTAL_ROLES)
@require_http_methods(["POST"])
def demo_balance_action(request, login_id: str):
    """
    Compatibility endpoint used by legacy demo account actions.
    Safely updates the current user's demo balance and returns to account history.
    """
    mt5 = MT5Account.objects.filter(
        user=request.user,
        login_id=str(login_id),
        account_type=MT5Account.AccountType.DEMO,
    ).first()
    if not mt5:
        messages.error(request, "Demo account not found.")
        return redirect("user-account-history")

    action = (request.POST.get("action") or "").strip().lower()
    current = Decimal(str(mt5.balance or 0))
    if action == "reset":
        demo_settings = DemoAccountSettings.get_solo()
        reset_to = Decimal(str(request.POST.get("amount") or demo_settings.default_balance or 10000))
        if reset_to < 0:
            reset_to = Decimal("0")
        mt5.balance = reset_to
    else:
        try:
            amount = Decimal(str(request.POST.get("amount") or "0"))
        except Exception:
            amount = Decimal("0")
        if amount <= 0:
            messages.error(request, "Enter a valid amount.")
            return redirect("/user/dashboard/?tab=demo")
        if action in {"withdraw", "debit", "remove"}:
            if amount > current:
                messages.error(request, "Insufficient demo balance.")
                return redirect("/user/dashboard/?tab=demo")
            mt5.balance = current - amount
        else:
            mt5.balance = current + amount
    mt5.equity = mt5.balance
    mt5.free_margin = mt5.balance
    mt5.save(update_fields=["balance", "equity", "free_margin", "updated_at"])
    TradingAccount.objects.filter(mt5_account=mt5).update(balance=mt5.balance, updated_at=timezone.now())
    messages.success(request, "Demo balance updated.")
    return redirect("/user/dashboard/?tab=demo")


@login_required
@role_required(PORTAL_ROLES)
def transaction_history(request):
    qs = Transaction.objects.filter(
        (Q(actor=request.user) | Q(from_user=request.user) | Q(to_user=request.user)) & real_ledger_q()
    ).order_by("-created_at")
    return render(request, "user_portal/transaction_history.html", {"transactions": qs})


@login_required
@role_required(PORTAL_ROLES)
def account_history(request):
    accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
    return render(request, "user_portal/account_history.html", {"accounts": accounts, "title": "Account History"})


@login_required
@role_required(PORTAL_ROLES)
def referral_link(request):
    prof = IBProfile.objects.filter(user=request.user).first()
    if not prof or request.user.role != User.Roles.IB:
        messages.info(request, "Referral link is available after you are approved as an IB.")
        return redirect("user-ib-dashboard")
    referral_url = (
        build_register_referral_url(request, prof.ib_code) if (prof.ib_code or "").strip() else (prof.referral_link or "")
    )
    return render(request, "user_portal/referral_link.html", {"referral_url": referral_url, "title": "Referral Link"})


@login_required
@role_required(PORTAL_ROLES)
def placeholder_page(request, title: str):
    return render(request, "user_portal/placeholder.html", {"title": title})

