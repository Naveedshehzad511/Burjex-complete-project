from datetime import timedelta
from decimal import Decimal

from django.utils import timezone
from django.db import transaction as db_transaction

from accounts.models import User
from transactions.models import Transaction

from .commission_engine import apply_level_caps, resolve_ib_commission_for_trade
from .models import IBCommissionRule, IBCommissionSettings, IBGroupCommission, IBLevel, IBPairCommission, IBProfile, IBRequest


def _effective_percentage(symbol: str = "", group_name: str = "", lots: Decimal = Decimal("0"), deposit_total: Decimal = Decimal("0")) -> Decimal:
    settings_obj = IBCommissionSettings.get_solo()
    if symbol:
        row = IBPairCommission.objects.filter(symbol__iexact=symbol, is_active=True).first()
        if row:
            return Decimal(str(row.percentage or 0))
    if group_name:
        row = IBGroupCommission.objects.filter(group_name__iexact=group_name, is_active=True).first()
        if row:
            return Decimal(str(row.percentage or 0))
    # Highest matching level by target
    level_row = (
        IBLevel.objects.filter(is_active=True, target_lots__lte=lots, target_deposit__lte=deposit_total)
        .order_by("-sequence")
        .first()
    )
    if level_row:
        return Decimal(str(level_row.commission_percentage or 0))
    return Decimal(str(settings_obj.default_percentage or 0))


def compute_ib_base_amount(
    *,
    link: IBRequest,
    lots: Decimal,
    spread_amount: Decimal = Decimal("0"),
    commission_amount: Decimal = Decimal("0"),
) -> Decimal:
    settings_obj = IBCommissionSettings.get_solo()
    if spread_amount or commission_amount:
        if settings_obj.commission_type == IBCommissionSettings.CommissionType.SPREAD_ONLY:
            return Decimal(str(spread_amount or 0))
        if settings_obj.commission_type == IBCommissionSettings.CommissionType.COMMISSION_ONLY:
            return Decimal(str(commission_amount or 0))
        return Decimal(str(spread_amount or 0)) + Decimal(str(commission_amount or 0))
    if settings_obj.commission_per_lot > 0:
        return Decimal(str(lots)) * Decimal(str(settings_obj.commission_per_lot))
    rule = (
        IBCommissionRule.objects.filter(plan=link.plan, is_active=True).select_related("commission_group").order_by("-id").first()
        if link.plan
        else IBCommissionRule.objects.filter(is_active=True).select_related("commission_group").order_by("-id").first()
    )
    if not rule:
        return Decimal("0")
    return Decimal(str(lots)) * Decimal(str(rule.level1 or 0))


