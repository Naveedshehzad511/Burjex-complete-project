"""Thin JSON wrappers for sales / manager portal dashboards."""

from __future__ import annotations

from rest_framework.views import APIView

from api.permissions import IsManagerPortalUser, IsSalesPortalUser
from api.responses import success_response
from manager_panel.services.dashboard import manager_dashboard_api_payload
from sales_panel.services.manager_target_metrics import compute_manager_target_progress


class SalesDashboardAPIView(APIView):
    permission_classes = [IsSalesPortalUser]

    def get(self, request):
        return success_response(
            {
                "manager_target": compute_manager_target_progress(request.user),
            },
            message="Sales dashboard retrieved successfully.",
        )


class ManagerDashboardAPIView(APIView):
    permission_classes = [IsManagerPortalUser]

    def get(self, request):
        return success_response(
            manager_dashboard_api_payload(request.user),
            message="Manager dashboard retrieved successfully.",
        )
