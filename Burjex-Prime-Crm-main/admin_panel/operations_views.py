from datetime import timedelta

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Avg, Count, Q
from django.http import JsonResponse
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import (
    ComplianceIntegration,
    ComplianceLog,
    ComplianceOfficer,
    EmailProvider,
    EmailSettings,
    KYCRequest,
    SMSProvider,
    SMSSettings,
    SupportIntegration,
    SupportLog,
    SupportSettings,
)


def _ensure_defaults() -> None:
    for value, _ in ComplianceIntegration.Provider.choices:
        ComplianceIntegration.objects.get_or_create(provider=value)
    for value, _ in SupportIntegration.IntegrationType.choices:
        SupportIntegration.objects.get_or_create(integration_type=value)
    for value, _ in EmailProvider.Provider.choices:
        EmailProvider.objects.get_or_create(provider=value)
    for value, _ in SMSProvider.Provider.choices:
        SMSProvider.objects.get_or_create(provider=value)
    SupportSettings.get_solo()
    EmailSettings.get_solo()
    SMSSettings.get_solo()


# These support modules are intentionally hidden from the current customer-support flow.
# Keep the constants here so old database rows stay harmless instead of deleting data.
DISABLED_SUPPORT_INTEGRATIONS = ["CUSTOM_API", "EMAIL_SUPPORT", "LIVE_CHAT"]


def _active_support_rows():
    """Return only the support integrations that are allowed in the current admin UI."""
    return SupportIntegration.objects.exclude(
        # Disabled/commented support modules:
        # - Custom API Support (CUSTOM_API)
        # - Email Support (EMAIL_SUPPORT)
        # - Live Chat (LIVE_CHAT)
        integration_type__in=DISABLED_SUPPORT_INTEGRATIONS
    )


def _support_integration_missing_config(row: SupportIntegration) -> str:
    """Validate only the fields required by the currently enabled support integrations."""
    if row.integration_type == "WHATSAPP_DIRECT" and not row.phone_number:
        return "WhatsApp Direct needs a phone number before it can be active."
    if row.integration_type == "TAWK_TO" and not row.embed_code:
        return "Tawk.to needs embed code before it can be active."
    if row.integration_type == "ZOHO_SALESIQ" and not row.embed_script:
        return "Zoho SalesIQ needs embed script before it can be active."
    if row.integration_type == "ZOHO_SALESIQ" and "YOUR_WIDGET_CODE" in row.embed_script:
        return "Zoho SalesIQ needs the real widget code from Zoho, not the YOUR_WIDGET_CODE placeholder."
    return ""


def _enforce_single_active_support_integration() -> None:
    """Keep old/dirty data from showing more than one active support widget in the portal."""
    active_rows = list(
        _active_support_rows()
        .filter(enabled=True, status="ACTIVE")
        .order_by("-updated_at", "integration_type")
    )
    if len(active_rows) <= 1:
        return
    keep_id = active_rows[0].id
    _active_support_rows().filter(enabled=True, status="ACTIVE").exclude(id=keep_id).update(
        enabled=False,
        status="INACTIVE",
    )


