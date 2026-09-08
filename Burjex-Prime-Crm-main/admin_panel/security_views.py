from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.models import MaintenanceSettings, OrganizationProfileSettings


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def maintenance_settings_page(request):
    settings_obj = MaintenanceSettings.get_solo()
    if request.method == "POST":
        settings_obj.enabled = request.POST.get("enabled") == "on"
        settings_obj.secret_bypass_key = (request.POST.get("secret_bypass_key") or "").strip()
        settings_obj.title = (request.POST.get("title") or "System Under Maintenance").strip()
        settings_obj.message = (
            request.POST.get("message")
            or "We are currently performing scheduled maintenance. Please check back shortly."
        ).strip()
        settings_obj.estimated_time = (request.POST.get("estimated_time") or "").strip()
        settings_obj.support_email = (request.POST.get("support_email") or "").strip()
        settings_obj.allow_whitelist_ip = request.POST.get("allow_whitelist_ip") == "on"
        settings_obj.whitelist_ips = (request.POST.get("whitelist_ips") or "").strip()
        settings_obj.save()
        messages.success(request, "Maintenance settings saved.")
        return redirect("admin-maintenance-settings")
    return render(request, "admin_panel/maintenance_settings.html", {"settings_obj": settings_obj})


@require_http_methods(["GET"])
def maintenance_page(request):
    settings_obj = MaintenanceSettings.get_solo()
    org = OrganizationProfileSettings.get_solo()
    return render(
        request,
        "maintenance.html",
        {
            "settings_obj": settings_obj,
            "org": org,
        },
    )