def distribute_trade_commission(
    client_user: User,
    lots: Decimal,
    volume: Decimal = Decimal("0"),
    reference: str = "",
    symbol: str = "",
    group_name: str = "",
    spread_amount: Decimal = Decimal("0"),
    commission_amount: Decimal = Decimal("0"),
    account_type_id: int | None = None,
    hold_seconds: int | None = None,
):
    """
    Distribute IB commission after a trade-close event.
    Commission values are treated as amount per lot.
    """
    if not client_user or lots <= 0:
        return {"distributed": 0, "rows": []}

    link = (
        IBRequest.objects.filter(client_user=client_user, status=IBRequest.Status.APPROVED)
        .select_related("ib_user", "plan")
        .order_by("-processed_at", "-requested_at")
        .first()
    )
    if not link or not link.ib_user:
        return {"distributed": 0, "rows": []}
    # Never pay commission for IB's own trading activity.
    if link.ib_user_id == client_user.id:
        return {"distributed": 0, "rows": []}

    base_amount = compute_ib_base_amount(
        link=link,
        lots=Decimal(str(lots)),
        spread_amount=Decimal(str(spread_amount or 0)),
        commission_amount=Decimal(str(commission_amount or 0)),
    )
    if base_amount <= 0:
        return {"distributed": 0, "rows": []}

    dep_total = (
        Transaction.objects.filter(
            actor=client_user,
            tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
        ).values_list("amount", flat=True)
    )
    deposit_total = sum((Decimal(str(x or 0)) for x in dep_total), Decimal("0"))
    
    from admin_panel.models import TradingAccountType
    account_type = TradingAccountType.objects.filter(id=account_type_id).first() if account_type_id else None
    override_rate = get_rebate_rate(link.plan, symbol, account_type)

    res = resolve_ib_commission_for_trade(
        ib_user=link.ib_user,
        base_amount=base_amount,
        symbol_raw=symbol,
        group_name=group_name,
        lots=Decimal(str(lots)),
        deposit_total=deposit_total,
        account_type_id=account_type_id,
        hold_seconds=hold_seconds,
        override_rate=override_rate,
    )
    ib_total = res.ib_total
    ib_profile = IBProfile.objects.filter(user=link.ib_user).select_related("ib_level").first()
    ib_total = apply_level_caps(link.ib_user_id, ib_profile.ib_level if ib_profile else None, ib_total)
    if ib_total <= 0:
        return {"distributed": 0, "rows": []}

    out = []
    ib_user = link.ib_user
    ref = reference or f"TRADE_CLOSE_{timezone.now().strftime('%Y%m%d%H%M%S')}"
    with db_transaction.atomic():
        max_rebate_rate = (ib_total / lots) if lots > 0 else Decimal("0")
        payout = (lots * max_rebate_rate).quantize(Decimal("0.01"))

        if payout > 0:
            tx = Transaction.objects.create(
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status=Transaction.Status.COMPLETED,
                actor=ib_user,
                from_user=client_user,
                to_user=ib_user,
                amount=payout,
                currency="USD",
                reference=f"{ref}_{ib_user.id}",
                notes=f"Auto IB comm | lots={lots} volume={volume} symbol={symbol} rate={max_rebate_rate}",
            )
            out.append({"level": 1, "ib_user_id": ib_user.id, "amount": payout, "tx_id": tx.id})

    try:
        from .level_progress import maybe_queue_level_upgrade

        bump_ib_progress_from_trade(link.ib_user, volume=Decimal(str(volume)), lots=Decimal(str(lots)))
        maybe_queue_level_upgrade(link.ib_user)
    except Exception:
        pass

    return {"distributed": len(out), "rows": out, "resolution": {"mode": res.mode, "source": res.source}}


def bump_ib_progress_from_trade(ib_user: User, volume: Decimal, lots: Decimal) -> None:
    """Increment IB progress metrics for the IB."""
    from .models import IBProgressMetrics

    targets = [ib_user]

    now = timezone.now()
    today = now.date()
    week_start = today - timedelta(days=today.weekday())
    month_start = today.replace(day=1)

    for u in targets:
        mp, _ = IBProgressMetrics.objects.get_or_create(ib_user=u)
        changed = []
        mp.all_time_volume += volume
        mp.all_time_lots += lots
        changed.extend(["all_time_volume", "all_time_lots"])

        if mp.daily_period != today:
            mp.daily_period = today
            mp.daily_volume = Decimal("0")
            mp.daily_lots = Decimal("0")
            mp.daily_team_deposit = Decimal("0")
            mp.daily_referrals = 0
            changed.extend(["daily_period", "daily_volume", "daily_lots", "daily_team_deposit", "daily_referrals"])
        mp.daily_volume += volume
        mp.daily_lots += lots
        changed.extend(["daily_volume", "daily_lots"])

        if mp.week_start != week_start:
            mp.week_start = week_start
            mp.weekly_volume = Decimal("0")
            mp.weekly_lots = Decimal("0")
            mp.weekly_team_deposit = Decimal("0")
            mp.weekly_referrals = 0
            changed.extend(["weekly_volume", "weekly_lots", "weekly_team_deposit", "weekly_referrals", "week_start"])
        mp.weekly_volume += volume
        mp.weekly_lots += lots
        changed.extend(["weekly_volume", "weekly_lots"])

        if mp.month_start != month_start:
            mp.month_start = month_start
            mp.monthly_volume = Decimal("0")
            mp.monthly_lots = Decimal("0")
            mp.monthly_team_deposit = Decimal("0")
            mp.monthly_referrals = 0
            changed.extend(["monthly_volume", "monthly_lots", "monthly_team_deposit", "monthly_referrals", "month_start"])
        mp.monthly_volume += volume
        mp.monthly_lots += lots
        changed.extend(["monthly_volume", "monthly_lots"])

        mp.save(update_fields=list(dict.fromkeys(changed + ["updated_at"])))


