"""IB Levels admin: dashboard, CRUD, level upgrade approval queue.

Admin workflow:
- Define tiers under IB Levels (sequence, thresholds, metric window, caps, rewards, MT5 defaults).
- Set symbol-specific and group overrides in IB Commission Structure (matrix).
- Master/Sub settings: global commission type, default %, optional legacy pair/group rules,
  and "Matrix rules first" toggle on IBCommissionSettings.
- When a master IB meets the next tier, a row appears in Level Approval; approving updates
  IBProfile.ib_level so payouts follow the new matrix/level defaults immediately.
"""

from __future__ import annotations

from decimal import Decimal

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Q
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import MT5Group, User
from accounts.permissions import role_required
from admin_panel.models import TradingAccountType
from ib.models import (
    IBLevel,
    IBLevelAccountTypeDefault,
    IBLevelReward,
    IBLevelUpgradeRequest,
    IBProfile,
)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def ib_levels_dashboard(request):
    q = (request.GET.get("q") or "").strip()
    lt = (request.GET.get("level_type") or "").strip().upper()
    qs = IBLevel.objects.all().order_by("sequence", "id")
    if q:
        qs = qs.filter(Q(name__icontains=q) | Q(benefits__icontains=q))
    if lt in {IBLevel.LevelType.DIRECT, IBLevel.LevelType.PROGRESSION}:
        qs = qs.filter(level_type=lt)

    total_levels = IBLevel.objects.count()
    direct_n = IBLevel.objects.filter(level_type=IBLevel.LevelType.DIRECT).count()
    prog_n = IBLevel.objects.filter(level_type=IBLevel.LevelType.PROGRESSION).count()
    total_ibs = IBProfile.objects.count()
    pending_approvals = IBLevelUpgradeRequest.objects.filter(status=IBLevelUpgradeRequest.Status.PENDING).count()

    return render(
        request,
        "admin_panel/ib_levels_dashboard.html",
        {
            "levels": qs,
            "total_levels": total_levels,
            "direct_n": direct_n,
            "prog_n": prog_n,
            "total_ibs": total_ibs,
            "pending_approvals": pending_approvals,
            "filters": {"q": q, "level_type": lt},
            "level_types": IBLevel.LevelType.choices,
        },
    )


