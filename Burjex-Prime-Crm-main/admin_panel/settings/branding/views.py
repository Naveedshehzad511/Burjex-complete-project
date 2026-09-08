from django.contrib import messages
from django.shortcuts import redirect

from admin_panel import views as legacy_views


def branding_settings(request):
    try:
        return legacy_views.branding_logo(request)
    except Exception:
        messages.error(request, "Branding module is temporarily unavailable.")
        return redirect("admin-system-management-dashboard")