def _compliance_dashboard_payload():
    now = timezone.now()
    d14 = now - timedelta(days=13)
    pending_qs = KYCRequest.objects.filter(status="PENDING_REVIEW")
    data = {
        "top_cards": {
            "pending_individual_kyc": pending_qs.filter(request_type=KYCRequest.RequestType.INDIVIDUAL).count(),
            "pending_corporate_kyc": pending_qs.filter(request_type=KYCRequest.RequestType.CORPORATE).count(),
            "partial_approved": KYCRequest.objects.filter(partial_approved=True).count(),
        },
        "main_stats": {
            "total_kyc": KYCRequest.objects.count(),
            "pending_review": pending_qs.count(),
            "fully_verified": KYCRequest.objects.filter(status="FULLY_VERIFIED").count(),
            "rejected": KYCRequest.objects.filter(status="REJECTED").count(),
        },
        "activity": {
            "today_activity": KYCRequest.objects.filter(last_activity_at__date=timezone.localdate()).count(),
            "fresh_lt_24h": KYCRequest.objects.filter(submitted_at__gte=now - timedelta(hours=24)).count(),
            "overdue_gt_3d": pending_qs.filter(submitted_at__lte=now - timedelta(days=3)).count(),
            "avg_processing_time": int(KYCRequest.objects.aggregate(v=Avg("processing_time_minutes"))["v"] or 0),
        },
    }
    enabled_officers = ComplianceOfficer.objects.filter(enabled=True)
    assigned = pending_qs.filter(assigned_officer__isnull=False).count()
    unassigned = pending_qs.filter(assigned_officer__isnull=True).count()
    data["team_workload"] = {
        "enabled_officers": enabled_officers.count(),
        "unassigned": unassigned,
        "assigned": assigned,
        "capacity": sum(o.max_capacity for o in enabled_officers),
    }

    labels = [(d14 + timedelta(days=i)).date().isoformat() for i in range(14)]
    submit_map = {
        d["day"].isoformat(): d["c"]
        for d in KYCRequest.objects.filter(submitted_at__gte=d14)
        .extra(select={"day": "date(submitted_at)"})
        .values("day")
        .annotate(c=Count("id"))
    }
    verify_map = {
        d["day"].isoformat(): d["c"]
        for d in KYCRequest.objects.filter(approved_at__gte=d14)
        .extra(select={"day": "date(approved_at)"})
        .values("day")
        .annotate(c=Count("id"))
    }
    data["trends"] = {
        "labels": labels,
        "submissions": [submit_map.get(k, 0) for k in labels],
        "verified": [verify_map.get(k, 0) for k in labels],
    }
    data["status_breakdown"] = {
        "fully_verified": data["main_stats"]["fully_verified"],
        "rejected": data["main_stats"]["rejected"],
        "pending": data["main_stats"]["pending_review"],
    }
    data["aging_distribution"] = {
        "lt_1d": pending_qs.filter(submitted_at__gte=now - timedelta(days=1)).count(),
        "d1_3": pending_qs.filter(submitted_at__lt=now - timedelta(days=1), submitted_at__gt=now - timedelta(days=3)).count(),
        "gt_3d": pending_qs.filter(submitted_at__lte=now - timedelta(days=3)).count(),
    }
    week_start = timezone.localdate() - timedelta(days=timezone.localdate().weekday())
    monthly_start = timezone.localdate().replace(day=1)
    prev_month_end = monthly_start - timedelta(days=1)
    prev_month_start = prev_month_end.replace(day=1)
    data["reports"] = {
        "this_week": {
            "new_submissions": KYCRequest.objects.filter(submitted_at__date__gte=week_start).count(),
            "approved": KYCRequest.objects.filter(approved_at__date__gte=week_start).count(),
            "rejected": KYCRequest.objects.filter(rejected_at__date__gte=week_start).count(),
        },
        "monthly_comparison": {
            "submissions_this_month": KYCRequest.objects.filter(submitted_at__date__gte=monthly_start).count(),
            "submissions_prev_month": KYCRequest.objects.filter(
                submitted_at__date__gte=prev_month_start, submitted_at__date__lte=prev_month_end
            ).count(),
            "verified_this_month": KYCRequest.objects.filter(approved_at__date__gte=monthly_start).count(),
            "verified_prev_month": KYCRequest.objects.filter(
                approved_at__date__gte=prev_month_start, approved_at__date__lte=prev_month_end
            ).count(),
        },
    }
    top = (
        ComplianceOfficer.objects.filter(enabled=True)
        .annotate(
            review_volume=Count("requests"),
            approved_count=Count("requests", filter=Q(requests__status="FULLY_VERIFIED")),
        )
        .order_by("-review_volume")[:5]
    )
    data["top_performers"] = [
        {
            "name": t.user.display_name() if t.user_id else f"Officer #{t.id}",
            "review_volume": t.review_volume,
            "approved": t.approved_count,
            "performance": round((t.approved_count / t.review_volume) * 100, 1) if t.review_volume else 0,
        }
        for t in top
    ]
    return data


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def compliance_desk(request):
    _ensure_defaults()
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        req = KYCRequest.objects.filter(id=request.POST.get("request_id")).first()
        if action in {"approve", "reject", "request_docs", "assign_officer", "set_priority"} and not req:
            messages.error(request, "KYC request not found.")
            return redirect("admin-compliance-desk")
        if action == "approve":
            req.status = "FULLY_VERIFIED"
            req.approved_at = timezone.now()
            req.save(update_fields=["status", "approved_at", "last_activity_at"])
        elif action == "reject":
            req.status = "REJECTED"
            req.rejected_at = timezone.now()
            req.rejection_reason = (request.POST.get("reason") or "").strip()
            req.save(update_fields=["status", "rejected_at", "rejection_reason", "last_activity_at"])
        elif action == "request_docs":
            req.status = "PENDING_DOCUMENTS"
            req.save(update_fields=["status", "last_activity_at"])
        elif action == "assign_officer":
            officer = ComplianceOfficer.objects.filter(id=request.POST.get("officer_id"), enabled=True).first()
            req.assigned_officer = officer
            req.save(update_fields=["assigned_officer", "last_activity_at"])
        elif action == "set_priority":
            pr = (request.POST.get("priority") or KYCRequest.Priority.NORMAL).upper()
            if pr in {c[0] for c in KYCRequest.Priority.choices}:
                req.priority = pr
                req.save(update_fields=["priority", "last_activity_at"])
        if req:
            ComplianceLog.objects.create(request=req, actor=request.user, action=action.upper(), details="Action from desk")
            messages.success(request, "Compliance action completed.")
        return redirect("admin-compliance-desk")

    payload = _compliance_dashboard_payload()
    context = {
        **payload,
        "recent_requests": KYCRequest.objects.select_related("user", "assigned_officer__user").order_by("-submitted_at")[:25],
        "officers": ComplianceOfficer.objects.select_related("user").filter(enabled=True).order_by("user__email"),
        "integrations": ComplianceIntegration.objects.order_by("provider"),
    }
    return render(request, "admin_panel/compliance_desk.html", context)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def compliance_desk_live(request):
    _ensure_defaults()
    return JsonResponse(_compliance_dashboard_payload())


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def support_integrations_admin(request):
    _ensure_defaults()
    _enforce_single_active_support_integration()
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        row = _active_support_rows().filter(id=request.POST.get("id")).first()
        settings = SupportSettings.get_solo()
        if action == "save_settings":
            settings.floating_button_enabled = request.POST.get("floating_button_enabled") == "on"
            settings.default_ticket_email = (request.POST.get("default_ticket_email") or "").strip()
            settings.save()
            messages.success(request, "Support settings saved.")
            return redirect("admin-support-integrations")
        if not row:
            messages.error(request, "Integration not found.")
            return redirect("admin-support-integrations")
        enable_requested = request.POST.get("enabled") == "on"

        # Current UI fields:
        # - WhatsApp uses phone_number and prefilled_message.
        # - Tawk.to uses embed_code.
        # - Zoho SalesIQ uses embed_script.
        row.phone_number = (request.POST.get("phone_number") or "").strip()
        row.prefilled_message = (request.POST.get("prefilled_message") or "").strip()

        if "embed_code" in request.POST:
            row.embed_code = request.POST.get("embed_code") or ""
        if "embed_script" in request.POST:
            row.embed_script = request.POST.get("embed_script") or ""
        missing_config = _support_integration_missing_config(row) if enable_requested else ""
        row.enabled = enable_requested and not missing_config
        row.status = "ACTIVE" if row.enabled else "INACTIVE"
        disabled_previous = False
        if row.enabled:
            # Only one customer support integration can be active at a time.
            disabled_previous = _active_support_rows().exclude(id=row.id).filter(enabled=True).exists()
            _active_support_rows().exclude(id=row.id).update(enabled=False, status="INACTIVE")
        row.save()
        SupportLog.objects.create(
            integration=row,
            user=request.user,
            action="UPDATE",
            status="OK",
            payload=f"enabled={row.enabled}",
        )
        if missing_config:
            messages.error(request, missing_config)
        elif disabled_previous:
            messages.success(
                request,
                "Support integration updated. Previous active support integration was disabled because only one can be active at a time.",
            )
        else:
            messages.success(request, "Support integration updated.")
        return redirect("admin-support-integrations")
    return render(
        request,
        "admin_panel/support_integrations.html",
        {
            "rows": _active_support_rows().order_by("integration_type"),
            "settings": SupportSettings.get_solo(),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def email_sms_management(request):
    _ensure_defaults()
    email_settings = EmailSettings.get_solo()
    sms_settings = SMSSettings.get_solo()
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "save_defaults":
            email_settings.default_provider_id = request.POST.get("default_email_provider") or None
            sms_settings.default_provider_id = request.POST.get("default_sms_provider") or None
            email_settings.save()
            sms_settings.save()
            messages.success(request, "Default providers updated.")
            return redirect("admin-email-sms")
        if action in {"test_email", "test_sms"}:
            messages.success(request, "Test request recorded successfully.")
            return redirect("admin-email-sms")
        if action in {"save_email_provider", "save_sms_provider"}:
            if action == "save_email_provider":
                row = EmailProvider.objects.filter(id=request.POST.get("id")).first()
                if not row:
                    messages.error(request, "Email provider not found.")
                    return redirect("admin-email-sms")
                row.enabled = request.POST.get("enabled") == "on"
                row.enable_integration = row.enabled
                row.is_active = request.POST.get("is_active") == "on"
                row.api_key = (request.POST.get("api_key") or "")[:2048]
                row.secret_key = request.POST.get("secret_key") or ""
                row.domain = request.POST.get("domain") or ""
                row.sender_email = request.POST.get("sender_email") or ""
                row.sender_name = request.POST.get("sender_name") or ""
                row.smtp_host = request.POST.get("smtp_host") or ""
                row.smtp_port = int(request.POST.get("smtp_port") or 587)
                row.username = request.POST.get("username") or ""
                row.password = request.POST.get("password") or ""
                row.encryption = request.POST.get("encryption") or "TLS"
                row.save()
            else:
                row = SMSProvider.objects.filter(id=request.POST.get("id")).first()
                if not row:
                    messages.error(request, "SMS provider not found.")
                    return redirect("admin-email-sms")
                row.enabled = request.POST.get("enabled") == "on"
                row.is_active = request.POST.get("is_active") == "on"
                row.api_key = request.POST.get("api_key") or ""
                row.sender_id = request.POST.get("sender_id") or ""
                row.sender_email = request.POST.get("sender_email") or ""
                row.api_url = request.POST.get("api_url") or ""
                row.account_sid = request.POST.get("account_sid") or ""
                row.auth_token = request.POST.get("auth_token") or ""
                row.phone_number = request.POST.get("phone_number") or ""
                row.save()
            messages.success(request, "Provider saved.")
            return redirect("admin-email-sms")
    return render(
        request,
        "admin_panel/email_sms_management.html",
        {
            "email_providers": EmailProvider.objects.order_by("provider"),
            "sms_providers": SMSProvider.objects.order_by("provider"),
            "email_settings": email_settings,
            "sms_settings": sms_settings,
        },
    )
