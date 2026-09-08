"""
Shared balance movements for internal transfers (client instant + admin manual approval).
"""

from decimal import Decimal
from typing import Optional

from django.db.models import Sum

from admin_panel.models import TradingAccount
from transactions.models import BalanceLedger, InternalTransfer, Transaction
from mt5_integration.services import mt5_balance_withdrawal, mt5_balance_deposit
import logging

logger = logging.getLogger(__name__)

def validate_internal_transfer_route(transfer_type: str, from_account: str, to_account: str) -> Optional[str]:
    """
    Ensure from/to match the declared transfer type. Blocks bogus destinations (e.g. direct withdrawal).
    """
    tt = InternalTransfer.TransferType
    fa = (from_account or "").strip()
    ta = (to_account or "").strip()
    if ta != "WALLET" and not ta.startswith("TRADING:"):
        return (
            "Transfers to withdrawal or unsupported destinations are not allowed. "
            "Move funds to your Wallet first, then request a withdrawal."
        )
    if fa not in ("WALLET", "IB_WALLET") and not fa.startswith("TRADING:"):
        return "Invalid source account."
    if transfer_type == tt.WALLET_TO_TRADING:
        if fa != "WALLET" or not ta.startswith("TRADING:"):
            return "Invalid accounts for Wallet → Trading transfer."
    elif transfer_type == tt.TRADING_TO_WALLET:
        if not fa.startswith("TRADING:") or ta != "WALLET":
            return "Invalid accounts for Trading → Wallet transfer."
    elif transfer_type == tt.TRADING_TO_TRADING:
        if not fa.startswith("TRADING:") or not ta.startswith("TRADING:"):
            return "Invalid accounts for Trading → Trading transfer."
        if fa == ta:
            return "Source and destination trading accounts must differ."
    elif transfer_type == tt.IB_TO_TRADING:
        if fa != "IB_WALLET" or not ta.startswith("TRADING:"):
            return "Invalid accounts for IB Wallet → Trading transfer."
    elif transfer_type == tt.IB_TO_WALLET:
        if fa != "IB_WALLET" or ta != "WALLET":
            return (
                "IB commission can only be moved to your Wallet first. "
                "Withdrawals are processed from Wallet only."
            )
    else:
        return "Unknown transfer type."
    return None