def evaluate_ib_level_for_user(ib_user: User) -> None:
    """
    Assign the starter IB level (lowest active sequence) when none is set.
    Further upgrades go through the Level Approval queue (see maybe_queue_level_upgrade).
    """
    profile = IBProfile.objects.filter(user=ib_user).first()
    if not profile:
        return

    levels = list(IBLevel.objects.filter(is_active=True).order_by("sequence", "id"))
    if not levels:
        return
    if profile.ib_level_id is None:
        profile.ib_level = levels[0]
        profile.save(update_fields=["ib_level"])

    try:
        from .level_progress import maybe_queue_level_upgrade, refresh_referral_count

        refresh_referral_count(ib_user, increment_period=False)
        maybe_queue_level_upgrade(ib_user)
    except Exception:
        pass


def get_rebate_rate(plan, symbol_name, account_type=None) -> Decimal:
    """
    Resolve the rebate rate for a symbol under the given plan.
    Supports exact matching, base symbol matching (removing suffixes like .S, .R),
    and optional account type overrides.
    """
    from .models import IBPlanSymbolRebate

    # Try exact match with specific account type
    if account_type:
        rate = IBPlanSymbolRebate.objects.filter(plan=plan, symbol__iexact=symbol_name, account_type=account_type, is_active=True).first()
        if rate:
            return rate.rebate_per_lot

    # Try exact match with no account type
    rate = IBPlanSymbolRebate.objects.filter(plan=plan, symbol__iexact=symbol_name, account_type__isnull=True, is_active=True).first()
    if rate:
        return rate.rebate_per_lot

    # Try base symbol match (XAUUSD.S -> XAUUSD)
    if "." in symbol_name:
        base_symbol = symbol_name.split(".")[0]
        if account_type:
            rate = IBPlanSymbolRebate.objects.filter(plan=plan, symbol__iexact=base_symbol, account_type=account_type, is_active=True).first()
            if rate:
                return rate.rebate_per_lot
        rate = IBPlanSymbolRebate.objects.filter(plan=plan, symbol__iexact=base_symbol, account_type__isnull=True, is_active=True).first()
        if rate:
            return rate.rebate_per_lot

    return Decimal("0")


