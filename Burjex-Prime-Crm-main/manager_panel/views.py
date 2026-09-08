from __future__ import annotations

from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from django.shortcuts import render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from sales_panel.services.manager_target_metrics import compute_manager_target_progress

from .services.dashboard import build_manager_dashboard_context, manager_dashboard_api_payload


def _manager_ctx(nav: str) -> dict:
    return {"manager_nav_active": nav}


@login_required
@role_required([User.Roles.MANAGER])
@require_http_methods(["GET"])
def manager_dashboard(request):
    ctx = build_manager_dashboard_context(request.user)
    target_payload = compute_manager_target_progress(request.user, client_ids=None)
    return render(
        request,
        "manager_panel/dashboard.html",
        {
            **ctx,
            **_manager_ctx("dashboard"),
            "target_progress": target_payload,
        },
    )


@login_required
@role_required([User.Roles.MANAGER])
@require_http_methods(["GET"])
def manager_dashboard_api(request):
    payload = manager_dashboard_api_payload(request.user)
    resp = JsonResponse(payload)
    resp["Cache-Control"] = "no-store"
    return resp
