from __future__ import annotations

from decimal import Decimal

from django.db.models import Sum
from rest_framework.views import APIView

from admin_panel.models import CashbackPayout
from api.permissions import IsAuthenticatedClient
from api.responses import success_response


class ClientCashbackHistoryAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        try:
            limit = min(int(request.query_params.get("limit") or 100), 300)
        except (TypeError, ValueError):
            limit = 100
        qs = CashbackPayout.objects.filter(user=request.user).order_by("-created_at")[:limit]
        items = [
            {
                "engine_trade_id": row.engine_trade_id,
                "alias": row.alias,
                "amount": str(row.amount),
                "login_id": row.login_id,
                "created_at": row.created_at.isoformat(),
            }
            for row in qs
        ]
        all_total = CashbackPayout.objects.filter(user=request.user).aggregate(s=Sum("amount"))["s"] or Decimal("0")
        return success_response(
            {"items": items, "total": str(all_total)},
            message="Cashback history retrieved successfully.",
        )
