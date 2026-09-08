"""IB level progression metrics, referral sync, and upgrade request queue."""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.db import transaction as db_transaction
from django.utils import timezone

from accounts.models import User
from transactions.models import Transaction

from .models import IBLevel, IBLevelUpgradeRequest, IBProfile, IBProgressMetrics, IBRequest


def _team_client_ids(ib_user_id: int) -> list[int]:
    return list(
        IBRequest.objects.filter(ib_user_id=ib_user_id, status=IBRequest.Status.APPROVED).values_list(
            "client_user_id", flat=True
        ).distinct()
    )


def refresh_referral_count(ib_user: User, *, increment_period: bool = False) -> None:
    if not ib_user:
        return
    prof = IBProfile.objects.filter(user=ib_user).first()
    if not prof:
        return
        
    mp, _ = IBProgressMetrics.objects.get_or_create(ib_user=ib_user)
    now = timezone.now().date()
    week_start = now - timedelta(days=now.weekday())
    month_start = now.replace(day=1)
    
    base_qs = IBRequest.objects.filter(ib_user=ib_user, status=IBRequest.Status.APPROVED)
    
    mp.referral_count = base_qs.values("client_user_id").distinct().count()
    mp.daily_referrals = base_qs.filter(requested_at__date=now).values("client_user_id").distinct().count()
    mp.weekly_referrals = base_qs.filter(requested_at__date__gte=week_start).values("client_user_id").distinct().count()
    mp.monthly_referrals = base_qs.filter(requested_at__date__gte=month_start).values("client_user_id").distinct().count()
    
    mp.daily_period = now
    mp.week_start = week_start
    mp.month_start = month_start
    
    mp.save(
        update_fields=[
            "referral_count",
            "daily_period",
            "daily_referrals",
            "week_start",
            "weekly_referrals",
            "month_start",
            "monthly_referrals",
            "updated_at",
        ]
    )

    try:
        maybe_queue_level_upgrade(ib_user)
    except Exception:
        pass


def bump_team_deposit_from_transaction(actor_id: int, amount) -> None:
    """When a referred client deposits, credit team deposit on their IB's metrics."""
    amt = Decimal(str(amount or 0))
    if amt <= 0:
        return
    link = (
        IBRequest.objects.filter(client_user_id=actor_id, status=IBRequest.Status.APPROVED)
        .select_related("ib_user")
        .order_by("-processed_at", "-requested_at")
        .first()
    )
    if not link:
        return
    ib_user = link.ib_user
    prof = IBProfile.objects.filter(user=ib_user).first()

    if not ib_user:
        return
    mp, _ = IBProgressMetrics.objects.get_or_create(ib_user=ib_user)
    now = timezone.now().date()
    week_start = now - timedelta(days=now.weekday())
    month_start = now.replace(day=1)
    mp.all_time_team_deposit += amt
    fields = ["all_time_team_deposit", "updated_at"]
    if mp.daily_period != now:
        mp.daily_period = now
        mp.daily_team_deposit = Decimal("0")
        fields.extend(["daily_period", "daily_team_deposit"])
    mp.daily_team_deposit += amt
    fields.append("daily_team_deposit")
    if mp.week_start != week_start:
        mp.week_start = week_start
        mp.weekly_team_deposit = Decimal("0")
        fields.extend(["week_start", "weekly_team_deposit"])
    mp.weekly_team_deposit += amt
    fields.append("weekly_team_deposit")
    if mp.month_start != month_start:
        mp.month_start = month_start
        mp.monthly_team_deposit = Decimal("0")
        fields.extend(["month_start", "monthly_team_deposit"])
    mp.monthly_team_deposit += amt
    fields.append("monthly_team_deposit")
    mp.save(update_fields=list(dict.fromkeys(fields)))

    try:
        maybe_queue_level_upgrade(ib_user)
    except Exception:
        pass


def window_metric_values(level: IBLevel, mp: IBProgressMetrics) -> tuple[Decimal, Decimal, int]:
    w = level.metric_window
    if w == IBLevel.MetricWindow.DAILY:
        return mp.daily_lots, mp.daily_team_deposit, mp.daily_referrals
    if w == IBLevel.MetricWindow.WEEKLY:
        return mp.weekly_lots, mp.weekly_team_deposit, mp.weekly_referrals
    if w == IBLevel.MetricWindow.MONTHLY:
        return mp.monthly_lots, mp.monthly_team_deposit, mp.monthly_referrals
    return mp.all_time_lots, mp.all_time_team_deposit, mp.referral_count


def _meets_level_thresholds(ib_user: User, level: IBLevel, mp: IBProgressMetrics) -> bool:
    lots, dep, refs = window_metric_values(level, mp)
    if level.target_lots and lots < level.target_lots:
        return False
    if level.target_deposit and dep < level.target_deposit:
        return False
    need_refs = max(level.min_referrals or 0, level.target_active_clients or 0)
    if need_refs and refs < need_refs:
        return False
    return True


