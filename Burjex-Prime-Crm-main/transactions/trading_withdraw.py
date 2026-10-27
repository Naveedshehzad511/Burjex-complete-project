"""Withdrawals taken directly from a live trading account (instead of the wallet).

Off by default (`WalletTreasurySettings.allow_direct_trading_withdraw`); with the setting off nothing
in this module is reached and withdrawals stay wallet-only.

Ledger of record for a trading-account withdrawal:

* request   - a PENDING `Transaction` (CLIENT_WITHDRAW) with `trading_account` set. The wallet is
              not touched: `User.pending_withdraw` is wallet-only and is deliberately left alone.
              The amount is RESERVED in the trading engine (`reserve`, reference
              `crm-withdraw-reserve-<tx id>`) in the same step: the engine then keeps it out of new
              trades and triggered pending orders until the request is settled. If the reservation
              is refused no request is created.
* approval  - the BTrader WITHDRAWAL balance operation (`externalRef = crm-withdraw-<tx id>`) that
              also finalizes the reservation in the same transaction, so the amount is debited once
              and never counted twice, then the transaction is marked APPROVED. The engine ignores a
              repeated `externalRef`, so a retry or a double click cannot debit the account twice.
* rejection - the reservation is released (exactly once), then the request is marked REJECTED. If the
              release cannot be done the request stays PENDING and can be rejected again.
"""

from __future__ import annotations

import logging
from decimal import Decimal
from typing import Optional

from django.db.models import Sum
from django.utils import timezone

from accounts.models import MT5Account
from admin_panel.models import TradingAccount, WalletTreasurySettings
from transactions.models import Transaction

logger = logging.getLogger(__name__)

SOURCE_PREFIX = "TRADING:"


def direct_withdraw_enabled() -> bool:
    return bool(WalletTreasurySettings.get_solo().allow_direct_trading_withdraw)


def is_trading_source(withdraw_from: str) -> bool:
    """True when `withdraw_from` names a trading account (anything but the wallet)."""
    return (withdraw_from or "").strip().lower() not in ("", "wallet")


def parse_source_id(withdraw_from: str) -> Optional[int]:
    """`TRADING:<id>` (or a bare id) -> the TradingAccount primary key, else None."""
    raw = (withdraw_from or "").strip()
    if raw.upper().startswith(SOURCE_PREFIX):
        raw = raw[len(SOURCE_PREFIX):]
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def _is_eligible(account: TradingAccount) -> bool:
    from btrader_integration.services import is_btrader_account_row

    mt5 = account.mt5_account
    return (
        mt5 is not None
        and account.status == TradingAccount.Status.ACTIVE
        and mt5.account_type == MT5Account.AccountType.LIVE
        and is_btrader_account_row(trading_account=account)
    )


def eligible_accounts(user) -> list[TradingAccount]:
    """The user's live, active BTrader accounts: the only ones a withdrawal may be taken from."""
    rows = (
        TradingAccount.objects.filter(
            user=user,
            status=TradingAccount.Status.ACTIVE,
            mt5_account__account_type=MT5Account.AccountType.LIVE,
        )
        .select_related("mt5_account", "mt5_account__group")
        .order_by("-created_at")
    )
    return [a for a in rows if _is_eligible(a)]


def resolve_source(user, withdraw_from: str, *, lock: bool = False) -> Optional[TradingAccount]:
    """The account the request names, only if it belongs to `user` and is eligible. Never trusts
    anything but the id: ownership, status and live/BTrader checks all run server-side."""
    pk = parse_source_id(withdraw_from)
    if pk is None:
        return None
    qs = TradingAccount.objects.select_related("mt5_account", "mt5_account__group")
    if lock:
        qs = qs.select_for_update(of=("self",))
    account = qs.filter(id=pk, user=user).first()
    if account is None or not _is_eligible(account):
        return None
    return account


def pending_requested(account: TradingAccount) -> Decimal:
    """Total of PENDING withdrawal requests already made against this account."""
    total = Transaction.objects.filter(
        trading_account=account,
        tx_type=Transaction.TxType.CLIENT_WITHDRAW,
        status=Transaction.Status.PENDING,
    ).aggregate(s=Sum("amount"))["s"]
    return Decimal(str(total or 0))


INSUFFICIENT_MESSAGE = (
    "Insufficient available funds on the selected trading account "
    "(open positions and pending withdrawal requests reduce what can be withdrawn)."
)


def reservation_ref(tx: Transaction) -> str:
    """The engine-side reference of this request's reservation (one per request, so every step is idempotent)."""
    return f"crm-withdraw-reserve-{tx.id}"


def reserve(account: TradingAccount, amount: Decimal, ref: str) -> tuple[bool, str]:
    """Hold `amount` in the trading engine for a new request. (ok, message-for-the-client)."""
    from btrader_integration.services import reserve_btrader_withdrawal

    try:
        reserve_btrader_withdrawal(login=account_login(account), amount=float(amount), external_ref=ref)
    except Exception as exc:
        if "insufficient" in str(exc).lower():
            return False, INSUFFICIENT_MESSAGE
        logger.warning("Withdrawal reservation %s could not be made: %s", ref, exc)
        return False, "Unable to reserve the funds for this withdrawal right now. Please retry."
    return True, ""


