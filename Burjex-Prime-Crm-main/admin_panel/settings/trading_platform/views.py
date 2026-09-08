from django.contrib import messages
from django.shortcuts import redirect

from admin_panel import org_legal_platform_views


def trading_platform_settings(request):
    try:
        return org_legal_platform_views.trading_platform_settings_page(request)
    except Exception:
        messages.error(request, "Trading Platform settings are temporarily unavailable.")
        return redirect("admin-system-management-dashboard")

