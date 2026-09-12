"""BTrader IB rebates: $ per 1.00 standard lot on engine close, keyed by trade/deal id.

MT5 rebate sync is unchanged (ib.services.sync_mt5_deals_and_calculate_rebates).
"""

from __future__ import annotations

import logging
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from django.db import IntegrityError, transaction as db_transaction

from accounts.models import MT5Account, User
from ib.models import IBCommissionMatrixRule, IBProfile, IBRequest, ProcessedBTraderDeal
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


def resolve_btrader_rebate_per_lot(*, ib_user: User, symbol: str) -> Decimal:
    """Return $ paid to the IB for 1.00 lot on this BTrader symbol, else 0."""
    name = (symbol or "").strip()
    if not ib_user or not name:
        return _ZERO
    qs = IBCommissionMatrixRule.objects.filter(
        is_active=True,
        platform=IBCommissionMatrixRule.Platform.BTRADER,
        commission_mode=IBCommissionMatrixRule.CommissionMode.FIXED_PER_LOT,
        matrix_symbol_name__iexact=name,
    )
    profile = IBProfile.objects.filter(user=ib_user).select_related("ib_level").first()
    if profile and profile.ib_level_id:
        qs = qs.filter(ib_level_id=profile.ib_level_id)
    row = qs.order_by("-priority", "-id").first()
    if not row:
        return _ZERO
    rate = _dec(row.value)
    return rate if rate > 0 else _ZERO


def credit_btrader_close(
    *,
    login: str,
    deal_id: str,
    symbol: str,
    lots,
    position_id: str = "",
) -> dict:
    """
    Credit the referring IB when a BTrader trade closes.

    Idempotent on deal_id (engine trade id). Payout = rebate_per_lot * lots
    (example: $5 / 1.00 lot → 0.10 lot = $0.50). Demo accounts are skipped.
    """
    login_s = str(login or "").strip()
    deal_s = str(deal_id or "").strip()
    symbol_s = (symbol or "").strip()
    lots_d = _dec(lots)
    if not login_s or not deal_s or not symbol_s or lots_d <= 0:
        return {"credited": False, "reason": "missing_fields"}

    if ProcessedBTraderDeal.objects.filter(deal_id=deal_s).exists():
        return {"credited": False, "reason": "duplicate"}

    mt5 = MT5Account.objects.select_related("user").filter(login_id=login_s).first()
    if not mt5 or not mt5.user_id:
        return {"credited": False, "reason": "unknown_login"}
    if mt5.account_type == MT5Account.AccountType.DEMO:
        return {"credited": False, "reason": "demo"}

    client = mt5.user
    link = (
        IBRequest.objects.filter(client_user=client, status=IBRequest.Status.APPROVED)
        .select_related("ib_user")
        .order_by("-processed_at", "-requested_at")
        .first()
    )
    if not link or not link.ib_user_id:
        return {"credited": False, "reason": "no_ib"}
    if link.ib_user_id == client.id:
        return {"credited": False, "reason": "self"}

    ib_user = link.ib_user
    rate = resolve_btrader_rebate_per_lot(ib_user=ib_user, symbol=symbol_s)
    if rate <= 0:
        return {"credited": False, "reason": "no_rule"}

    payout = (rate * lots_d).quantize(_CENT, rounding=ROUND_HALF_UP)
    if payout <= 0:
        return {"credited": False, "reason": "zero_payout"}

    try:
        with db_transaction.atomic():
            ProcessedBTraderDeal.objects.create(
                deal_id=deal_s,
                position_id=str(position_id or "")[:64],
                login_id=login_s[:64],
                symbol=symbol_s[:64],
                volume_lots=lots_d,
                rebate_per_lot=rate,
                rebate_amount=payout,
                ib_user=ib_user,
            )
            Transaction.objects.create(
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status=Transaction.Status.COMPLETED,
                actor=ib_user,
                from_user=client,
                to_user=ib_user,
                amount=payout,
                currency="USD",
                reference=f"BT_{deal_s}_{ib_user.id}",
                notes=f"BTrader IB comm | deal={deal_s} lots={lots_d} symbol={symbol_s} rate={rate}",
            )
    except IntegrityError:
        return {"credited": False, "reason": "duplicate"}

    try:
        from ib.services import bump_ib_progress_from_trade
        from ib.level_progress import maybe_queue_level_upgrade

        bump_ib_progress_from_trade(ib_user, volume=lots_d, lots=lots_d)
        maybe_queue_level_upgrade(ib_user)
    except Exception:
        logger.exception("BTrader IB progress bump failed deal=%s", deal_s)

    logger.info(
        "BTrader IB rebate deal=%s login=%s symbol=%s lots=%s ib=%s amount=%s",
        deal_s,
        login_s,
        symbol_s,
        lots_d,
        ib_user.id,
        payout,
    )
    return {"credited": True, "amount": str(payout), "ib_user_id": ib_user.id, "rate": str(rate)}
