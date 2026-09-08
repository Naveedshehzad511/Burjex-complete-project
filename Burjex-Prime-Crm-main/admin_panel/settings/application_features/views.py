from decimal import Decimal

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render

from accounts.models import User
from accounts.permissions import role_required
from admin_panel import views as legacy_views
from admin_panel.models import UserActivitySettings


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def application_features_hub(request):
    cards = [
        {"title": "Dashboard Settings", "url_name": "admin-dashboard-settings"},
        {"title": "Sidebar UI", "url_name": "admin-sidebar-settings"},
        {"title": "Signup Fields", "url_name": "admin-signup-fields-settings"},
        {"title": "Email Verification", "url_name": "admin-email-verification-settings"},
        {"title": "User Settings", "url_name": "admin-user-settings"},
        {"title": "Compliance Settings", "url_name": "admin-compliance-settings"},
    ]
    if request.GET.get("saved"):
        messages.success(request, "Application features updated.")
    return render(request, "settings/application_features/index.html", {"cards": cards})


def dashboard_settings(request):
    try:
        return legacy_views.dashboard_settings(request)
    except Exception:
        messages.error(request, "Dashboard settings are temporarily unavailable.")
        return redirect("admin-settings-application-features")


def sidebar_settings(request):
    try:
        return legacy_views.sidebar_settings(request)
    except Exception:
        messages.error(request, "Sidebar settings are temporarily unavailable.")
        return redirect("admin-settings-application-features")


def signup_fields(request):
    try:
        return legacy_views.signup_fields_settings(request)
    except Exception:
        messages.error(request, "Signup fields settings are temporarily unavailable.")
        return redirect("admin-settings-application-features")


def email_verification(request):
    try:
        return legacy_views.email_verification_settings_view(request)
    except Exception:
        messages.error(request, "Email verification settings are temporarily unavailable.")
        return redirect("admin-settings-application-features")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def user_settings(request):
    s = UserActivitySettings.get_solo()
    if request.method == "POST":
        try:
            s.active_days = max(int(request.POST.get("active_days") or 15), 1)
        except (TypeError, ValueError):
            s.active_days = 15
        try:
            s.min_balance = Decimal(request.POST.get("min_balance") or "1.00")
        except Exception:
            s.min_balance = Decimal("1.00")
        if s.min_balance < 0:
            s.min_balance = Decimal("0.00")
        # Keep legacy preset fields loosely in sync for any old reads
        ad = s.active_days
        if ad in (7, 15, 30):
            s.active_period_preset = str(ad)
        else:
            s.active_period_preset = UserActivitySettings.ActivePeriodPreset.CUSTOM
            s.custom_active_days = ad
        s.save()
        messages.success(request, "User settings updated.")
        return redirect("admin-user-settings")
    return render(request, "settings/application_features/user_settings.html", {"s": s})

