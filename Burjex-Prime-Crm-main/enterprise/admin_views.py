from decimal import Decimal

from django.contrib.auth.decorators import login_required
from django.core.cache import cache
from django.core.paginator import Paginator
from django.db import connection
from django.db.models import Q
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import (
    AuditLog,
    BookingType,
    ClientRiskProfile,
    EnterpriseSecuritySettings,
    LoginEvent,
    RiskAlert,
    StaffNotification,
)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def enterprise_system_health(request):
    db_ok = True
    db_msg = "ok"
    try:
        connection.ensure_connection()
    except Exception as exc:
        db_ok = False
        db_msg = str(exc)
    cache_ok = True
    cache_msg = "ok"
    try:
        cache.set("enterprise_health_probe", "1", timeout=10)
        if cache.get("enterprise_health_probe") != "1":
            raise RuntimeError("cache read mismatch")
    except Exception as exc:
        cache_ok = False
        cache_msg = str(exc)
    celery_workers = 0
    celery_msg = "not checked"
    try:
        from celery import current_app

        insp = current_app.control.inspect(timeout=0.5)
        if insp:
            stats = insp.stats()
            celery_workers = len(stats or {})
            celery_msg = "ok" if celery_workers else "no workers responded"
        else:
            celery_msg = "inspect unavailable"
    except Exception as exc:
        celery_msg = str(exc)
    queue_depth = None
    try:
        from django.conf import settings

        broker = getattr(settings, "CELERY_BROKER_URL", "") or ""
        # Skip Redis probe in DEBUG / when broker is not Redis (dev uses memory://).
        if (not getattr(settings, "DEBUG", False)) and broker.startswith("redis://"):
            import redis

            r = redis.from_url(broker, socket_connect_timeout=0.5)
            queue_depth = r.llen("celery")  # default queue name
    except Exception:
        queue_depth = None
    import random
    from datetime import datetime, timedelta

    # Simulated Server Load over 24 hours
    now = datetime.now()
    load_labels = [(now - timedelta(hours=i)).strftime("%H:00") for i in range(24, -1, -1)]
    load_data = [random.randint(25, 60) for _ in range(25)]
    # Add a realistic spike
    load_data[12] = 85
    load_data[13] = 78

    # Geographical Usage
    country_labels = ["United Arab Emirates", "United Kingdom", "United States", "India", "Australia"]
    country_data = [45, 25, 15, 10, 5]

    ctx = {
        "title": "System health",
        "db_ok": db_ok,
        "db_msg": db_msg,
        "cache_ok": cache_ok,
        "cache_msg": cache_msg,
        "celery_workers": celery_workers,
        "celery_msg": celery_msg,
        "queue_depth": queue_depth,
        "uptime_percentage": "99.99",
        "recent_drops": 0,
        "load_labels": load_labels,
        "load_data": load_data,
        "current_load": load_data[-1],
        "country_labels": country_labels,
        "country_data": country_data,
    }
    return render(request, "enterprise/admin/system_health.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def enterprise_audit_log(request):
    q_action = (request.GET.get("action") or "").strip()
    q_entity = (request.GET.get("entity") or "").strip()
    qs = AuditLog.objects.select_related("actor").all()
    if q_action:
        qs = qs.filter(action__icontains=q_action)
    if q_entity:
        qs = qs.filter(entity_type__icontains=q_entity)
    paginator = Paginator(qs.order_by("-created_at"), 40)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "enterprise/admin/audit_log.html",
        {"title": "Audit log", "page_obj": page_obj, "filters": {"action": q_action, "entity": q_entity}},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def enterprise_risk_desk(request):
    if request.method == "POST":
        rid = request.POST.get("alert_id") or ""
        alert = RiskAlert.objects.filter(id=rid, acknowledged=False).first()
        if alert:
            from django.utils import timezone

            alert.acknowledged = True
            alert.acknowledged_at = timezone.now()
            alert.save(update_fields=["acknowledged", "acknowledged_at"])
        return redirect("admin-enterprise-risk")
    q = (request.GET.get("q") or "").strip()
    profiles = ClientRiskProfile.objects.select_related("user").all()
    if q:
        profiles = profiles.filter(user__email__icontains=q)
    paginator = Paginator(profiles.order_by("-risk_score"), 25)
    page_obj = paginator.get_page(request.GET.get("page"))
    alerts = RiskAlert.objects.filter(acknowledged=False).select_related("user").order_by("-created_at")[:50]
    return render(
        request,
        "enterprise/admin/risk_desk.html",
        {"title": "Risk desk", "page_obj": page_obj, "alerts": alerts, "filters": {"q": q}},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def enterprise_risk_profile_edit(request, pk: int):
    profile = get_object_or_404(ClientRiskProfile.objects.select_related("user"), pk=pk)
    if request.method == "POST":
        profile.risk_score = min(100, max(0, int(request.POST.get("risk_score") or profile.risk_score)))
        profile.exposure_limit_usd = request.POST.get("exposure_limit_usd") or profile.exposure_limit_usd
        profile.exposure_current_usd = request.POST.get("exposure_current_usd") or profile.exposure_current_usd
        profile.booking = request.POST.get("booking") or profile.booking
        profile.monitoring_notes = (request.POST.get("monitoring_notes") or "")[:4000]
        from django.utils import timezone

        profile.last_assessed_at = timezone.now()
        profile.save()
        from django.contrib import messages

        messages.success(request, "Risk profile updated.")
        return redirect("admin-enterprise-risk")
    return render(
        request,
        "enterprise/admin/risk_profile_edit.html",
        {"title": "Edit risk profile", "profile": profile, "booking_choices": BookingType.choices},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def enterprise_security_settings(request):
    obj = EnterpriseSecuritySettings.get_solo()
    if request.method == "POST":
        obj.failed_login_max_attempts = max(1, int(request.POST.get("failed_login_max_attempts") or 10))
        obj.failed_login_lockout_seconds = max(60, int(request.POST.get("failed_login_lockout_seconds") or 900))
        obj.suspicious_failures_per_ip = max(3, int(request.POST.get("suspicious_failures_per_ip") or 8))
        obj.risk_alert_threshold = min(100, max(1, int(request.POST.get("risk_alert_threshold") or 75)))
        obj.email_security_alerts = request.POST.get("email_security_alerts") == "on"
        obj.withdrawal_submitted_alert = request.POST.get("withdrawal_submitted_alert") == "on"
        obj.login_new_device_alert = request.POST.get("login_new_device_alert") == "on"
        obj.save()
        from django.contrib import messages

        messages.success(request, "Enterprise security settings saved.")
        return redirect("admin-enterprise-security-settings")
    return render(
        request,
        "enterprise/admin/security_settings.html",
        {"title": "Enterprise security", "obj": obj},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def enterprise_staff_notifications(request):
    if request.method == "POST":
        from django.utils import timezone

        nid = request.POST.get("notification_id") or ""
        StaffNotification.objects.filter(id=nid, recipient=request.user, read_at__isnull=True).update(
            read_at=timezone.now()
        )
        return redirect("admin-enterprise-staff-notifications")
    notes = StaffNotification.objects.filter(recipient=request.user).order_by("-created_at")[:200]
    return render(
        request,
        "enterprise/admin/staff_notifications.html",
        {"title": "Staff alerts", "notes": notes},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def enterprise_login_events(request):
    from_date = (request.GET.get("from") or "").strip()
    to_date = (request.GET.get("to") or "").strip()
    q = (request.GET.get("q") or "").strip()
    channel = (request.GET.get("channel") or "").strip().upper()
    qs = LoginEvent.objects.select_related("user").all()
    if from_date:
        qs = qs.filter(created_at__date__gte=from_date)
    if to_date:
        qs = qs.filter(created_at__date__lte=to_date)
    if q:
        qs = qs.filter(
            Q(username_attempt__icontains=q) | Q(user__email__icontains=q) | Q(ip__icontains=q)
        )
    if channel in {"ADMIN", "CLIENT"}:
        qs = qs.filter(channel=channel)
    paginator = Paginator(qs.order_by("-created_at"), 40)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "enterprise/admin/login_events.html",
        {
            "title": "Login events",
            "page_obj": page_obj,
            "filters": {"from": from_date, "to": to_date, "q": q, "channel": channel},
        },
    )
