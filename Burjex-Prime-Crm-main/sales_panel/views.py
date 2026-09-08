import re

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import HttpResponseNotFound, JsonResponse
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods, require_POST

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.services.sales_dashboard import get_sales_dashboard_context
from admin_panel.services.sales_enterprise import (
    export_ib_detail_csv,
    get_ib_analytics_context,
    get_ib_detail_context,
    get_sales_main_context,
    get_sales_team_context,
)
from enterprise.models import AuditLog, AuditLogChannel
from marketing.models import Lead, SalesFunnelContactLog, SalesFunnelVisitor
from sales_panel.services.sales_funnel import (
    STAGE_ORDER,
    build_funnel_cards,
    client_is_dropped,
    funnel_counts_and_profit,
    get_or_create_funnel_profile,
    get_stage_list,
    recent_contact_logs,
    row_tone_for_stage,
)
from sales_panel.services.crm_scoping import (
    clients_qs_for_sales_user,
    leads_qs_for_sales_user,
    visitors_qs_for_sales_user,
)
from sales_panel.services.manager_target_metrics import compute_manager_target_progress
from sales_panel.services.sales_funnel_enrichment import first_deposit_by_user_ids, first_live_mt5_by_user


def _sales_ctx(nav_key: str) -> dict:
    return {"sales_nav_active": nav_key}


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_dashboard(request):
    """Main Sales Dashboard (company-level); keep Manager/Department dashboards separate."""
    u = request.user
    sm = u if u.is_sales_manager() else None
    funnel_cards = build_funnel_cards(sales_user=sm)
    counts, _, v_drop, c_drop = funnel_counts_and_profit(sales_user=sm)

    if u.is_sales_manager():
        mt_payload = compute_manager_target_progress(u)
        ctx = {
            "sales_date_from": "",
            "sales_date_to": "",
            "kpi_total_revenue": 0.0,
            "kpi_total_loss": 0.0,
            "kpi_net_profit": 0.0,
            "kpi_net_positive": True,
            "kpi_trading_volume": 0.0,
            "kpi_active_ibs": 0,
            "kpi_total_clients": 0,
            "pending_orange": {"deposits": 0, "withdrawals": 0, "ib_requests": 0},
            "chart_revenue_dw": {"labels": [], "deposits": [], "withdrawals": []},
            "chart_volume": {"labels": [], "values": []},
            "chart_net": {"labels": [], "values": []},
            "chart_ib": {"labels": [], "withdrawals": [], "transfers": []},
            "sales_activity": {},
            "sales_conversion_rate": "—",
            "sales_total_leads": None,
            "sales_manager_mode": True,
            "manager_target": mt_payload,
        }
    else:
        ctx = get_sales_main_context(request)
        legacy = get_sales_dashboard_context()
        ctx.update(
            {
                "sales_activity": legacy.get("activity"),
                "sales_conversion_rate": legacy.get("conversion_rate"),
                "sales_total_leads": legacy.get("total_leads"),
                "sales_manager_mode": False,
                "manager_target": {"has_target": False, "ok": True},
            }
        )
    ctx.update(
        {
            "funnel_cards": funnel_cards,
            "funnel_chart_labels": [c["title"] for c in funnel_cards],
            "funnel_chart_counts": [c["count"] for c in funnel_cards],
            "funnel_stage_conv": [c["conversion_to_next"] for c in funnel_cards],
            "funnel_dropped_visitors": v_drop,
            "funnel_dropped_clients": c_drop,
        }
    )
    ctx.update(_sales_ctx("dashboard"))
    return render(request, "sales_panel/dashboard.html", ctx)


