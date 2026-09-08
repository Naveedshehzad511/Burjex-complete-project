from __future__ import annotations

from decimal import Decimal

from django.db.models import Sum
from rest_framework.views import APIView

from admin_panel.models import DashboardSettings, TradingAccount, WalletTreasurySettings
from api.permissions import IsAuthenticatedClient
from api.responses import success_response
from api.services.treasury_service import list_user_transactions, wallet_summary
from transactions.models import Transaction
from transactions.real_ledger import filter_real_ledger_transactions
from user_portal.views import _fmt_money_2, _ib_wallet_balance_for_user, _sum_mt5_decimal, _wallet_balance_for_user


def _platform_for_trading_account(a: TradingAccount) -> str:
    mt5 = a.mt5_account
    if mt5 and getattr(mt5, "group", None) and getattr(mt5.group, "platform", None):
        return str(mt5.group.platform).upper()
    blob = f"{a.account_type or ''} {a.server or ''}".lower()
    if "btrader" in blob:
        return "BTRADER"
    if "match" in blob:
        return "MATCH_TRADER"
    return "MT5"


def _serialize_trading_account(a: TradingAccount) -> dict:
    mt5 = a.mt5_account
    base = (a.base_account_type or "LIVE").upper()
    platform = _platform_for_trading_account(a)
    return {
        "id": a.id,
        "account_number": a.account_number,
        "login_id": (mt5.login_id if mt5 else a.account_number) or a.account_number,
        "account_type": a.account_type,
        "base_account_type": base,
        "leverage": a.leverage,
        "currency": a.currency,
        "balance": str(mt5.balance if mt5 else a.balance),
        "equity": str(mt5.equity if mt5 else a.balance),
        "credit": str(a.credit),
        "free_margin": str(mt5.free_margin if mt5 else 0),
        "unrealized_pnl": str(a.unrealized_pnl),
        "status": a.status,
        "server": a.server,
        "platform": platform,
        "is_demo": base == "DEMO",
        "deposit_enabled": bool(mt5.deposit_enabled) if mt5 else True,
        "withdraw_enabled": bool(mt5.withdraw_enabled) if mt5 else True,
        "trading_enabled": bool(mt5.trading_enabled) if mt5 else True,
        "created_at": a.created_at.isoformat() if a.created_at else None,
    }


class ClientDashboardAPIView(APIView):
    """JSON equivalent of user_portal dashboard metrics (same calculations)."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        settings_obj = DashboardSettings.get_solo()
        ws_treasury = WalletTreasurySettings.get_solo()
        wallet_only_withdrawal_ui = bool(
            ws_treasury.wallet_system_enabled and settings_obj.enforce_wallet_only_withdrawal
        )
        tab = (request.query_params.get("tab") or "real").lower()
        if tab not in ("real", "demo"):
            tab = "real"

        user = request.user
        user.refresh_from_db(fields=["wallet_balance", "pending_withdraw"])
        # Live-pull BTrader balance/equity before serializing Home account list.
        try:
            from btrader_integration.services import is_btrader_configured, sync_user_btrader_accounts

            if is_btrader_configured():
                sync_user_btrader_accounts(user)
        except Exception:
            # Never block dashboard if engine is briefly unreachable — serve last snapshot.
            pass
        wallet_balance = _wallet_balance_for_user(user)
        ib_balance = _ib_wallet_balance_for_user(user)
        reserved_withdraw = Decimal(str(user.pending_withdraw or 0))
        wallet_available_after_reservations = max(Decimal("0"), wallet_balance - reserved_withdraw)

        total_deposit = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=user,
                    tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )
        pending_withdraw = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=user,
                    tx_type__in=[
                        Transaction.TxType.CLIENT_WITHDRAW,
                        Transaction.TxType.WALLET_WITHDRAW,
                        Transaction.TxType.PENDING_WITHDRAW,
                    ],
                    status=Transaction.Status.PENDING,
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )

        mt5_qs = (
            TradingAccount.objects.filter(user=user)
            .select_related("mt5_account", "mt5_account__group")
            .order_by("-created_at")
        )
        live_qs = [a for a in mt5_qs if a.base_account_type == "LIVE"]
        demo_qs = [a for a in mt5_qs if a.base_account_type == "DEMO"]
        sum_live_bal_all = sum(
            (Decimal(str(a.mt5_account.balance if a.mt5_account else a.balance or 0)) for a in live_qs),
            start=Decimal("0"),
        )
        sum_demo_bal_all = sum(
            (Decimal(str(a.mt5_account.balance if a.mt5_account else a.balance or 0)) for a in demo_qs),
            start=Decimal("0"),
        )

        accounts = list(mt5_qs[:48])
        live_rows = [a for a in accounts if a.base_account_type == "LIVE"]
        demo_rows = [a for a in accounts if a.base_account_type == "DEMO"]
        avail_real = max(Decimal("0"), _sum_mt5_decimal(live_rows, "free_margin"))
        withdraw_metric_real = (
            _fmt_money_2(wallet_available_after_reservations)
            if wallet_only_withdrawal_ui
            else _fmt_money_2(avail_real)
        )
        def _tab_block(rows, total_bal, withdraw_metric: str) -> dict:
            free_m = _sum_mt5_decimal(rows, "free_margin")
            credit = _sum_mt5_decimal(rows, "credit")
            pnl = _sum_mt5_decimal(rows, "unrealized_pnl")
            # Same margin estimate as user_portal.dashboard (equity - free_margin per row).
            used_margin = Decimal("0")
            for a in rows:
                mt5 = a.mt5_account
                if mt5:
                    used_margin += Decimal(str(mt5.equity or 0)) - Decimal(str(mt5.free_margin or 0))
                else:
                    used_margin += max(Decimal("0"), Decimal(str(a.balance or 0)) - Decimal("0"))
            return {
                "total_balance": _fmt_money_2(total_bal),
                "available_to_withdraw": withdraw_metric,
                "total_credit": _fmt_money_2(credit),
                "open_pnl": _fmt_money_2(pnl),
                "total_equity": _fmt_money_2(total_bal + pnl),
                "free_margin": _fmt_money_2(free_m),
                "margin": _fmt_money_2(max(Decimal("0"), used_margin)),
                "wallet_balance": _fmt_money_2(wallet_balance),
                "wallet_available": _fmt_money_2(wallet_available_after_reservations),
            }

        tab_metrics = {
            "real": _tab_block(live_rows, sum_live_bal_all, withdraw_metric_real),
            "demo": _tab_block(demo_rows, sum_demo_bal_all, "0.00"),
        }
        sel = tab_metrics["demo" if tab == "demo" else "real"]

        return success_response(
            {
                "tab": tab,
                "wallet": wallet_summary(user),
                "ib_balance": str(ib_balance),
                "total_deposits": str(total_deposit),
                "pending_withdrawals": str(pending_withdraw),
                "metrics": sel,
                "tab_metrics": tab_metrics,
                "live_accounts_count": len(live_qs),
                "demo_accounts_count": len(demo_qs),
                "accounts": [_serialize_trading_account(a) for a in accounts],
                "recent_transactions": list_user_transactions(user, limit=8),
                "wallet_only_withdrawal": wallet_only_withdrawal_ui,
                "user": {
                    "id": user.id,
                    "email": user.email,
                    "display_name": user.display_name(),
                    "first_name": user.first_name,
                    "last_name": user.last_name,
                },
            },
            message="Dashboard retrieved successfully.",
        )