def _ib_wallet_balance(user) -> Decimal:
    """
    Available IB commission = credits − approved IB→* transfers − pending/approved IB withdraws.
    Must match portal `_ib_wallet_balance_for_user` so transfers cannot spend reserved IB cash.
    """
    ib_credit = (
        Transaction.objects.filter(
            actor=user,
            tx_type=Transaction.TxType.IB_WITHDRAW,
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    ib_transfer_out = (
        InternalTransfer.objects.filter(
            user=user,
            status=InternalTransfer.Status.APPROVED,
            from_account="IB_WALLET",
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    ib_withdraw_out = (
        Transaction.objects.filter(
            actor=user,
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
            status__in=[
                Transaction.Status.PENDING,
                Transaction.Status.APPROVED,
                Transaction.Status.COMPLETED,
            ],
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    return (
        Decimal(str(ib_credit or 0))
        - Decimal(str(ib_transfer_out or 0))
        - Decimal(str(ib_withdraw_out or 0))
    )


def apply_internal_transfer_balances(
    locked_user,
    *,
    transfer_type: str,
    from_account: str,
    to_account: str,
    amount: Decimal,
    request_uid: str,
) -> Optional[str]:
    """
    Apply wallet / trading ledger movements for one internal transfer.
    Returns None on success, or a user-facing error string.
    """
    route_err = validate_internal_transfer_route(transfer_type, from_account, to_account)
    if route_err:
        return route_err

    trading_locked = TradingAccount.objects.select_for_update().filter(
        user=locked_user,
        status=TradingAccount.Status.ACTIVE,
    )
    ta_map = {str(a.id): a for a in trading_locked}

    if from_account == "WALLET":
        wb = Decimal(str(locked_user.wallet_balance or 0))
        pw = Decimal(str(locked_user.pending_withdraw or 0))
        # Hold funds already requested as pending wallet→* transfers (manual approval queue).
        pending_wallet_out = (
            InternalTransfer.objects.select_for_update()
            .filter(
                user=locked_user,
                from_account="WALLET",
                status=InternalTransfer.Status.PENDING,
            )
            .aggregate(total=Sum("amount"))["total"]
            or 0
        )
        available = wb - pw - Decimal(str(pending_wallet_out))
        if amount <= 0:
            return "Transfer amount must be greater than zero."
        if available < amount:
            return (
                "Insufficient wallet balance for this transfer. "
                "Pending withdrawals and pending transfers reduce available funds."
            )
        wallet_before = wb
        locked_user.wallet_balance = wallet_before - amount
        if locked_user.wallet_balance < 0:
            return "Negative balance is not allowed."
        locked_user.save(update_fields=["wallet_balance"])
        BalanceLedger.objects.create(
            user=locked_user,
            entry_type=BalanceLedger.EntryType.TRANSFER_DEBIT,
            amount=amount,
            wallet_before=wallet_before,
            wallet_after=locked_user.wallet_balance,
            pending_before=Decimal(str(locked_user.pending_withdraw or 0)),
            pending_after=Decimal(str(locked_user.pending_withdraw or 0)),
            reference=request_uid,
            note=f"Debit from wallet to {to_account}",
        )

    elif from_account == "IB_WALLET":
        if _ib_wallet_balance(locked_user) < amount:
            return "Insufficient IB wallet balance."

    elif from_account.startswith("TRADING:"):
        from_id = from_account.split(":", 1)[1]
        src = ta_map.get(from_id)
        if not src:
            return "Invalid source trading account."
        if not src.mt5_account:
            return "Invalid source trading account."

        # Live free-margin / equity guard (BTrader + MT5).
        from btrader_integration.services import (
            is_btrader_account_row,
            validate_trading_debit_amount,
            withdraw_btrader_balance,
        )

        debit_err = validate_trading_debit_amount(src, amount)
        if debit_err:
            return debit_err
        src.refresh_from_db()
        if src.mt5_account_id:
            src.mt5_account.refresh_from_db()

        login = str(src.mt5_account.login_id or src.account_number)
        if is_btrader_account_row(trading_account=src):
            try:
                withdraw_btrader_balance(
                    login=login,
                    amount=float(amount),
                    comment=f"CRM Transfer {request_uid[:8]}",
                    external_ref=f"crm-xfer-out-{request_uid}",
                )
            except Exception as e:
                logger.error("BTrader withdrawal failed during internal transfer %s: %s", request_uid, e)
                return "Failed to withdraw funds from BTrader trading account."
        else:
            if Decimal(str(src.balance or 0)) < amount and Decimal(str(src.mt5_account.balance or 0)) < amount:
                return "Insufficient balance for selected source."
            try:
                mt5_balance_withdrawal(
                    int(src.mt5_account.login_id),
                    float(amount),
                    comment=f"CRM Transfer {request_uid[:8]}",
                )
            except Exception as e:
                logger.error("MT5 withdrawal failed during internal transfer %s: %s", request_uid, e)
                return "Failed to withdraw funds from MT5 trading account."

        # Prefer engine-synced snapshot; if sync lagged, apply local debit so CRM matches.
        src.refresh_from_db()
        before = Decimal(str(src.balance or 0))
        if src.mt5_account_id:
            src.mt5_account.refresh_from_db()
            synced = Decimal(str(src.mt5_account.balance or 0))
            # Synced value should drop after withdraw; if unchanged, debit locally.
            if synced < before:
                src.balance = synced
            else:
                src.balance = before - amount
                src.mt5_account.balance = src.balance
                src.mt5_account.equity = max(
                    Decimal("0"),
                    Decimal(str(src.mt5_account.equity or before)) - amount,
                )
                src.mt5_account.free_margin = max(
                    Decimal("0"),
                    Decimal(str(src.mt5_account.free_margin or before)) - amount,
                )
                src.mt5_account.save(
                    update_fields=["balance", "equity", "free_margin", "updated_at"]
                )
        else:
            src.balance = before - amount
        if src.balance < 0:
            return "Negative balance is not allowed."
        src.save(update_fields=["balance", "updated_at"])
        if src.mt5_account and not is_btrader_account_row(trading_account=src):
            src.mt5_account.balance = src.balance
            src.mt5_account.save(update_fields=["balance", "updated_at"])
    else:
        return "Invalid source account."

    if to_account.startswith("TRADING:"):
        to_id = to_account.split(":", 1)[1]
        dst = ta_map.get(to_id)
        if not dst:
            return "Invalid destination trading account."
        if not dst.mt5_account:
            return "Invalid destination trading account."

        from btrader_integration.services import deposit_btrader_balance, is_btrader_account_row

        login = str(dst.mt5_account.login_id or dst.account_number)
        if is_btrader_account_row(trading_account=dst):
            try:
                deposit_btrader_balance(
                    login=login,
                    amount=float(amount),
                    comment=f"CRM Transfer {request_uid[:8]}",
                    external_ref=f"crm-xfer-in-{request_uid}",
                )
            except Exception as e:
                logger.error("BTrader deposit failed during internal transfer %s: %s", request_uid, e)
                return "Failed to deposit funds to BTrader trading account."
            dst.refresh_from_db()
            if dst.mt5_account_id:
                dst.mt5_account.refresh_from_db()
                dst.balance = Decimal(str(dst.mt5_account.balance or 0))
            else:
                dst.balance = Decimal(str(dst.balance or 0)) + amount
        else:
            try:
                mt5_balance_deposit(
                    int(dst.mt5_account.login_id),
                    float(amount),
                    comment=f"CRM Transfer {request_uid[:8]}",
                )
            except Exception as e:
                logger.error("MT5 deposit failed during internal transfer %s: %s", request_uid, e)
                return "Failed to deposit funds to MT5 trading account."
            dst.balance = Decimal(str(dst.balance or 0)) + amount
            if dst.mt5_account:
                dst.mt5_account.balance = dst.balance
                dst.mt5_account.save(update_fields=["balance", "updated_at"])

        dst.save(update_fields=["balance", "updated_at"])

    if to_account == "WALLET":
        wallet_before = Decimal(str(locked_user.wallet_balance or 0))
        locked_user.wallet_balance = wallet_before + amount
        locked_user.save(update_fields=["wallet_balance"])
        BalanceLedger.objects.create(
            user=locked_user,
            entry_type=BalanceLedger.EntryType.TRANSFER_CREDIT,
            amount=amount,
            wallet_before=wallet_before,
            wallet_after=locked_user.wallet_balance,
            pending_before=Decimal(str(locked_user.pending_withdraw or 0)),
            pending_after=Decimal(str(locked_user.pending_withdraw or 0)),
            reference=request_uid,
            note=f"Credit to wallet from {from_account}",
        )
    elif not to_account.startswith("TRADING:"):
        return "Invalid destination account."

    return None
