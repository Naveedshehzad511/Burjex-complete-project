from __future__ import annotations

import logging
import uuid
from datetime import timedelta
from decimal import Decimal

from django.db import transaction as db_transaction
from django.db.models import Q, Sum
from django.utils import timezone
from rest_framework.views import APIView

from accounts.kyc_policy import kyc_blocks_internal_transfer
from accounts.models import MT5Account, User
from accounts.restrictions import restriction_for_user
from admin_panel.models import ComplianceSettings, TradingAccount, TransferTreasurySettings, WalletTreasurySettings
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response
from enterprise.audit import get_client_ip, log_audit
from enterprise.models import AuditLogChannel
from transactions.internal_transfer_execution import apply_internal_transfer_balances, validate_internal_transfer_route
from transactions.models import InternalTransfer
from transactions.real_ledger import filter_real_internal_transfers
from transactions.utils import ensure_unique_action
from user_portal.views import _ib_wallet_balance_for_user, _internal_transfer_blocked_message, _wallet_balance_for_user

logger = logging.getLogger(__name__)


def _serialize_trading_account_option(row: TradingAccount) -> dict:
    mt5 = row.mt5_account
    return {
        "id": row.id,
        "account_number": row.account_number,
        "account_type": row.account_type,
        "currency": row.currency,
        "balance": str(mt5.balance if mt5 else row.balance),
        "free_margin": str(mt5.free_margin if mt5 else 0),
        "from_account_key": f"TRADING:{row.id}",
    }


def _serialize_internal_transfer(row: InternalTransfer) -> dict:
    return {
        "id": row.id,
        "transfer_type": row.transfer_type,
        "from_account": row.from_account,
        "to_account": row.to_account,
        "amount": str(row.amount),
        "status": row.status,
        "note": row.note or "",
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "processed_at": row.processed_at.isoformat() if row.processed_at else None,
    }


class InternalTransferAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        r = restriction_for_user(request.user)
        ws = WalletTreasurySettings.get_solo()
        ts = TransferTreasurySettings.get_solo()

        blocked_reason = None
        if not ws.wallet_system_enabled:
            blocked_reason = "Wallet is not available."
        elif not ts.internal_transfers_enabled:
            blocked_reason = "Internal transfers are disabled."
        elif ts.internal_maintenance_mode:
            blocked_reason = "Internal transfer temporarily unavailable."
        elif r and r.disable_internal_transfer:
            blocked_reason = "Internal transfers are disabled for your account. Please contact support."

        tt = InternalTransfer.TransferType
        transfer_types = []
        if ws.allow_wallet_to_trading:
            transfer_types.append(tt.WALLET_TO_TRADING)
        if ws.allow_trading_to_wallet:
            transfer_types.append(tt.TRADING_TO_WALLET)
        transfer_types.append(tt.TRADING_TO_TRADING)
        if ws.allow_p2p_transfers:
            transfer_types.append(tt.IB_TO_TRADING)
            transfer_types.append(tt.IB_TO_WALLET)

        try:
            from btrader_integration.services import is_btrader_configured, sync_user_btrader_accounts

            if is_btrader_configured():
                sync_user_btrader_accounts(request.user)
        except Exception:
            pass

        trading_accounts = TradingAccount.objects.filter(
            user=request.user,
            status=TradingAccount.Status.ACTIVE,
            mt5_account__account_type=MT5Account.AccountType.LIVE,
        ).select_related("mt5_account").order_by("-created_at")

        history_qs = filter_real_internal_transfers(
            InternalTransfer.objects.filter(user=request.user).order_by("-created_at"),
            request.user,
        )

        return success_response(
            {
                "allowed": blocked_reason is None,
                "block_reason": blocked_reason,
                "transfer_types": transfer_types,
                "trading_accounts": [_serialize_trading_account_option(a) for a in trading_accounts],
                "wallet_balance": str(_wallet_balance_for_user(request.user)),
                "ib_wallet_balance": str(_ib_wallet_balance_for_user(request.user)),
                "history": [_serialize_internal_transfer(h) for h in history_qs[:100]],
                "request_uid": uuid.uuid4().hex,
                "settings": {
                    "internal_min_amount": str(ts.internal_min_amount),
                    "internal_max_amount": str(ts.internal_max_amount),
                    "internal_daily_limit": str(ts.internal_daily_limit),
                    "internal_cooldown_minutes": ts.internal_cooldown_minutes,
                    "transfer_max_pending": ts.transfer_max_pending,
                    "processing_mode": ts.internal_processing_mode,
                },
                "preselect_from": (request.query_params.get("from_account") or "").strip(),
            },
            message="Internal transfer options retrieved successfully.",
        )

    def post(self, request):
        r = restriction_for_user(request.user)
        ws = WalletTreasurySettings.get_solo()
        ts = TransferTreasurySettings.get_solo()

        if not ws.wallet_system_enabled:
            return error_response("Wallet is not available.")
        if not ts.internal_transfers_enabled:
            return error_response("Internal transfers are disabled.")
        if ts.internal_maintenance_mode:
            return error_response("Internal transfer temporarily unavailable.")
        if r and r.disable_internal_transfer:
            return error_response("Internal transfers are disabled for your account. Please contact support.")

        tt = InternalTransfer.TransferType
        transfer_types = []
        if ws.allow_wallet_to_trading:
            transfer_types.append(tt.WALLET_TO_TRADING)
        if ws.allow_trading_to_wallet:
            transfer_types.append(tt.TRADING_TO_WALLET)
        transfer_types.append(tt.TRADING_TO_TRADING)
        if ws.allow_p2p_transfers:
            transfer_types.append(tt.IB_TO_TRADING)
            transfer_types.append(tt.IB_TO_WALLET)

        transfer_type = request.data.get("transfer_type") or ""
        from_account = request.data.get("from_account") or ""
        to_account = request.data.get("to_account") or ""
        amount_raw = request.data.get("amount") or "0"
        request_uid = (request.data.get("request_uid") or "").strip()

        try:
            amount = Decimal(amount_raw)
        except Exception:
            amount = Decimal("0")

        if transfer_type not in transfer_types:
            return error_response("Invalid transfer type.")

        def _trading_row_kind(tid: int):
            row = (
                TradingAccount.objects.select_related("mt5_account")
                .filter(id=tid, user=request.user, status=TradingAccount.Status.ACTIVE)
                .first()
            )
            if not row or not row.mt5_account:
                return None
            return row.mt5_account.account_type

        for acct_str in (from_account, to_account):
            if not str(acct_str).startswith("TRADING:"):
                continue
            try:
                tid = int(str(acct_str).split(":", 1)[1])
            except Exception:
                tid = 0
            k = _trading_row_kind(tid)
            if k == MT5Account.AccountType.DEMO:
                return error_response("Demo accounts cannot send or receive internal transfers.")

        blocked_msg = _internal_transfer_blocked_message(r, transfer_type)
        if blocked_msg:
            return error_response(blocked_msg)
        if amount <= 0:
            return error_response("Amount must be greater than zero.")
        if not request_uid:
            return error_response("Invalid transfer token.")

        route_err = validate_internal_transfer_route(transfer_type, from_account, to_account)
        if route_err:
            return error_response(route_err)

        compliance_settings = ComplianceSettings.get_solo()
        if kyc_blocks_internal_transfer(request.user, compliance_settings):
            return error_response("KYC approval is required before internal transfers.", status=403)

        if ts.internal_min_amount > 0 and amount < ts.internal_min_amount:
            return error_response(f"Minimum transfer amount is {ts.internal_min_amount}.")
        if ts.internal_max_amount > 0 and amount > ts.internal_max_amount:
            return error_response(f"Maximum transfer amount is {ts.internal_max_amount}.")

        if transfer_type in {tt.TRADING_TO_WALLET, tt.TRADING_TO_TRADING} and str(from_account).startswith(
            "TRADING:"
        ):
            try:
                acc_id = int(str(from_account).split(":", 1)[1])
            except Exception:
                acc_id = 0
            src = (
                TradingAccount.objects.select_related("mt5_account")
                .filter(
                    id=acc_id,
                    user=request.user,
                    status=TradingAccount.Status.ACTIVE,
                    mt5_account__account_type=MT5Account.AccountType.LIVE,
                )
                .first()
            )
            if not src or not src.mt5_account:
                return error_response("Source trading account not found.")
            from btrader_integration.services import validate_trading_debit_amount

            debit_err = validate_trading_debit_amount(src, amount)
            if debit_err:
                return error_response(debit_err)
            # Refresh serializer-facing free_margin after live sync inside validator.
            src.mt5_account.refresh_from_db()

        if ts.internal_daily_limit > 0:
            today_sum = (
                InternalTransfer.objects.filter(
                    user=request.user,
                    created_at__date=timezone.localdate(),
                    status=InternalTransfer.Status.APPROVED,
                ).aggregate(s=Sum("amount"))["s"]
                or 0
            )
            if Decimal(str(today_sum)) + amount > ts.internal_daily_limit:
                return error_response("Daily internal transfer limit reached.")

        if ts.internal_cooldown_minutes > 0:
            last_it = InternalTransfer.objects.filter(user=request.user).order_by("-created_at").first()
            if last_it and last_it.created_at + timedelta(minutes=ts.internal_cooldown_minutes) > timezone.now():
                return error_response("Please wait before submitting another transfer.")

        if ts.transfer_max_pending > 0:
            pend_n = InternalTransfer.objects.filter(
                user=request.user, status=InternalTransfer.Status.PENDING
            ).count()
            if pend_n >= ts.transfer_max_pending:
                return error_response("Maximum pending transfers reached.")

        try:
            ensure_unique_action(f"TRANSFER_{request_uid}", "INTERNAL_TRANSFER")
        except ValueError as e:
            return error_response(str(e))

        if ts.internal_processing_mode == TransferTreasurySettings.ProcessingMode.MANUAL:
            try:
                with db_transaction.atomic():
                    locked_user = User.objects.select_for_update().get(id=request.user.id)
                    if InternalTransfer.objects.select_for_update().filter(
                        user=locked_user,
                        note__icontains=request_uid,
                    ).exists():
                        return error_response("Duplicate transfer blocked.")
                    it = InternalTransfer.objects.create(
                        user=locked_user,
                        transfer_type=transfer_type,
                        from_account=from_account,
                        to_account=to_account,
                        amount=amount,
                        status=InternalTransfer.Status.PENDING,
                        note=f"request_uid={request_uid}",
                    )
            except Exception:
                logger.exception("Internal transfer pending create failed")
                return error_response("Transfer request failed. Please try again.")

            log_audit(
                action="INTERNAL_TRANSFER_PENDING",
                entity_type="InternalTransfer",
                entity_id=str(it.id),
                actor=request.user,
                channel=AuditLogChannel.CLIENT,
                request=request,
                ip=get_client_ip(request),
                metadata={"amount": str(amount), "type": transfer_type},
            )
            return success_response(
                {"transfer": _serialize_internal_transfer(it), "pending_approval": True},
                message="Transfer submitted for admin approval.",
                status=201,
            )

        try:
            with db_transaction.atomic():
                locked_user = User.objects.select_for_update().get(id=request.user.id)
                if InternalTransfer.objects.select_for_update().filter(
                    user=locked_user,
                    note__icontains=request_uid,
                ).exists():
                    return error_response("Duplicate transfer blocked.")

                duplicate_cutoff = timezone.now() - timedelta(seconds=8)
                duplicate_exists = InternalTransfer.objects.filter(
                    user=locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    status=InternalTransfer.Status.APPROVED,
                    created_at__gte=duplicate_cutoff,
                ).exists()
                if duplicate_exists:
                    return error_response("Duplicate transfer detected. Please wait a moment.")

                err = apply_internal_transfer_balances(
                    locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    request_uid=request_uid,
                )
                if err:
                    return error_response(err)

                row = InternalTransfer.objects.create(
                    user=locked_user,
                    transfer_type=transfer_type,
                    from_account=from_account,
                    to_account=to_account,
                    amount=amount,
                    status=InternalTransfer.Status.APPROVED,
                    processed_at=timezone.now(),
                    processed_by=locked_user,
                    note=f"request_uid={request_uid}",
                )
                if row.amount <= 0:
                    raise ValueError("Transfer verification failed")
        except Exception:
            logger.exception("Internal transfer auto processing failed")
            return error_response("Transfer failed. Please try again.")

        log_audit(
            action="INTERNAL_TRANSFER_COMPLETED",
            entity_type="InternalTransfer",
            entity_id=str(row.id),
            actor=request.user,
            channel=AuditLogChannel.CLIENT,
            request=request,
            ip=get_client_ip(request),
            metadata={"amount": str(amount), "type": transfer_type},
        )
        return success_response(
            {"transfer": _serialize_internal_transfer(row), "pending_approval": False},
            message="Transfer completed successfully.",
            status=201,
        )
