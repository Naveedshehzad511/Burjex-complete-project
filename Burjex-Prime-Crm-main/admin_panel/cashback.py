"""Trader cashback: flat $ per client alias on BTrader full close, keyed by engine trade id.

Not IB/referral. Credits the trader's own CRM wallet at the CRM-set alias rate.
"""

from __future__ import annotations

import logging
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from django.db import IntegrityError, transaction as db_transaction
from django.db.models import F

from accounts.models import MT5Account, User
from admin_panel.models import CashbackPayout, CashbackRate
from transactions.models import Transaction

logger = logging.getLogger(__name__)

_ZERO = Decimal("0")
_CENT = Decimal("0.01")


def _dec(value, default="0") -> Decimal:
    try:
        if value is None or value == "":
            return Decimal(default)
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return Decimal(default)


def _truthy(value) -> bool:
    if value is True:
        return True
    if value is False or value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "y"}


def resolve_cashback_rate(alias: str) -> Decimal:
    name = (alias or "").strip()
    if not name:
        return _ZERO
    row = CashbackRate.objects.filter(alias__iexact=name).first()
    if not row:
        return _ZERO
    rate = _dec(row.amount_usd)
    return rate if rate > 0 else _ZERO


def credit_cashback_on_close(
    *,
    login: str,
    engine_trade_id: str,
    alias: str,
    deal_id: str = "",
    partial=None,
) -> dict:
    """
    Credit the trader (not an IB) when a BTrader position fully closes.

    Idempotent on engine_trade_id (position / engine trade id). Amount is the
    CRM-set $ for that client alias. Demo accounts and partial closes are skipped.
    """
    login_s = str(login or "").strip()
    trade_s = str(engine_trade_id or "").strip()
    alias_s = (alias or "").strip()
    deal_s = str(deal_id or "").strip()
    if not login_s or not trade_s or not alias_s:
        return {"credited": False, "reason": "missing_fields"}
    if _truthy(partial):
        return {"credited": False, "reason": "partial"}

    if CashbackPayout.objects.filter(engine_trade_id=trade_s).exists():
        return {"credited": False, "reason": "duplicate"}

    mt5 = MT5Account.objects.select_related("user").filter(login_id=login_s).first()
    if not mt5 or not mt5.user_id:
        return {"credited": False, "reason": "unknown_login"}
    if mt5.account_type == MT5Account.AccountType.DEMO:
        return {"credited": False, "reason": "demo"}

    client = mt5.user
    rate = resolve_cashback_rate(alias_s)
    if rate <= 0:
        return {"credited": False, "reason": "no_rate"}

    payout = rate.quantize(_CENT, rounding=ROUND_HALF_UP)
    if payout <= 0:
        return {"credited": False, "reason": "zero_payout"}

    try:
        with db_transaction.atomic():
            CashbackPayout.objects.create(
                engine_trade_id=trade_s[:64],
                deal_id=deal_s[:64],
                user=client,
                login_id=login_s[:64],
                alias=alias_s[:64],
                amount=payout,
            )
            locked = User.objects.select_for_update().get(pk=client.pk)
            locked.wallet_balance = F("wallet_balance") + payout
            locked.save(update_fields=["wallet_balance"])
            Transaction.objects.create(
                tx_type=Transaction.TxType.CASHBACK,
                status=Transaction.Status.COMPLETED,
                actor=client,
                to_user=client,
                amount=payout,
                currency="USD",
                reference=f"CB_{trade_s}"[:200],
                notes=f"Cashback | trade={trade_s} alias={alias_s} amount={payout}",
            )
    except IntegrityError:
        return {"credited": False, "reason": "duplicate"}

    logger.info(
        "Cashback credited trade=%s login=%s alias=%s amount=%s user=%s",
        trade_s,
        login_s,
        alias_s,
        payout,
        client.id,
    )
    return {
        "credited": True,
        "amount": str(payout),
        "user_id": client.id,
        "engine_trade_id": trade_s,
        "alias": alias_s,
        "rate": str(rate),
    }