@login_required
@role_required([User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_manager_target_progress_api(request):
    """JSON for live progress updates (polling)."""
    return JsonResponse(compute_manager_target_progress(request.user))


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_ib_analytics(request):
    ctx = get_ib_analytics_context(request)
    ctx.update(_sales_ctx("ib_analytics"))
    return render(request, "sales_panel/ib_analytics.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_ib_detail(request, ib_id: int):
    ctx = get_ib_detail_context(ib_id, request)
    if not ctx:
        return HttpResponseNotFound("IB not found")
    ctx.update(_sales_ctx("ib_analytics"))
    return render(request, "sales_panel/ib_detail.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_ib_detail_export_csv(request, ib_id: int):
    resp = export_ib_detail_csv(ib_id, request)
    return resp or HttpResponseNotFound("IB not found")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_ib_detail_export_excel(request, ib_id: int):
    resp = export_ib_detail_csv(ib_id, request)
    if not resp:
        return HttpResponseNotFound("IB not found")
    resp["Content-Type"] = "application/vnd.ms-excel"
    resp["Content-Disposition"] = f'attachment; filename="ib_sales_{ib_id}.xls"'
    return resp


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_ib_detail_export_pdf(request, ib_id: int):
    ctx = get_ib_detail_context(ib_id, request)
    if not ctx:
        return HttpResponseNotFound("IB not found")
    return render(request, "sales_panel/ib_detail_pdf.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_team(request):
    ctx = get_sales_team_context(request)
    ctx.update(_sales_ctx("sales_team"))
    return render(request, "sales_panel/sales_team.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_revenue_hub(request):
    ctx = get_sales_main_context(request)
    ctx.update(_sales_ctx("revenue"))
    return render(request, "sales_panel/hub_revenue.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_performance_hub(request):
    ctx = get_sales_main_context(request)
    ctx.update(_sales_ctx("performance"))
    return render(request, "sales_panel/hub_performance_sales.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_leads(request):
    leads = (
        leads_qs_for_sales_user(request.user)
        .select_related("campaign", "assigned_to")
        .order_by("-created_at")[:200]
    )
    return render(
        request,
        "sales_panel/leads.html",
        {**_sales_ctx("leads"), "leads": leads},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_clients(request):
    clients = (
        clients_qs_for_sales_user(request.user)
        .order_by("-date_joined")
        .only("id", "email", "first_name", "last_name", "date_joined", "is_active", "account_status")[:200]
    )
    return render(
        request,
        "sales_panel/clients.html",
        {**_sales_ctx("clients"), "clients": clients},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_follow_ups(request):
    leads = (
        leads_qs_for_sales_user(request.user)
        .filter(status=Lead.Status.QUALIFIED)
        .select_related("campaign", "assigned_to")
        .order_by("-created_at")[:200]
    )
    return render(
        request,
        "sales_panel/follow_ups.html",
        {**_sales_ctx("followups"), "leads": leads},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_conversions(request):
    leads = (
        leads_qs_for_sales_user(request.user)
        .filter(status=Lead.Status.CONVERTED)
        .select_related("campaign", "assigned_to")
        .order_by("-created_at")[:200]
    )
    return render(
        request,
        "sales_panel/conversions.html",
        {**_sales_ctx("conversions"), "leads": leads},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_reports_hub(request):
    return render(
        request,
        "sales_panel/hub_sales_reports.html",
        _sales_ctx("reports"),
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_targets(request):
    return render(
        request,
        "sales_panel/placeholder.html",
        {
            **_sales_ctx("targets"),
            "placeholder_title": "Targets",
            "placeholder_body": "Set and track sales targets. Full configuration will connect to CRM goals and KPIs.",
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_commission_hub(request):
    return render(
        request,
        "sales_panel/hub_commission.html",
        _sales_ctx("commission"),
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_activity_log(request):
    logs = AuditLog.objects.filter(channel__in=[AuditLogChannel.ADMIN, AuditLogChannel.STAFF]).order_by(
        "-created_at"
    )[:150]
    return render(
        request,
        "sales_panel/activity_log.html",
        {**_sales_ctx("activity"), "logs": logs},
    )


def _assignable_staff_qs(for_user: User | None = None):
    qs = User.objects.filter(
        role__in=[User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER],
        is_active=True,
    ).order_by("first_name", "last_name", "email")
    if for_user and for_user.is_sales_manager():
        return qs.filter(pk=for_user.pk)
    return qs


def _whatsapp_url(phone: str) -> str:
    digits = re.sub(r"\D", "", phone or "")
    return f"https://wa.me/{digits}" if digits else ""


def _parse_staff_id(request, raw: str | None) -> int | None:
    if not raw:
        return None
    try:
        pk = int(raw)
    except ValueError:
        return None
    if not _assignable_staff_qs(request.user).filter(pk=pk).exists():
        return None
    return pk


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_funnel_hub(request):
    sm = request.user if request.user.is_sales_manager() else None
    cards = build_funnel_cards(sales_user=sm)
    _, _, v_drop, c_drop = funnel_counts_and_profit(sales_user=sm)
    return render(
        request,
        "sales_panel/funnel.html",
        {
            **_sales_ctx("funnel"),
            "funnel_cards": cards,
            "funnel_chart_labels": [c["title"] for c in cards],
            "funnel_chart_counts": [c["count"] for c in cards],
            "funnel_stage_conv": [c["conversion_to_next"] for c in cards],
            "funnel_dropped_visitors": v_drop,
            "funnel_dropped_clients": c_drop,
            "funnel_logs": recent_contact_logs(30, sales_user=sm),
            "assignable_staff": _assignable_staff_qs(request.user)[:200],
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_http_methods(["GET"])
def sales_funnel_stage(request, stage_key: str):
    if stage_key not in STAGE_ORDER:
        return HttpResponseNotFound("Unknown funnel stage")
    sm = request.user if request.user.is_sales_manager() else None
    rows, title = get_stage_list(stage_key, sales_user=sm)
    staff = _assignable_staff_qs(request.user)[:200]
    enriched: list[dict] = []

    if stage_key == "visitors":
        for v in rows:
            enriched.append(
                {
                    "kind": "visitor",
                    "visitor": v,
                    "tone": row_tone_for_stage(stage_key, v.is_dropped),
                    "whatsapp_url": _whatsapp_url(v.phone),
                }
            )
    else:
        users = rows
        dep_map = {}
        if stage_key in ("deposit", "active"):
            dep_map = first_deposit_by_user_ids(u.id for u in users)
        mt5_map = first_live_mt5_by_user(users)
        for u in users:
            dropped = client_is_dropped(u)
            tone = row_tone_for_stage(stage_key, dropped)
            extra: dict = {}
            if stage_key in ("deposit", "active"):
                t = dep_map.get(u.id)
                extra["deposit_amount"] = t.amount if t else None
                extra["deposit_currency"] = t.currency if t else "USD"
                extra["deposit_date"] = t.created_at if t else None
            a = mt5_map.get(u.id)
            extra["mt5_login"] = a.login_id if a else None
            extra["mt5_type"] = a.get_account_type_display() if a else None
            profile = getattr(u, "sales_funnel_profile", None)
            extra["assigned_manager"] = profile.assigned_manager if profile else None
            extra["assigned_agent"] = profile.assigned_agent if profile else None
            extra["assigned_manager_id"] = profile.assigned_manager_id if profile else None
            extra["assigned_agent_id"] = profile.assigned_agent_id if profile else None
            extra["last_contact_at"] = profile.last_contact_at if profile else None
            extra["internal_notes"] = profile.internal_notes if profile else ""
            extra["whatsapp_url"] = _whatsapp_url(u.phone or "")
            enriched.append({"kind": "client", "user": u, "tone": tone, **extra})

    return render(
        request,
        "sales_panel/funnel_stage.html",
        {
            **_sales_ctx(f"funnel_{stage_key}"),
            "stage_key": stage_key,
            "stage_title": title,
            "rows": enriched,
            "assignable_staff": staff,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER, User.Roles.SALES_MANAGER])
@require_POST
def sales_funnel_action(request):
    action = (request.POST.get("action") or "").strip()
    note = (request.POST.get("note") or "").strip()
    next_url = request.POST.get("next") or reverse("sales-funnel")
    vid = request.POST.get("visitor_id")
    uid = request.POST.get("user_id")

    def touch_visitor(v: SalesFunnelVisitor, channel: str, body: str = "") -> None:
        SalesFunnelContactLog.objects.create(
            visitor=v,
            channel=channel,
            body=body or note,
            created_by=request.user,
        )
        v.last_contact_at = timezone.now()
        v.last_contacted_by = request.user
        v.save(update_fields=["last_contact_at", "last_contacted_by"])

    def touch_client(u: User, channel: str, body: str = "") -> None:
        profile = get_or_create_funnel_profile(u)
        SalesFunnelContactLog.objects.create(
            client=u,
            channel=channel,
            body=body or note,
            created_by=request.user,
        )
        profile.last_contact_at = timezone.now()
        profile.last_contacted_by = request.user
        profile.save(update_fields=["last_contact_at", "last_contacted_by"])

    try:
        if vid:
            v = SalesFunnelVisitor.objects.get(pk=int(vid))
        else:
            v = None
    except (ValueError, SalesFunnelVisitor.DoesNotExist):
        v = None

    try:
        if uid:
            client = User.objects.get(pk=int(uid), role=User.Roles.CLIENT)
        else:
            client = None
    except (ValueError, User.DoesNotExist):
        client = None

    if not v and not client:
        messages.error(request, "Missing or invalid lead.")
        return redirect(next_url)

    ru = request.user
    if ru.is_sales_manager():
        if v and not visitors_qs_for_sales_user(ru).filter(pk=v.pk).exists():
            messages.error(request, "You cannot modify this record.")
            return redirect(next_url)
        if client and not clients_qs_for_sales_user(ru).filter(pk=client.pk).exists():
            messages.error(request, "You cannot modify this record.")
            return redirect(next_url)

    if action == "log_call":
        if v:
            touch_visitor(v, SalesFunnelContactLog.Channel.CALL)
        else:
            touch_client(client, SalesFunnelContactLog.Channel.CALL)  # type: ignore[arg-type]
        messages.success(request, "Call logged.")
    elif action == "log_email":
        if v:
            touch_visitor(v, SalesFunnelContactLog.Channel.EMAIL)
        else:
            touch_client(client, SalesFunnelContactLog.Channel.EMAIL)  # type: ignore[arg-type]
        messages.success(request, "Email contact logged.")
    elif action == "log_whatsapp":
        if v:
            touch_visitor(v, SalesFunnelContactLog.Channel.WHATSAPP)
        else:
            touch_client(client, SalesFunnelContactLog.Channel.WHATSAPP)  # type: ignore[arg-type]
        messages.success(request, "WhatsApp contact logged.")
    elif action == "save_note":
        if not note:
            messages.warning(request, "Add note text before saving.")
            return redirect(next_url)
        if v:
            touch_visitor(v, SalesFunnelContactLog.Channel.NOTE, note)
        else:
            touch_client(client, SalesFunnelContactLog.Channel.NOTE, note)  # type: ignore[arg-type]
        if client:
            prof = get_or_create_funnel_profile(client)
            prof.internal_notes = (prof.internal_notes + "\n" + note).strip()[:8000]
            prof.save(update_fields=["internal_notes"])
        messages.success(request, "Note saved.")
    elif action == "assign_manager":
        mid = _parse_staff_id(request, request.POST.get("manager_id"))
        if mid is None:
            messages.error(request, "Invalid manager.")
            return redirect(next_url)
        if request.user.is_sales_manager() and mid != request.user.pk:
            messages.error(request, "You may only assign yourself as manager.")
            return redirect(next_url)
        if v:
            v.assigned_manager_id = mid
            v.save(update_fields=["assigned_manager_id"])
            touch_visitor(v, SalesFunnelContactLog.Channel.ASSIGN, f"Assigned manager id={mid}")
        else:
            prof = get_or_create_funnel_profile(client)  # type: ignore[arg-type]
            prof.assigned_manager_id = mid
            prof.save(update_fields=["assigned_manager_id"])
            touch_client(client, SalesFunnelContactLog.Channel.ASSIGN, f"Assigned manager id={mid}")  # type: ignore[arg-type]
        messages.success(request, "Manager assigned.")
    elif action == "assign_agent":
        aid = _parse_staff_id(request, request.POST.get("agent_id"))
        if aid is None:
            messages.error(request, "Invalid agent.")
            return redirect(next_url)
        if request.user.is_sales_manager() and aid != request.user.pk:
            messages.error(request, "You may only assign yourself as agent.")
            return redirect(next_url)
        if v:
            v.assigned_agent_id = aid
            v.save(update_fields=["assigned_agent_id"])
            touch_visitor(v, SalesFunnelContactLog.Channel.ASSIGN, f"Assigned agent id={aid}")
        else:
            prof = get_or_create_funnel_profile(client)  # type: ignore[arg-type]
            prof.assigned_agent_id = aid
            prof.save(update_fields=["assigned_agent_id"])
            touch_client(client, SalesFunnelContactLog.Channel.ASSIGN, f"Assigned agent id={aid}")  # type: ignore[arg-type]
        messages.success(request, "Agent assigned.")
    elif action == "mark_dropped":
        if v:
            v.is_dropped = True
            v.save(update_fields=["is_dropped"])
            touch_visitor(v, SalesFunnelContactLog.Channel.NOTE, note or "Marked as dropped")
        else:
            prof = get_or_create_funnel_profile(client)  # type: ignore[arg-type]
            prof.is_dropped = True
            prof.dropped_at = timezone.now()
            prof.dropped_reason = note[:500] if note else ""
            prof.save(update_fields=["is_dropped", "dropped_at", "dropped_reason"])
            touch_client(client, SalesFunnelContactLog.Channel.NOTE, note or "Marked as dropped")  # type: ignore[arg-type]
        messages.success(request, "Marked as dropped.")
    elif action == "clear_dropped":
        if v:
            v.is_dropped = False
            v.save(update_fields=["is_dropped"])
            touch_visitor(v, SalesFunnelContactLog.Channel.NOTE, "Dropped status cleared")
        else:
            prof = get_or_create_funnel_profile(client)  # type: ignore[arg-type]
            prof.is_dropped = False
            prof.dropped_at = None
            prof.dropped_reason = ""
            prof.save(update_fields=["is_dropped", "dropped_at", "dropped_reason"])
            touch_client(client, SalesFunnelContactLog.Channel.NOTE, "Dropped status cleared")  # type: ignore[arg-type]
        messages.success(request, "Dropped status cleared.")
    else:
        messages.error(request, "Unknown action.")

    return redirect(next_url)