def maybe_queue_level_upgrade(ib_user: User) -> IBLevelUpgradeRequest | None:
    """Create pending upgrade request if IB qualifies for the next sequence level."""
    prof = IBProfile.objects.filter(user=ib_user).select_related("ib_level").first()
    if not prof:
        return None
    levels = list(IBLevel.objects.filter(is_active=True).order_by("sequence", "id"))
    if not levels:
        return None
    current = prof.ib_level
    next_level = None
    if current:
        for x in levels:
            if x.sequence > current.sequence or (x.sequence == current.sequence and x.id > current.id):
                next_level = x
                break
    else:
        next_level = levels[0]
    if not next_level:
        return None
    if current and current.id == next_level.id:
        return None

    mp, _ = IBProgressMetrics.objects.get_or_create(ib_user=ib_user)
    if not _meets_level_thresholds(ib_user, next_level, mp):
        return None

    exists = IBLevelUpgradeRequest.objects.filter(
        ib_user=ib_user,
        to_level=next_level,
        status=IBLevelUpgradeRequest.Status.PENDING,
    ).exists()
    if exists:
        return None

    req = IBLevelUpgradeRequest.objects.create(
        ib_user=ib_user,
        from_level=current,
        to_level=next_level,
        status=IBLevelUpgradeRequest.Status.APPROVED,
        processed_at=timezone.now(),
    )
    
    prof.ib_level = next_level
    prof.save(update_fields=["ib_level"])

    try:
        from django.urls import reverse

        from enterprise.staff_notify import broadcast_staff_notification

        tok = f"[ib_level_up:{req.id}]"
        broadcast_staff_notification(
            "IB level automatically upgraded",
            f"{tok} {ib_user.display_name()} was automatically promoted to {next_level.name}.",
            action_url=reverse("admin-ib-levels"),
            dedupe_body_contains=tok,
        )
    except Exception:
        pass
    return req


def build_ib_portal_progress(ib_user: User) -> dict | None:
    """Context for client IB dashboard: level stepper, next tier, progress %."""
    prof = IBProfile.objects.filter(user=ib_user).select_related("ib_level").first()
    if not prof:
        return None
    mp, _ = IBProgressMetrics.objects.get_or_create(ib_user=ib_user)
    levels = list(IBLevel.objects.filter(is_active=True).order_by("sequence", "id"))
    current = prof.ib_level
    next_level = None
    if current:
        for x in levels:
            if x.sequence > current.sequence or (x.sequence == current.sequence and x.id > current.id):
                next_level = x
                break
    else:
        next_level = levels[0] if levels else None

    commission_rate = ""
    if current:
        commission_rate = f"{current.commission_percentage}%"
    elif levels:
        commission_rate = f"{levels[0].commission_percentage}%"

    if not next_level:
        return {
            "levels": levels,
            "current_level": current,
            "next_level": None,
            "progress_percent": 100,
            "primary_label": "",
            "current_value": Decimal("0"),
            "required_value": Decimal("0"),
            "remaining_value": Decimal("0"),
            "lots_cur": Decimal("0"), "lots_req": Decimal("0"), "lots_pct": 100,
            "dep_cur": Decimal("0"), "dep_req": Decimal("0"), "dep_pct": 100,
            "refs_cur": Decimal("0"), "refs_req": Decimal("0"), "refs_pct": 100,
            "commission_rate": commission_rate,
            "next_reward_title": "",
            "next_reward_remaining_label": "",
        }

    lots, dep, refs = window_metric_values(next_level, mp)
    m = next_level.primary_progress_metric
    if m == IBLevel.PrimaryProgressMetric.DEPOSIT:
        cur, req = dep, next_level.target_deposit
        label = "Team deposit"
    elif m == IBLevel.PrimaryProgressMetric.REFERRALS:
        cur = Decimal(str(refs))
        req = Decimal(str(max(next_level.min_referrals or 0, next_level.target_active_clients or 0)))
        label = "Referrals"
    else:
        cur, req = lots, next_level.target_lots
        label = "Volume (lots)"

    req_d = Decimal(str(req or 0))
    cur_d = Decimal(str(cur or 0))
    if req_d <= 0:
        pct = 100
    else:
        pct = min(100, int((cur_d / req_d * Decimal("100")).quantize(Decimal("1"))))
    remaining = max(Decimal("0"), req_d - cur_d)
    
    req_lots = Decimal(str(next_level.target_lots or 0))
    cur_lots = Decimal(str(lots or 0))
    pct_lots = 100 if req_lots <= 0 else min(100, int((cur_lots / req_lots * Decimal("100")).quantize(Decimal("1"))))

    req_dep = Decimal(str(next_level.target_deposit or 0))
    cur_dep = Decimal(str(dep or 0))
    pct_dep = 100 if req_dep <= 0 else min(100, int((cur_dep / req_dep * Decimal("100")).quantize(Decimal("1"))))

    req_refs = Decimal(str(max(next_level.min_referrals or 0, next_level.target_active_clients or 0)))
    cur_refs = Decimal(str(refs or 0))
    pct_refs = 100 if req_refs <= 0 else min(100, int((cur_refs / req_refs * Decimal("100")).quantize(Decimal("1"))))

    nr = next_level.rewards.order_by("sort_order", "id").first()
    next_reward_title = nr.title if nr else ""
    next_reward_remaining = ""
    if nr and m == IBLevel.PrimaryProgressMetric.VOLUME and next_level.target_lots > 0:
        next_reward_remaining = f"{remaining} lots to next reward tier"

    return {
        "levels": levels,
        "current_level": current,
        "next_level": next_level,
        "progress_percent": pct,
        "primary_label": label,
        "current_value": cur_d,
        "required_value": req_d,
        "remaining_value": remaining,
        "lots_cur": cur_lots, "lots_req": req_lots, "lots_pct": pct_lots,
        "dep_cur": cur_dep, "dep_req": req_dep, "dep_pct": pct_dep,
        "refs_cur": cur_refs, "refs_req": req_refs, "refs_pct": pct_refs,
        "commission_rate": commission_rate,
        "next_reward_title": next_reward_title,
        "next_reward_remaining_label": next_reward_remaining,
    }
