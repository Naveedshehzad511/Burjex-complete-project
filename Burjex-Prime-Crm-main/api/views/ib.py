from __future__ import annotations

import re
from decimal import Decimal

from django.db import transaction as db_transaction
from django.db.models import Sum
from django.urls import reverse
from rest_framework.views import APIView

from accounts.kyc_policy import kyc_blocks_ib_request
from accounts.models import MT5Account, User
from admin_panel.models import ComplianceSettings
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response, validation_error_response
from enterprise.staff_notify import broadcast_staff_notification
from ib.models import IBApplicationQuestion, IBPlan, IBProfile, IBRequest, ProcessedMT5Deal
from ib.referral import build_register_referral_url, ensure_profile_referral_url
from transactions.models import Transaction
from transactions.real_ledger import filter_real_ledger_transactions
from user_portal.views import _ib_wallet_balance_for_user, _team_client_ids


def _decimal_str(x, *, is_int=False):
    if x is None:
        return "0"
    v = Decimal(str(x))
    if is_int:
        return str(v.to_integral_value())
    return f"{v:.2f}"


class IBDashboardAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        from django.utils import timezone

        user = request.user
        now = timezone.localtime(timezone.now())
        month_start = now.date().replace(day=1)
        team_ids = _team_client_ids(user)
        team_tx = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor_id__in=team_ids,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        )
        monthly_commission = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=user,
                    tx_type=Transaction.TxType.IB_WITHDRAW,
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                    created_at__date__gte=month_start,
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )
        total_commission = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=user,
                    tx_type=Transaction.TxType.IB_WITHDRAW,
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )
        ib_profile = IBProfile.objects.filter(user=user).first()
        if ib_profile and user.role == User.Roles.IB and not (ib_profile.ib_code or "").strip():
            ensure_profile_referral_url(request, ib_profile)
            ib_profile.save(update_fields=["ib_code", "referral_link"])

        referral_link = ""
        if ib_profile and (ib_profile.ib_code or "").strip():
            referral_link = build_register_referral_url(request, ib_profile.ib_code)

        pending_ib = IBRequest.objects.filter(client_user=user, status=IBRequest.Status.PENDING).first()
        live_qs = MT5Account.objects.filter(user_id__in=team_ids, account_type=MT5Account.AccountType.LIVE)
        team_dep = team_tx.filter(
            tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
        ).aggregate(total=Sum("amount"))["total"] or Decimal("0")
        team_wdr = team_tx.filter(
            tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
        ).aggregate(total=Sum("amount"))["total"] or Decimal("0")

        ib_wallet_available = _ib_wallet_balance_for_user(user)
        ib_wallet_pending = (
            Transaction.objects.filter(
                actor=user,
                tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
                status=Transaction.Status.PENDING,
            ).aggregate(total=Sum("amount"))["total"]
            or Decimal("0")
        )

        return success_response(
            {
                "month_name": now.strftime("%B %Y"),
                "monthly_commission": str(monthly_commission),
                "total_commission": str(total_commission),
                "total_clients": len(team_ids),
                "ib_profile": {
                    "id": ib_profile.id,
                    "ib_code": ib_profile.ib_code if ib_profile else "",
                    "referral_link": referral_link,
                    "link_clicks": ib_profile.link_clicks if ib_profile else 0,
                }
                if ib_profile
                else None,
                "pending_application": bool(pending_ib),
                "live_accounts_total": live_qs.count(),
                "live_accounts_active": live_qs.filter(status=MT5Account.Status.ACTIVE).count(),
                "team_deposits": str(team_dep),
                "team_withdrawals": str(team_wdr),
                "team_net": str(team_dep - team_wdr),
                "ib_wallet_available": str(ib_wallet_available),
                "ib_wallet_pending": str(ib_wallet_pending),
                "referral_registrations": len(team_ids),
                "referral_kyc_approved": User.objects.filter(
                    id__in=team_ids, kyc_status=User.KYCStatus.APPROVED
                ).count(),
                "referral_depositors": Transaction.objects.filter(
                    actor_id__in=team_ids,
                    tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
                .values_list("actor_id", flat=True)
                .distinct()
                .count(),
                "referral_active_traders": ProcessedMT5Deal.objects.filter(
                    login_id__in=MT5Account.objects.filter(user_id__in=team_ids).values_list(
                        "login_id", flat=True
                    )
                )
                .values_list("login_id", flat=True)
                .distinct()
                .count(),
            },
            message="IB dashboard retrieved successfully.",
        )


class IBProgressAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        from ib.level_progress import build_ib_portal_progress, refresh_referral_count

        refresh_referral_count(request.user)
        data = build_ib_portal_progress(request.user)
        if not data:
            return success_response({"available": False}, message="IB progress not available.")

        is_ref = data["primary_label"] == "Referrals"
        return success_response(
            {
                "available": True,
                "progress_percent": data["progress_percent"],
                "primary_label": data["primary_label"],
                "current_value": _decimal_str(data["current_value"], is_int=is_ref),
                "required_value": _decimal_str(data["required_value"], is_int=is_ref),
                "remaining_value": _decimal_str(data["remaining_value"], is_int=is_ref),
                "lots_cur": _decimal_str(data.get("lots_cur")),
                "lots_req": _decimal_str(data.get("lots_req")),
                "lots_pct": data.get("lots_pct", 100),
                "dep_cur": _decimal_str(data.get("dep_cur")),
                "dep_req": _decimal_str(data.get("dep_req")),
                "dep_pct": data.get("dep_pct", 100),
                "refs_cur": _decimal_str(data.get("refs_cur"), is_int=True),
                "refs_req": _decimal_str(data.get("refs_req"), is_int=True),
                "refs_pct": data.get("refs_pct", 100),
                "commission_rate": data["commission_rate"],
                "next_reward_title": data["next_reward_title"],
                "next_reward_remaining_label": data["next_reward_remaining_label"],
                "current_level": data["current_level"].name if data["current_level"] else "",
                "next_level": data["next_level"].name if data["next_level"] else "",
                "at_top_tier": data["next_level"] is None,
            },
            message="IB progress retrieved successfully.",
        )


class IBApplyAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        if kyc_blocks_ib_request(request.user, ComplianceSettings.get_solo()):
            return error_response(
                "KYC approval is required before you can apply for the IB programme.",
                status=403,
            )
        if IBProfile.objects.filter(user=request.user).exists():
            return error_response("You are already registered as an IB.", status=400)
        if IBRequest.objects.filter(client_user=request.user, status=IBRequest.Status.PENDING).exists():
            return error_response("You already have a pending IB application.", status=400)

        questions = IBApplicationQuestion.objects.filter(is_active=True).order_by("sort_order")
        return success_response(
            {
                "questions": [
                    {
                        "id": q.id,
                        "label": q.label,
                        "input_type": q.input_type,
                        "choices": q.choice_lines(),
                        "required": q.required,
                    }
                    for q in questions
                ]
            },
            message="IB application form retrieved successfully.",
        )

    def post(self, request):
        if kyc_blocks_ib_request(request.user, ComplianceSettings.get_solo()):
            return error_response(
                "KYC approval is required before you can apply for the IB programme.",
                status=403,
            )
        if IBProfile.objects.filter(user=request.user).exists():
            return error_response("You are already registered as an IB.", status=400)
        if IBRequest.objects.filter(client_user=request.user, status=IBRequest.Status.PENDING).exists():
            return error_response("You already have a pending IB application.", status=400)

        questions = IBApplicationQuestion.objects.filter(is_active=True).order_by("sort_order")
        application_data = {}
        missing_required = False

        for q in questions:
            field_name = f"question_{q.id}"
            if q.input_type == IBApplicationQuestion.InputType.MULTI:
                ans = request.data.getlist(field_name) if hasattr(request.data, "getlist") else []
                if not ans and field_name in request.data:
                    val = request.data.get(field_name)
                    ans = val if isinstance(val, list) else [val] if val else []
                answer_val = ", ".join(str(a) for a in ans if a) if ans else ""
            else:
                answer_val = (request.data.get(field_name) or "").strip()
            application_data[q.label] = answer_val
            if q.required and not answer_val:
                missing_required = True

        if missing_required:
            return validation_error_response({}, message="Please complete all required fields.")

        plan = IBPlan.objects.filter(is_active=True).order_by("id").first()
        full_name = (request.user.display_name() or "").strip()
        email = (getattr(request.user, "email", None) or "").strip()
        country = (getattr(request.user, "country", None) or "").strip()

        with db_transaction.atomic():
            req = IBRequest.objects.create(
                ib_user=request.user,
                client_user=request.user,
                plan=plan,
                status=IBRequest.Status.PENDING,
                full_name=full_name,
                email=email,
                trading_account="",
                country=country,
                notes="IB application (dynamic form)",
                application_data=application_data,
            )
            try:
                ib_tok = f"[ib_request:{req.id}]"
                broadcast_staff_notification(
                    "New IB request",
                    f"{ib_tok} {full_name} ({email}) submitted an IB application.",
                    action_url=reverse("admin-ib-requests"),
                    dedupe_body_contains=ib_tok,
                )
            except Exception:
                pass

        return success_response(
            {"request_id": req.id},
            message="IB application submitted successfully.",
            status=201,
        )


class IBClientsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        team_ids = _team_client_ids(request.user)
        clients = User.objects.filter(id__in=team_ids).order_by("id")
        rows = []
        LOT_RE = re.compile(r"lots=([\d.]+)", re.I)

        for c in clients:
            dep = (
                filter_real_ledger_transactions(
                    Transaction.objects.filter(
                        actor=c,
                        tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                    )
                ).aggregate(total=Sum("amount"))["total"]
                or 0
            )
            wdr = (
                filter_real_ledger_transactions(
                    Transaction.objects.filter(
                        actor=c,
                        tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW],
                        status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                    )
                ).aggregate(total=Sum("amount"))["total"]
                or 0
            )
            payouts = filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=request.user,
                    from_user=c,
                    tx_type=Transaction.TxType.IB_WITHDRAW,
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            )
            client_comm = payouts.aggregate(total=Sum("amount"))["total"] or Decimal("0")
            client_lots = Decimal("0")
            for tx in payouts:
                m = LOT_RE.search(tx.notes or "")
                if m:
                    try:
                        client_lots += Decimal(m.group(1))
                    except Exception:
                        pass
            mt5 = MT5Account.objects.filter(user=c).order_by("-updated_at").first()
            rows.append(
                {
                    "client_id": c.id,
                    "email": c.email,
                    "name": c.display_name(),
                    "country": c.country,
                    "kyc_status": c.kyc_status,
                    "mt5_login": mt5.login_id if mt5 else None,
                    "lots": str(client_lots),
                    "commission": str(client_comm),
                    "deposit": str(dep),
                    "withdraw": str(wdr),
                }
            )

        return success_response(
            {
                "clients": rows,
                "summary": {
                    "commission": str(sum(Decimal(r["commission"]) for r in rows)),
                    "deposit": str(sum(Decimal(r["deposit"]) for r in rows)),
                    "withdraw": str(sum(Decimal(r["withdraw"]) for r in rows)),
                    "lot": str(sum(Decimal(r["lots"]) for r in rows)),
                },
            },
            message="IB clients retrieved successfully.",
        )


class IBCommissionAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        limit = min(int(request.query_params.get("limit") or 50), 200)
        qs = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type=Transaction.TxType.IB_WITHDRAW,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
            .select_related("from_user", "payment_gateway")
            .order_by("-created_at")[:limit]
        )
        transactions = [
            {
                "id": tx.id,
                "reference": tx.reference,
                "amount": str(tx.amount),
                "currency": tx.currency,
                "status": tx.status,
                "notes": tx.notes or "",
                "from_client_id": tx.from_user_id,
                "from_client_email": tx.from_user.email if tx.from_user else None,
                "created_at": tx.created_at.isoformat() if tx.created_at else None,
            }
            for tx in qs
        ]
        total = sum(Decimal(t["amount"]) for t in transactions)
        return success_response(
            {"transactions": transactions, "total": str(total), "count": len(transactions)},
            message="IB commission transactions retrieved successfully.",
        )
