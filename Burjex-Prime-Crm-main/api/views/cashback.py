from __future__ import annotations

from datetime import datetime, time, timedelta
from decimal import Decimal, ROUND_HALF_UP

from django.db.models import Sum
from django.utils import timezone
from django.utils.dateparse import parse_date
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from admin_panel.cashback import cashback_is_enabled
from admin_panel.models import CashbackPayout
from api.permissions import IsAuthenticatedClient
from api.responses import success_response
from user_portal.views import _wallet_balance_for_user

_CENT = Decimal("0.01")


def _money(val) -> str:
    return str((val or Decimal("0")).quantize(_CENT, rounding=ROUND_HALF_UP))


def _period_bounds(request):
    period = (request.query_params.get("period") or "30d").strip().lower()
    now = timezone.now()
    local_now = timezone.localtime(now)
    start = None
    end = None
    if period in {"today", "tdy"}:
        period = "today"
        start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif period in {"7d", "7", "last7", "last_7_days"}:
        period = "7d"
        start = now - timedelta(days=7)
    elif period in {"30d", "30", "last30", "last_30_days"}:
        period = "30d"
        start = now - timedelta(days=30)
    elif period == "custom":
        dfrom = parse_date((request.query_params.get("date_from") or "").strip())
        dto = parse_date((request.query_params.get("date_to") or "").strip())
        tz = timezone.get_current_timezone()
        if dfrom:
            start = timezone.make_aware(datetime.combine(dfrom, time.min), tz)
        if dto:
            end = timezone.make_aware(datetime.combine(dto, time.max), tz)
        if start and end and end < start:
            start, end = end, start
    elif period == "all":
        period = "all"
    else:
        period = "30d"
        start = now - timedelta(days=30)
    return period, start, end


class ClientCashbackSettingsAPIView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        return success_response(
            {"enabled": cashback_is_enabled()},
            message="Cashback settings retrieved successfully.",
        )


class ClientCashbackHistoryAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        enabled = cashback_is_enabled()
        all_total = CashbackPayout.objects.filter(user=request.user).aggregate(s=Sum("amount"))["s"] or Decimal("0")
        if not enabled:
            return success_response(
                {
                    "enabled": False,
                    "items": [],
                    "total": _money(all_total),
                    "period": "30d",
                    "wallet_balance": _money(_wallet_balance_for_user(request.user)),
                },
                message="Cashback is disabled.",
            )
        try:
            limit = min(int(request.query_params.get("limit") or 100), 300)
        except (TypeError, ValueError):
            limit = 100
        period, start, end = _period_bounds(request)
        qs = CashbackPayout.objects.filter(user=request.user)
        if start is not None:
            qs = qs.filter(created_at__gte=start)
        if end is not None:
            qs = qs.filter(created_at__lte=end)
        items = [
            {
                "alias": row.alias,
                "amount": _money(row.amount),
                "created_at": row.created_at.isoformat(),
            }
            for row in qs.order_by("-created_at")[:limit]
        ]
        return success_response(
            {
                "enabled": True,
                "items": items,
                "total": _money(all_total),
                "period": period,
                "wallet_balance": _money(_wallet_balance_for_user(request.user)),
            },
            message="Cashback history retrieved successfully.",
        )