def sync_mt5_deals_and_calculate_rebates(days_back: int = 30) -> dict:
    """
    Periodic/manual task: fetch closed trade deals from MT5, calculate IB rebates,
    credit them to IB wallets, and prevent duplicate processing. Excludes demo accounts.
    """
    from datetime import datetime, timedelta, timezone as dt_timezone
    from django.utils import timezone
    from django.db import transaction as db_transaction
    from accounts.models import MT5Account
    from admin_panel.models import TradingAccount
    from mt5_integration.services import _mt5_client, is_mt5_configured
    from .models import IBPlan, IBRequest, IBUserCommission, ProcessedMT5Deal
    from transactions.models import Transaction

    if not is_mt5_configured():
        return {"status": "skipped", "reason": "MT5 not configured"}

    # Fetch active live accounts only
    live_accounts = MT5Account.objects.filter(
        account_type=MT5Account.AccountType.LIVE,
        status=MT5Account.Status.ACTIVE
    )

    now = timezone.now()
    to_time = int((now + timedelta(days=1)).timestamp())
    # Query last `days_back` days to catch up on any missed syncs
    from_time = int((now - timedelta(days=days_back)).timestamp())

    processed_count = 0
    errors_count = 0

    try:
        with _mt5_client() as client:
            for account in live_accounts:
                login_id = int(account.login_id)
                client_user = account.user

                try:
                    # Get closed trade deals (limit 1000 per page to be safe)
                    deals = client.deal_get_page(login_id, from_time, to_time, 0, 1000)
                except Exception as exc:
                    errors_count += 1
                    continue

                if not deals or not isinstance(deals, list):
                    continue

                for deal in deals:
                    # MT5 deal details:
                    # - 'Deal': ticket ID
                    # - 'Login': login ID
                    # - 'Symbol': symbol string (e.g. XAUUSD.S)
                    # - 'Volume': volume (value is lots * 10000)
                    # - 'Time': UNIX timestamp of close
                    # - 'Action': 0 = Buy, 1 = Sell, 2 = Balance (exclude balance!)
                    # - 'Entry': 0 = In, 1 = Out, 2 = InOut, 3 = OutBy
                    deal_id = str(deal.get("Deal", ""))
                    if not deal_id or deal_id == "0":
                        continue

                    symbol_name = deal.get("Symbol")
                    if not symbol_name:
                        continue

                    # Exclude balance changes (Action=2)
                    try:
                        action = int(deal.get("Action", -1))
                    except (ValueError, TypeError):
                        action = -1
                    if action == 2:
                        continue

                    # Process exits only (Entry OUT=1, INOUT=2, OUT_BY=3)
                    try:
                        entry = int(deal.get("Entry", -1))
                    except (ValueError, TypeError):
                        entry = -1
                    if entry not in (1, 2, 3):
                        continue

                    # Duplicate protection
                    if ProcessedMT5Deal.objects.filter(deal_id=deal_id).exists():
                        continue

                    deal_time_ts = deal.get("Time")
                    if not deal_time_ts:
                        continue
                    close_time = datetime.fromtimestamp(int(deal_time_ts), tz=dt_timezone.utc)

                    # Resolve referred relationship active at close_time (historical matching)
                    active_request = IBRequest.objects.filter(
                        client_user=client_user,
                        status=IBRequest.Status.APPROVED,
                        processed_at__lte=close_time
                    ).order_by("-processed_at").first()

                    if not active_request or not active_request.ib_user:
                        continue

                    ib_user = active_request.ib_user

                    # Never pay commission for IB's own trading activity
                    if ib_user.id == client_user.id:
                        continue

                    # Resolve IB's plan
                    plan = active_request.plan
                    if not plan:
                        user_comm = IBUserCommission.objects.filter(ib_user=ib_user).first()
                        plan = user_comm.plan if user_comm else None
                    if not plan:
                        plan = IBPlan.objects.filter(is_active=True).first()

                    # Resolve client account type
                    account_type_id = None
                    account_type_obj = None
                    trading_acc = TradingAccount.objects.filter(mt5_account=account).first()
                    if trading_acc:
                        from admin_panel.models import TradingAccountType
                        tat = TradingAccountType.objects.filter(account_name=trading_acc.account_type).first()
                        if tat:
                            account_type_id = tat.id
                            account_type_obj = tat

                    # Calculate volume lots (Volume in MT5 Web API is lots * 10000)
                    deal_vol = deal.get("Volume", 0)
                    lots = Decimal(str(deal_vol)) / Decimal("10000.0")
                    if lots <= 0:
                        continue
                        
                    override_rate = get_rebate_rate(plan, symbol_name, account_type_obj)

                    mt5_comm = abs(Decimal(str(deal.get("Commission", 0))))
                    base_amount = compute_ib_base_amount(
                        link=active_request,
                        lots=lots,
                        spread_amount=Decimal("0"),
                        commission_amount=mt5_comm,
                    )

                    dep_total = (
                        Transaction.objects.filter(
                            actor=client_user,
                            tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                        ).values_list("amount", flat=True)
                    )
                    deposit_total = sum((Decimal(str(x or 0)) for x in dep_total), Decimal("0"))
                    
                    hold_seconds = None
                    
                    ib_profile = IBProfile.objects.filter(user=ib_user).select_related("ib_level").first()
                    ib_level = ib_profile.ib_level if ib_profile else None
                    
                    if ib_level and ib_level.min_holding_period_seconds and ib_level.min_holding_period_seconds > 0:
                        try:
                            pos_id_str = deal.get("PositionID")
                            if pos_id_str and pos_id_str != "0":
                                # Fetch the initial order that created the position to get open time
                                hist_order = client.history_get(int(pos_id_str))
                                if hist_order and hist_order.get("TimeDone"):
                                    open_time = int(hist_order.get("TimeDone"))
                                    close_time_ts = int(deal_time_ts)
                                    hold_seconds = max(0, close_time_ts - open_time)
                        except Exception as e:
                            pass

                    res = resolve_ib_commission_for_trade(
                        ib_user=ib_user,
                        base_amount=base_amount,
                        symbol_raw=symbol_name,
                        group_name=account.group.name if account.group else "",
                        lots=lots,
                        deposit_total=deposit_total,
                        account_type_id=account_type_id,
                        hold_seconds=hold_seconds,
                        override_rate=override_rate,
                    )
                    
                    ib_total = apply_level_caps(ib_user.id, ib_level, res.ib_total)
                    
                    try:
                        with db_transaction.atomic():
                            from transactions.utils import ensure_unique_action
                            try:
                                ensure_unique_action(f"IB_REBATE_DEAL_{deal_id}", "IB_REBATE")
                            except ValueError:
                                continue

                            if ProcessedMT5Deal.objects.filter(deal_id=deal_id).exists():
                                continue

                            try:
                                from .level_progress import maybe_queue_level_upgrade
                                bump_ib_progress_from_trade(ib_user, volume=Decimal(str(deal_vol)), lots=lots)
                                maybe_queue_level_upgrade(ib_user)
                            except Exception:
                                pass

                            max_rebate_rate = (ib_total / lots).quantize(Decimal("0.01")) if lots > 0 and ib_total > 0 else Decimal("0")

                            ProcessedMT5Deal.objects.create(
                                deal_id=deal_id,
                                login_id=str(login_id),
                                symbol=symbol_name,
                                volume_lots=lots,
                                close_time=close_time,
                                account_group=account.group.name if account.group else "",
                                rebate_rate=max_rebate_rate,
                                rebate_amount=ib_total if ib_total > 0 else Decimal("0"),
                                ib_user=ib_user,
                                plan=plan,
                            )

                            if ib_total > 0:
                                ref_str = f"REBATE_{deal_id}_{ib_user.id}"
                                Transaction.objects.create(
                                    tx_type=Transaction.TxType.IB_WITHDRAW,
                                    status=Transaction.Status.COMPLETED,
                                    actor=ib_user,
                                    from_user=client_user,
                                    to_user=ib_user,
                                    amount=ib_total,
                                    currency="USD",
                                    reference=ref_str,
                                    notes=f"IB Rebate | client={client_user.email} | deal={deal_id} | symbol={symbol_name} | lots={lots} | rate={max_rebate_rate}",
                                    processed_at=now,
                                )
                            processed_count += 1
                    except Exception as e:
                        errors_count += 1
                        continue

    except Exception as exc:
        return {"status": "error", "message": str(exc), "processed_count": processed_count}

    return {"status": "success", "processed_count": processed_count, "errors_count": errors_count}