def _parse_level_post(request) -> dict:
    return {
        "name": (request.POST.get("name") or "").strip()[:40],
        "level_type": request.POST.get("level_type") or IBLevel.LevelType.PROGRESSION,
        "sequence": int(request.POST.get("sequence") or 1),
        "is_active": request.POST.get("is_active") == "on",
        "metric_window": request.POST.get("metric_window") or IBLevel.MetricWindow.ALL_TIME,
        "primary_progress_metric": request.POST.get("primary_progress_metric") or IBLevel.PrimaryProgressMetric.VOLUME,
        "target_lots": Decimal(str(request.POST.get("target_lots") or 0)),
        "target_deposit": Decimal(str(request.POST.get("target_deposit") or 0)),
        "min_referrals": int(request.POST.get("min_referrals") or 0),
        "target_active_clients": int(request.POST.get("target_active_clients") or request.POST.get("min_referrals") or 0),
        "commission_percentage": Decimal(str(request.POST.get("commission_percentage") or 0)),
        "min_holding_period_seconds": int(request.POST.get("min_holding_period_seconds") or 0),
        "cap_daily": Decimal(str(request.POST.get("cap_daily") or 0)),
        "cap_weekly": Decimal(str(request.POST.get("cap_weekly") or 0)),
        "cap_monthly": Decimal(str(request.POST.get("cap_monthly") or 0)),
        "cap_per_trade": Decimal(str(request.POST.get("cap_per_trade") or 0)),
        "downgrade_review_days": int(request.POST.get("downgrade_review_days") or 0),
        "downgrade_grace_days": int(request.POST.get("downgrade_grace_days") or 0),
        "downgrade_to_level_id": (request.POST.get("downgrade_to_level_id") or "").strip(),
        "benefits": (request.POST.get("benefits") or "").strip()[:4000],
    }


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_level_add(request):
    if request.method == "POST":
        data = _parse_level_post(request)
        if not data["name"]:
            messages.error(request, "Level name is required.")
        elif IBLevel.objects.filter(name__iexact=data["name"]).exists():
            messages.error(request, "A level with this name already exists.")
        else:
            dl = None
            if data["downgrade_to_level_id"].isdigit():
                dl = IBLevel.objects.filter(id=int(data["downgrade_to_level_id"])).first()
            IBLevel.objects.create(
                name=data["name"],
                level_type=data["level_type"],
                sequence=data["sequence"],
                is_active=data["is_active"],
                metric_window=data["metric_window"],
                primary_progress_metric=data["primary_progress_metric"],
                target_lots=data["target_lots"],
                target_deposit=data["target_deposit"],
                min_referrals=data["min_referrals"],
                target_active_clients=data["target_active_clients"],
                commission_percentage=data["commission_percentage"],
                min_holding_period_seconds=data["min_holding_period_seconds"],
                cap_daily=data["cap_daily"],
                cap_weekly=data["cap_weekly"],
                cap_monthly=data["cap_monthly"],
                cap_per_trade=data["cap_per_trade"],
                downgrade_review_days=data["downgrade_review_days"],
                downgrade_grace_days=data["downgrade_grace_days"],
                downgrade_to_level=dl,
                benefits=data["benefits"],
            )
            messages.success(request, "IB Level created.")
            return redirect("admin-ib-levels")
    return render(
        request,
        "admin_panel/ib_level_form.html",
        {
            "mode": "add",
            "level": None,
            "all_levels": IBLevel.objects.order_by("sequence"),
            "account_types": TradingAccountType.objects.filter(is_active=True).order_by("display_order", "account_name"),
            "mt5_groups": MT5Group.objects.filter(is_active=True).order_by("name")[:200],
            "level_types": IBLevel.LevelType.choices,
            "metric_windows": IBLevel.MetricWindow.choices,
            "progress_metrics": IBLevel.PrimaryProgressMetric.choices,
            "reward_kinds": IBLevelReward.RewardKind.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_level_edit(request, pk: int):
    level = get_object_or_404(IBLevel, pk=pk)
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "add_reward":
            rk = request.POST.get("reward_kind") or IBLevelReward.RewardKind.BONUS
            title = (request.POST.get("reward_title") or "").strip()
            if title:
                IBLevelReward.objects.create(
                    ib_level=level,
                    reward_kind=rk,
                    title=title[:200],
                    value_text=(request.POST.get("reward_value_text") or "").strip()[:500],
                    sort_order=int(request.POST.get("reward_sort") or 0),
                )
                messages.success(request, "Reward added.")
            return redirect("admin-ib-level-edit", pk=pk)
        if action == "delete_reward":
            rid = request.POST.get("reward_id")
            if rid:
                IBLevelReward.objects.filter(id=rid, ib_level=level).delete()
                messages.success(request, "Reward removed.")
            return redirect("admin-ib-level-edit", pk=pk)
        if action == "save_default":
            atid = request.POST.get("account_type_id")
            if atid and atid.isdigit():
                live_id = request.POST.get("live_mt5_group_id") or ""
                demo_id = request.POST.get("demo_mt5_group_id") or ""
                live_g = MT5Group.objects.filter(id=live_id).first() if live_id.isdigit() else None
                demo_g = MT5Group.objects.filter(id=demo_id).first() if demo_id.isdigit() else None
                obj, _ = IBLevelAccountTypeDefault.objects.update_or_create(
                    ib_level=level,
                    account_type_id=int(atid),
                    defaults={"live_mt5_group": live_g, "demo_mt5_group": demo_g},
                )
                messages.success(request, "Account type default saved.")
            return redirect("admin-ib-level-edit", pk=pk)
        if action == "delete_default":
            did = request.POST.get("default_id")
            if did:
                IBLevelAccountTypeDefault.objects.filter(id=did, ib_level=level).delete()
            return redirect("admin-ib-level-edit", pk=pk)

        data = _parse_level_post(request)
        if not data["name"]:
            messages.error(request, "Level name is required.")
        else:
            clash = IBLevel.objects.filter(name__iexact=data["name"]).exclude(pk=level.pk).exists()
            if clash:
                messages.error(request, "Another level uses this name.")
            else:
                dl = None
                if data["downgrade_to_level_id"].isdigit():
                    cand = IBLevel.objects.filter(id=int(data["downgrade_to_level_id"])).first()
                    if cand and cand.id != level.id:
                        dl = cand
                level.name = data["name"]
                level.level_type = data["level_type"]
                level.sequence = data["sequence"]
                level.is_active = data["is_active"]
                level.metric_window = data["metric_window"]
                level.primary_progress_metric = data["primary_progress_metric"]
                level.target_lots = data["target_lots"]
                level.target_deposit = data["target_deposit"]
                level.min_referrals = data["min_referrals"]
                level.target_active_clients = data["target_active_clients"]
                level.commission_percentage = data["commission_percentage"]
                level.min_holding_period_seconds = data["min_holding_period_seconds"]
                level.cap_daily = data["cap_daily"]
                level.cap_weekly = data["cap_weekly"]
                level.cap_monthly = data["cap_monthly"]
                level.cap_per_trade = data["cap_per_trade"]
                level.downgrade_review_days = data["downgrade_review_days"]
                level.downgrade_grace_days = data["downgrade_grace_days"]
                level.downgrade_to_level = dl
                level.benefits = data["benefits"]
                level.save()
                messages.success(request, "IB Level updated.")
                return redirect("admin-ib-levels")

    rewards = level.rewards.all()
    defaults = level.account_type_defaults.select_related("account_type", "live_mt5_group", "demo_mt5_group")
    return render(
        request,
        "admin_panel/ib_level_form.html",
        {
            "mode": "edit",
            "level": level,
            "rewards": rewards,
            "account_defaults": defaults,
            "all_levels": IBLevel.objects.order_by("sequence"),
            "account_types": TradingAccountType.objects.filter(is_active=True).order_by("display_order", "account_name"),
            "mt5_groups": MT5Group.objects.filter(is_active=True).order_by("name")[:200],
            "level_types": IBLevel.LevelType.choices,
            "metric_windows": IBLevel.MetricWindow.choices,
            "progress_metrics": IBLevel.PrimaryProgressMetric.choices,
            "reward_kinds": IBLevelReward.RewardKind.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def ib_level_delete(request, pk: int):
    level = get_object_or_404(IBLevel, pk=pk)
    if IBProfile.objects.filter(ib_level=level).exists():
        messages.error(request, "Cannot delete: IB profiles are assigned to this level.")
        return redirect("admin-ib-levels")
    if IBLevelUpgradeRequest.objects.filter(to_level=level, status=IBLevelUpgradeRequest.Status.PENDING).exists():
        messages.error(request, "Cannot delete: pending upgrade requests reference this level.")
        return redirect("admin-ib-levels")
    level.delete()
    messages.success(request, "Level deleted.")
    return redirect("admin-ib-levels")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_level_approval_queue(request):
    if request.method == "POST":
        rid = request.POST.get("request_id")
        action = (request.POST.get("action") or "").strip().lower()
        req = IBLevelUpgradeRequest.objects.filter(id=rid).select_related("ib_user", "to_level", "from_level").first()
        if not req:
            messages.error(request, "Request not found.")
            return redirect("admin-ib-level-approval")
        if req.status != IBLevelUpgradeRequest.Status.PENDING:
            messages.warning(request, "Request already processed.")
            return redirect("admin-ib-level-approval")
        if action == "approve":
            prof = IBProfile.objects.filter(user=req.ib_user).first()
            if prof:
                prof.ib_level = req.to_level
                prof.save(update_fields=["ib_level"])
            req.status = IBLevelUpgradeRequest.Status.APPROVED
            req.processed_at = timezone.now()
            req.processed_by = request.user
            req.save(update_fields=["status", "processed_at", "processed_by"])
            messages.success(request, "Level upgrade approved.")
        elif action == "reject":
            req.status = IBLevelUpgradeRequest.Status.REJECTED
            req.processed_at = timezone.now()
            req.processed_by = request.user
            req.notes = (request.POST.get("notes") or req.notes or "")[:2000]
            req.save(update_fields=["status", "processed_at", "processed_by", "notes"])
            messages.success(request, "Request rejected.")
        return redirect("admin-ib-level-approval")

    pending = (
        IBLevelUpgradeRequest.objects.filter(status=IBLevelUpgradeRequest.Status.PENDING)
        .select_related("ib_user", "from_level", "to_level")
        .order_by("created_at")
    )
    recent = (
        IBLevelUpgradeRequest.objects.exclude(status=IBLevelUpgradeRequest.Status.PENDING)
        .select_related("ib_user", "from_level", "to_level", "processed_by")
        .order_by("-processed_at", "-id")[:30]
    )
    return render(
        request,
        "admin_panel/ib_level_approval.html",
        {"pending": pending, "recent": recent},
    )