def release(account: TradingAccount, ref: str) -> tuple[Optional[str], str]:
    """Give a reservation back. (engine state, error): the state is RELEASED / FINALIZED / NONE, or None with the
    error text when the engine could not be reached (nothing is known then; releasing again is always safe)."""
    from btrader_integration.services import release_btrader_withdrawal

    try:
        res = release_btrader_withdrawal(login=account_login(account), external_ref=ref)
    except Exception as exc:
        logger.warning("Withdrawal reservation %s could not be released: %s", ref, exc)
        return None, str(exc)[:300]
    return str((res or {}).get("status") or "NONE").upper(), ""


def account_login(account: TradingAccount) -> str:
    mt5 = account.mt5_account
    return str((mt5.login_id if mt5 else None) or account.account_number)


def live_allowed(account: TradingAccount) -> tuple[Optional[Decimal], dict, str]:
    """(withdrawable now, live snapshot, error): the live min(balance, free margin, equity).
    Credit / bonus is not withdrawable and open positions reduce free margin."""
    from btrader_integration.services import is_btrader_configured, live_withdrawable

    if not is_btrader_configured():
        return None, {}, "BTrader integration is not configured."
    allowed, snapshot, err = live_withdrawable(account_login(account))
    if err or allowed is None:
        return None, {}, err or "Unable to read the live account balance."
    return allowed, snapshot or {}, ""


def available_now(account: TradingAccount) -> tuple[Optional[Decimal], dict, str]:
    """`live_allowed` less this account's other pending requests; never below zero."""
    allowed, snapshot, err = live_allowed(account)
    if allowed is None:
        return None, {}, err
    return max(Decimal("0"), allowed - pending_requested(account)), snapshot, ""


def source_label(account: Optional[TradingAccount]) -> str:
    if account is None:
        return "Wallet"
    return f"Trading account {account_login(account)}"


def approve(tx: Transaction, admin_user) -> tuple[bool, str]:
    """Debit the trading account for an approved withdrawal and mark it APPROVED.

    Call with `tx` locked (select_for_update) inside a database transaction and still PENDING.
    On any failure the request stays PENDING so it can be retried; the engine's externalRef
    idempotency makes the retry safe even if a previous attempt already moved the money.
    """
    from btrader_integration.services import is_btrader_configured, withdraw_btrader_balance

    account = (
        TradingAccount.objects.select_for_update(of=("self",))
        .select_related("mt5_account", "mt5_account__group")
        .filter(id=tx.trading_account_id)
        .first()
    )
    if account is None or account.user_id != tx.actor_id or not _is_eligible(account):
        return False, "Cannot approve: the source trading account is missing, disabled or not a live account of this client."
    if not is_btrader_configured():
        return False, "Cannot approve: BTrader integration is not configured."

    amount = Decimal(str(tx.amount or 0))
    if amount <= 0:
        return False, "Cannot approve: invalid amount."
    try:
        withdraw_btrader_balance(
            login=account_login(account),
            amount=float(amount),
            comment=f"CRM withdrawal #{tx.id}",
            external_ref=f"crm-withdraw-{tx.id}",
            reservation_ref=reservation_ref(tx),
        )
    except Exception as exc:
        logger.warning("Trading-account withdrawal #%s not debited: %s", tx.id, exc)
        return False, f"Cannot approve: the trading account could not be debited ({str(exc)[:300]}). The request stays pending."

    tx.status = Transaction.Status.APPROVED
    tx.processed_at = timezone.now()
    tx.processed_by = admin_user
    tx.save(update_fields=["status", "processed_at", "processed_by"])
    return True, f"Approved withdraw #{tx.id}; {amount} debited from trading account {account_login(account)}."


def reject(tx: Transaction, admin_user, reason: str) -> tuple[bool, str]:
    """Reject a trading-account withdrawal: release its reservation first, then close the request.

    The release is exactly-once on the engine side, so a retry after any failure is safe. If it cannot be done
    (the engine is unreachable) the request stays PENDING - the funds are still held and consistent - and the
    admin can reject again. A request whose payout was already made is not rejected."""
    account = tx.trading_account
    if account is not None:
        state, err = release(account, reservation_ref(tx))
        if state is None:
            return False, f"Cannot reject: the reserved funds could not be released ({err}). The request stays pending; please try again."
        if state == "FINALIZED":
            return False, "Cannot reject: this withdrawal was already paid out from the trading account. Approve it to complete the record."
    tx.status = Transaction.Status.REJECTED
    tx.reject_reason = reason
    tx.processed_at = timezone.now()
    tx.processed_by = admin_user
    tx.save(update_fields=["status", "reject_reason", "processed_at", "processed_by"])
    return True, f"Rejected withdraw #{tx.id}."

