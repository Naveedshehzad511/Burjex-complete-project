from __future__ import annotations

import logging

from django.core.paginator import Paginator
from django.db.models import Q
from rest_framework.views import APIView

from accounts.models import User
from accounts.restrictions import get_or_create_restriction
from admin_panel.services.dashboard_live import get_live_dashboard_kpis
from admin_panel.user_management_views import _crm_user_list_qs, _wallet_balances
from api.permissions import IsStaffUser
from api.responses import not_found_response, success_response
from api.serializers.common import UserSerializer
from transactions.models import PaymentGateway, Transaction

logger = logging.getLogger(__name__)


def _serialize_admin_user(u: User, wallet_map: dict | None = None) -> dict:
    wallet = wallet_map.get(u.id, float(u.wallet_balance or 0)) if wallet_map else float(u.wallet_balance or 0)
    return {
        "id": u.id,
        "email": u.email,
        "name": u.display_name(),
        "first_name": u.first_name,
        "last_name": u.last_name,
        "kyc_status": u.kyc_status,
        "wallet_balance": str(wallet),
        "account_status": u.account_status,
        "role": u.role,
        "country": u.country,
        "is_active": u.is_active,
        "date_joined": u.date_joined.isoformat() if u.date_joined else None,
        "last_login": u.last_login.isoformat() if u.last_login else None,
    }


def _serialize_transaction(tx: Transaction) -> dict:
    return {
        "id": tx.id,
        "reference": tx.reference,
        "tx_type": tx.tx_type,
        "amount": str(tx.amount),
        "currency": tx.currency,
        "status": tx.status,
        "notes": tx.notes or "",
        "account_details": tx.account_details or "",
        "actor_id": tx.actor_id,
        "actor_email": tx.actor.email if tx.actor else None,
        "actor_name": tx.actor.display_name() if tx.actor else None,
        "payment_gateway": tx.payment_gateway.name if tx.payment_gateway else None,
        "created_at": tx.created_at.isoformat() if tx.created_at else None,
        "processed_at": tx.processed_at.isoformat() if tx.processed_at else None,
    }


class AdminDashboardStatsAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request):
        try:
            payload = get_live_dashboard_kpis()
        except Exception:
            logger.exception("Admin dashboard stats API failed")
            payload = {
                "total_users": User.objects.exclude(
                    role__in=[User.Roles.ADMIN, User.Roles.BANKER]
                ).count(),
                "active_users": User.objects.filter(is_active=True).exclude(
                    role__in=[User.Roles.ADMIN, User.Roles.BANKER]
                ).count(),
                "total_live_accounts": 0,
                "total_demo_accounts": 0,
                "total_deposit": 0.0,
                "total_withdrawal": 0.0,
                "today_deposit": 0.0,
                "today_withdrawal": 0.0,
                "error": True,
            }
        return success_response(payload, message="Dashboard stats retrieved successfully.")


class AdminUserListAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request):
        q = (request.query_params.get("q") or "").strip()
        page = max(int(request.query_params.get("page") or 1), 1)
        page_size = min(max(int(request.query_params.get("page_size") or 25), 1), 100)

        users_qs = _crm_user_list_qs().select_related("referred_by")
        if q:
            users_qs = users_qs.filter(
                Q(first_name__icontains=q)
                | Q(last_name__icontains=q)
                | Q(email__icontains=q)
                | Q(phone__icontains=q)
                | Q(country__icontains=q)
            )

        paginator = Paginator(users_qs.order_by("-date_joined"), page_size)
        page_obj = paginator.get_page(page)
        user_ids = [u.id for u in page_obj.object_list]
        wallet_map = _wallet_balances(user_ids)

        return success_response(
            {
                "users": [_serialize_admin_user(u, wallet_map) for u in page_obj.object_list],
                "pagination": {
                    "page": page_obj.number,
                    "page_size": page_size,
                    "total_pages": paginator.num_pages,
                    "total_count": paginator.count,
                    "has_next": page_obj.has_next(),
                    "has_previous": page_obj.has_previous(),
                },
            },
            message="Users retrieved successfully.",
        )


class AdminUserDetailAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request, pk: int):
        user = _crm_user_list_qs().select_related("referred_by", "ib_linked_by").filter(pk=pk).first()
        if not user:
            return not_found_response("User not found.")

        wallet_map = _wallet_balances([user.id])
        restriction = get_or_create_restriction(user)
        data = UserSerializer(user, context={"request": request}).data
        data["computed_wallet_balance"] = str(wallet_map.get(user.id, float(user.wallet_balance or 0)))
        data["restrictions"] = {
            f.name: getattr(restriction, f.name)
            for f in restriction._meta.fields
            if f.name not in ("id", "user")
        }
        return success_response(data, message="User retrieved successfully.")


class AdminPendingDepositsAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request):
        deposit_types = [
            Transaction.TxType.PENDING_DEPOSIT,
            Transaction.TxType.CLIENT_DEPOSIT,
            Transaction.TxType.WALLET_DEPOSIT,
        ]
        qs = (
            Transaction.objects.select_related("actor", "payment_gateway")
            .filter(tx_type__in=deposit_types, status=Transaction.Status.PENDING)
            .order_by("-created_at")
        )
        email = (request.query_params.get("email") or "").strip()
        if email:
            qs = qs.filter(actor__email__icontains=email)
        limit = min(int(request.query_params.get("limit") or 50), 200)
        rows = list(qs[:limit])
        return success_response(
            {
                "transactions": [_serialize_transaction(tx) for tx in rows],
                "count": len(rows),
            },
            message="Pending deposits retrieved successfully.",
        )


class AdminPendingWithdrawalsAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request):
        withdraw_types = [
            Transaction.TxType.PENDING_WITHDRAW,
            Transaction.TxType.CLIENT_WITHDRAW,
            Transaction.TxType.WALLET_WITHDRAW,
            Transaction.TxType.PENDING_IB_WITHDRAW,
            Transaction.TxType.IB_WITHDRAW,
        ]
        qs = (
            Transaction.objects.select_related("actor", "payment_gateway")
            .filter(tx_type__in=withdraw_types, status=Transaction.Status.PENDING)
            .order_by("-created_at")
        )
        email = (request.query_params.get("email") or "").strip()
        if email:
            qs = qs.filter(actor__email__icontains=email)
        limit = min(int(request.query_params.get("limit") or 50), 200)
        rows = list(qs[:limit])
        return success_response(
            {
                "transactions": [_serialize_transaction(tx) for tx in rows],
                "count": len(rows),
            },
            message="Pending withdrawals retrieved successfully.",
        )


class AdminTransactionListAPIView(APIView):
    permission_classes = [IsStaffUser]

    def get(self, request):
        qs = Transaction.objects.select_related("actor", "payment_gateway").order_by("-created_at")

        status = (request.query_params.get("status") or "").strip().upper()
        tx_type = (request.query_params.get("tx_type") or "").strip().upper()
        email = (request.query_params.get("email") or "").strip()
        q = (request.query_params.get("q") or "").strip()

        if status in {c for c, _ in Transaction.Status.choices}:
            qs = qs.filter(status=status)
        if tx_type in {c for c, _ in Transaction.TxType.choices}:
            qs = qs.filter(tx_type=tx_type)
        if email:
            qs = qs.filter(actor__email__icontains=email)
        if q:
            qs = qs.filter(Q(reference__icontains=q) | Q(notes__icontains=q))

        page = max(int(request.query_params.get("page") or 1), 1)
        page_size = min(max(int(request.query_params.get("page_size") or 25), 1), 100)
        paginator = Paginator(qs, page_size)
        page_obj = paginator.get_page(page)

        return success_response(
            {
                "transactions": [_serialize_transaction(tx) for tx in page_obj.object_list],
                "filters": {
                    "status_choices": [c for c, _ in Transaction.Status.choices],
                    "tx_type_choices": [c for c, _ in Transaction.TxType.choices],
                    "gateways": list(
                        PaymentGateway.objects.filter(is_active=True).order_by("name").values("id", "name")
                    ),
                },
                "pagination": {
                    "page": page_obj.number,
                    "page_size": page_size,
                    "total_pages": paginator.num_pages,
                    "total_count": paginator.count,
                    "has_next": page_obj.has_next(),
                    "has_previous": page_obj.has_previous(),
                },
            },
            message="Transactions retrieved successfully.",
        )
