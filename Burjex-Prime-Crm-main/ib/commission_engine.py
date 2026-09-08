"""
IB commission resolution: matrix-first (symbol > symbol group > level % > global),
with optional legacy pair/group chain, holding period, and payout caps.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING

from datetime import datetime, time, timedelta

from django.db.models import Q, Sum
from django.utils import timezone

from admin_panel.models import TradingAccountType, TradingSymbol

from .models import (
    IBCommissionMatrixRule,
    IBCommissionSettings,
    IBGroupCommission,
    IBLevel,
    IBPairCommission,
    IBProfile,
)

if TYPE_CHECKING:
    from accounts.models import User


@dataclass
class CommissionResolution:
    ib_total: Decimal
    mode: str
    source: str
    rule_id: int | None = None


def _norm_symbol(s: str) -> str:
    return (s or "").strip().upper()


def find_trading_symbol(mt5_symbol: str) -> TradingSymbol | None:
    raw = _norm_symbol(mt5_symbol)
    if not raw:
        return None
    for row in TradingSymbol.objects.filter(is_active=True).select_related("group"):
        if _norm_symbol(row.mt5_symbol()) == raw:
            return row
    return None


def infer_symbol_group_from_account_suffix(mt5_symbol: str, account_type: TradingAccountType | None) -> int | None:
    """Resolve SymbolGroup id using TradingAccountType.mt5_symbol_suffix when symbol row is missing."""
    from django.utils.text import slugify

    from admin_panel.models import SymbolGroup

    if not account_type:
        return None
    suf = (account_type.mt5_symbol_suffix or "").strip()
    if not suf:
        return None
    if not suf.startswith("."):
        suf = "." + suf
    raw = _norm_symbol(mt5_symbol)
    if not raw.endswith(_norm_symbol(suf)):
        return None
    token = suf[1:].upper() if suf.startswith(".") else suf.upper()
    pretty = "Standard" if token in ("", "STANDARD") else token
    g = SymbolGroup.objects.filter(name__iexact=pretty).first()
    if not g:
        slug = slugify(pretty)[:120]
        if slug:
            g = SymbolGroup.objects.filter(slug=slug).first()
    return g.id if g else None


def _matrix_rules_queryset(ib_level: IBLevel | None, account_type_id: int | None):
    if not ib_level:
        return IBCommissionMatrixRule.objects.none()
    qs = IBCommissionMatrixRule.objects.filter(ib_level=ib_level, is_active=True).select_related(
        "trading_symbol", "symbol_group", "account_type", "mt5_crm_group"
    )
    if account_type_id:
        qs = qs.filter(Q(account_type_id=account_type_id) | Q(account_type__isnull=True))
    at = TradingAccountType.objects.filter(id=account_type_id).first() if account_type_id else None
    if at and at.crm_group_id:
        qs = qs.filter(Q(mt5_crm_group__isnull=True) | Q(mt5_crm_group_id=at.crm_group_id))
    else:
        qs = qs.filter(mt5_crm_group__isnull=True)
    return qs


def _pick_matrix_rule(
    ib_level: IBLevel | None,
    sym: TradingSymbol | None,
    symbol_group_id: int | None,
    account_type_id: int | None,
    *,
    symbol_norm: str = "",
) -> IBCommissionMatrixRule | None:
    from admin_panel.models import CrmGroupSymbol

    raw = _norm_symbol(symbol_norm)
    qs = list(_matrix_rules_queryset(ib_level, account_type_id))
    if not qs:
        return None

    def score(r: IBCommissionMatrixRule) -> tuple[int, int, int]:
        ms = (r.matrix_symbol_name or "").strip()
        if ms:
            spec = 5
        elif r.mt5_crm_group_id:
            spec = 4
        elif r.trading_symbol_id:
            spec = 3
        elif r.symbol_group_id:
            spec = 2
        else:
            spec = 1
        acc_bonus = 1 if r.account_type_id else 0
        return (spec, acc_bonus, r.priority)

    best: IBCommissionMatrixRule | None = None
    best_key = (-1, -1, -1)
    for r in qs:
        match = False
        ms = (r.matrix_symbol_name or "").strip()
        if ms:
            if _norm_symbol(ms) == raw:
                match = True
            else:
                continue
        elif r.mt5_crm_group_id:
            cg = CrmGroupSymbol.objects.filter(mt5_group_id=r.mt5_crm_group_id)
            if raw and cg.exists() and not cg.filter(symbol_name__iexact=raw).exists():
                continue
            match = True
        elif r.trading_symbol_id and sym and r.trading_symbol_id == sym.id:
            match = True
        elif r.symbol_group_id and symbol_group_id and r.symbol_group_id == symbol_group_id:
            match = True
        elif not r.trading_symbol_id and not r.symbol_group_id and not r.mt5_crm_group_id and not ms:
            match = True
        if not match:
            continue
        k = score(r)
        if k > best_key:
            best_key = k
            best = r
    return best


def _legacy_percentage(symbol: str, group_name: str, lots: Decimal, deposit_total: Decimal) -> Decimal:
    settings_obj = IBCommissionSettings.get_solo()
    if symbol:
        row = IBPairCommission.objects.filter(symbol__iexact=symbol, is_active=True).first()
        if row:
            return Decimal(str(row.percentage or 0))
    if group_name:
        row = IBGroupCommission.objects.filter(group_name__iexact=group_name, is_active=True).first()
        if row:
            return Decimal(str(row.percentage or 0))
    level_row = (
        IBLevel.objects.filter(is_active=True, target_lots__lte=lots, target_deposit__lte=deposit_total)
        .order_by("-sequence")
        .first()
    )
    if level_row:
        return Decimal(str(level_row.commission_percentage or 0))
    return Decimal(str(settings_obj.default_percentage or 0))


def _period_start(kind: str):
    now = timezone.now()
    d = now.date()
    if kind == "day":
        return timezone.make_aware(datetime.combine(d, time.min))
    if kind == "week":
        start = d - timedelta(days=d.weekday())
        return timezone.make_aware(datetime.combine(start, time.min))
    if kind == "month":
        start = d.replace(day=1)
        return timezone.make_aware(datetime.combine(start, time.min))
    return now


def ib_payout_sum_since(ib_user_id: int, period_kind: str) -> Decimal:
    from transactions.models import Transaction

    start = _period_start(period_kind)
    total = (
        Transaction.objects.filter(
            actor_id=ib_user_id,
            tx_type=Transaction.TxType.IB_WITHDRAW,
            status=Transaction.Status.COMPLETED,
            created_at__gte=start,
        ).aggregate(s=Sum("amount"))["s"]
        or 0
    )
    return Decimal(str(total))


def apply_level_caps(ib_user_id: int, ib_level: IBLevel | None, proposed: Decimal) -> Decimal:
    if not ib_level or proposed <= 0:
        return proposed
    out = proposed
    if ib_level.cap_per_trade and ib_level.cap_per_trade > 0:
        out = min(out, Decimal(str(ib_level.cap_per_trade)))
    if ib_level.cap_daily and ib_level.cap_daily > 0:
        used = ib_payout_sum_since(ib_user_id, "day")
        remain = max(Decimal("0"), Decimal(str(ib_level.cap_daily)) - used)
        out = min(out, remain)
    if ib_level.cap_weekly and ib_level.cap_weekly > 0:
        used = ib_payout_sum_since(ib_user_id, "week")
        remain = max(Decimal("0"), Decimal(str(ib_level.cap_weekly)) - used)
        out = min(out, remain)
    if ib_level.cap_monthly and ib_level.cap_monthly > 0:
        used = ib_payout_sum_since(ib_user_id, "month")
        remain = max(Decimal("0"), Decimal(str(ib_level.cap_monthly)) - used)
        out = min(out, remain)
    return out.quantize(Decimal("0.01"))


def resolve_ib_commission_for_trade(
    *,
    ib_user: User,
    base_amount: Decimal,
    symbol_raw: str,
    group_name: str,
    lots: Decimal,
    deposit_total: Decimal,
    account_type_id: int | None = None,
    hold_seconds: int | None = None,
    override_rate: Decimal | None = None,
) -> CommissionResolution:
    """
    Returns IB payout amount.
    base_amount: economic base from spread/commission/per-lot (same as current distribute_trade_commission).
    """
    settings_obj = IBCommissionSettings.get_solo()
    profile = IBProfile.objects.filter(user=ib_user).select_related("ib_level").first()
    ib_level = profile.ib_level if profile else None

    if ib_level and ib_level.min_holding_period_seconds and ib_level.min_holding_period_seconds > 0:
        if hold_seconds is None or hold_seconds < ib_level.min_holding_period_seconds:
            return CommissionResolution(Decimal("0"), "blocked", "min_holding_period")
            
    if override_rate and override_rate > 0:
        amt = (Decimal(str(override_rate)) * Decimal(str(lots))).quantize(Decimal("0.01"))
        return CommissionResolution(amt, "FIXED_PER_LOT", "plan_symbol_override")

    sym = find_trading_symbol(symbol_raw)
    symbol_group_id = None
    if sym and sym.group_id:
        symbol_group_id = sym.group_id
    account_type = TradingAccountType.objects.filter(id=account_type_id).first() if account_type_id else None
    if symbol_group_id is None:
        gid = infer_symbol_group_from_account_suffix(symbol_raw, account_type)
        if gid:
            symbol_group_id = gid
    if symbol_group_id is None and group_name:
        from admin_panel.models import SymbolGroup

        g = SymbolGroup.objects.filter(name__iexact=group_name.strip()).first()
        if g:
            symbol_group_id = g.id

    use_matrix = settings_obj.use_matrix_commission_first

    if use_matrix and ib_level:
        rule = _pick_matrix_rule(
            ib_level, sym, symbol_group_id, account_type_id, symbol_norm=_norm_symbol(symbol_raw)
        )
        if rule:
            if rule.commission_mode == IBCommissionMatrixRule.CommissionMode.FIXED_PER_LOT:
                amt = (Decimal(str(rule.value)) * Decimal(str(lots))).quantize(Decimal("0.01"))
                return CommissionResolution(amt, "FIXED_PER_LOT", "matrix", rule.id)
            pct = Decimal(str(rule.value or 0))
            amt = (base_amount * pct / Decimal("100")).quantize(Decimal("0.01"))
            return CommissionResolution(amt, "PERCENT", "matrix", rule.id)

        pct = Decimal(str(ib_level.commission_percentage or 0))
        amt = (base_amount * pct / Decimal("100")).quantize(Decimal("0.01"))
        return CommissionResolution(amt, "PERCENT", "level_default")

    pct = _legacy_percentage(symbol_raw, group_name, lots, deposit_total)
    amt = (base_amount * pct / Decimal("100")).quantize(Decimal("0.01"))
    return CommissionResolution(amt, "PERCENT", "legacy")
