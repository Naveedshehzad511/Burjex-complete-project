from __future__ import annotations

import uuid

from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.views import APIView

from accounts.models import VerifiedBankAccount, VerifiedCryptoAddress
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response, validation_error_response
from api.services import treasury_service
from transactions.models import Transaction


class WalletAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        return success_response(treasury_service.wallet_summary(request.user), message="Wallet retrieved successfully.")


class DepositMethodsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        from admin_panel.models import TradingAccount
        from api.views.dashboard import _serialize_trading_account

        ok, msg = treasury_service.check_deposit_allowed(request.user)
        live_accounts = (
            TradingAccount.objects.filter(user=request.user)
            .select_related("mt5_account", "mt5_account__group")
            .order_by("-created_at")
        )
        deposit_targets = []
        for a in live_accounts:
            if a.base_account_type != "LIVE":
                continue
            mt5 = a.mt5_account
            if mt5 and not mt5.deposit_enabled:
                continue
            row = _serialize_trading_account(a)
            deposit_targets.append(row)
        from admin_panel.models import Match2PayIntegrationSettings

        m2p = Match2PayIntegrationSettings.get_solo()
        return success_response(
            {
                "allowed": ok,
                "block_reason": None if ok else msg,
                "gateways": treasury_service.deposit_gateways(),
                "trading_accounts": deposit_targets,
                "default_trading_account": request.query_params.get("trading_account") or "",
                "match2pay_enabled": bool(m2p.enabled),
                "crypto_networks": treasury_service.crypto_networks_for_gateway(),
            },
            message="Deposit methods retrieved successfully.",
        )


class DepositCreateAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def post(self, request):
        ok, result = treasury_service.create_manual_deposit(request.user, request.data, request.FILES)
        if not ok:
            if result.get("errors"):
                return validation_error_response(result["errors"], message=result.get("message", "Validation failed."))
            return error_response(result.get("message", "Deposit failed."), status=400)
        return success_response(result, message=result.get("message", "Deposit request submitted."), status=201)


class DepositCryptoAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def post(self, request):
        ok, result = treasury_service.create_crypto_deposit_session(request.user, request.data)
        if not ok:
            return error_response(result.get("message", "Crypto deposit failed."), status=400)
        return success_response(result, message=result.get("message", "Payment session generated."), status=201)


class WithdrawMethodsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        ok, msg = treasury_service.check_withdraw_allowed(request.user)
        banks = VerifiedBankAccount.objects.filter(
            user=request.user, status=VerifiedBankAccount.Status.APPROVED
        ).order_by("-created_at")
        cryptos = VerifiedCryptoAddress.objects.filter(
            user=request.user, status=VerifiedCryptoAddress.Status.APPROVED
        ).order_by("-created_at")
        bank_accounts = [
            {
                "id": b.id,
                "bank_name": b.bank_name,
                "account_name": b.account_name,
                "account_number": b.account_number,
                "iban": b.iban,
                "label": f"{b.bank_name} · {b.account_name}".strip(" ·"),
                "details": " · ".join(x for x in [b.account_number, b.iban] if x),
            }
            for b in banks
        ]
        crypto_addresses = [
            {
                "id": c.id,
                "wallet_name": c.wallet_name,
                "wallet_address": c.wallet_address,
                "network": c.network,
                "label": f"{c.network} · {c.wallet_name}".strip(" ·") or c.network,
                "details": c.wallet_address,
            }
            for c in cryptos
        ]
        gateways = treasury_service.withdraw_gateways()
        return success_response(
            {
                "allowed": ok,
                "block_reason": None if ok else msg,
                "gateways": gateways,
                "methods": self._methods(bank_accounts, crypto_addresses),
                "request_uid": uuid.uuid4().hex,
                "approved_bank_accounts": bank_accounts,
                "approved_crypto_addresses": crypto_addresses,
            },
            message="Withdrawal methods retrieved successfully.",
        )

    @staticmethod
    def _methods(bank_accounts, crypto_addresses):
        """Method + saved-KYC-account pairs so clients never re-enter payout details."""
        rows = []
        for key, label, accounts, empty_hint in (
            (
                "bank",
                "Bank Transfer",
                bank_accounts,
                "Add a bank account under KYC to withdraw by bank transfer.",
            ),
            (
                "crypto",
                "Crypto",
                crypto_addresses,
                "Add a crypto wallet under KYC to withdraw in crypto.",
            ),
        ):
            gateway = treasury_service.withdraw_gateway_for_method(key)
            rows.append(
                {
                    "key": key,
                    "label": gateway.name if gateway else label,
                    "gateway": gateway.id if gateway else None,
                    "currency": gateway.currency if gateway else "USD",
                    "min_amount": str(gateway.min_amount) if gateway else "0",
                    "max_amount": str(gateway.max_amount) if gateway else "0",
                    "enabled": bool(gateway and gateway.client_can_use()),
                    "accounts": accounts,
                    "empty_hint": empty_hint,
                }
            )
        return rows


class WithdrawCreateAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def post(self, request):
        ok, result = treasury_service.create_withdraw(request, request.user, request.data)
        if not ok:
            if result.get("errors"):
                return validation_error_response(result["errors"], message=result.get("message", "Validation failed."))
            return error_response(result.get("message", "Withdrawal failed."), status=400)
        status_code = 200 if result.get("otp_required") else 201
        return success_response(result, message=result.get("message", "Withdrawal submitted."), status=status_code)


class TransactionsListAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        tx_type = (request.query_params.get("tx_type") or "").strip()
        limit = min(int(request.query_params.get("limit") or 50), 200)
        types = None
        if tx_type:
            types = [tx_type]
        elif request.query_params.get("kind") == "deposits":
            types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
        elif request.query_params.get("kind") == "withdrawals":
            types = [
                Transaction.TxType.CLIENT_WITHDRAW,
                Transaction.TxType.WALLET_WITHDRAW,
                Transaction.TxType.PENDING_WITHDRAW,
            ]
        return success_response(
            {"transactions": treasury_service.list_user_transactions(request.user, tx_types=types, limit=limit)},
            message="Transactions retrieved successfully.",
        )
