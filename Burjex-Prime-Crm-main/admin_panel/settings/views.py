from django.contrib.auth.decorators import login_required
from django.shortcuts import render

from accounts.models import User
from accounts.permissions import role_required


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
def system_management_dashboard(request):
    cards = [
        {"title": "Email Templates", "url_name": "admin-system-email-templates"},
        {"title": "Integrations", "url_name": "admin-integrations-hub"},
        {"title": "Branding", "url_name": "admin-branding-logo"},
        {"title": "User Portal Theme", "url_name": "admin-user-portal-theme"},
        {"title": "Platform Information", "url_name": "admin-trading-platform-settings"},
        {"title": "Legal Agreements", "url_name": "admin-legal-agreements"},
    ]
    return render(request, "system_management/dashboard.html", {"cards": cards})

