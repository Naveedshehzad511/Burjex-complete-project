"""Extra client APIs mirroring HTML user_portal pages (same business rules)."""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone
from django.utils.crypto import get_random_string
from rest_framework.views import APIView

from accounts.models import Document, MT5Account, User, VerifiedBankAccount, VerifiedCryptoAddress
from admin_panel.models import DemoAccountSettings, TradingAccount, TradingAccountType
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, not_found_response, success_response
from api.services.treasury_service import list_user_transactions, serialize_transaction
from transactions.models import Transaction
from transactions.real_ledger import filter_real_ledger_transactions
from user_portal.views import _ib_wallet_balance_for_user, _team_client_ids


def _user_brief(u: User) -> dict:
    return {
        "id": u.id,
        "username": u.username,
        "email": u.email,
        "display_name": u.display_name(),
        "phone": u.phone or "",
        "country": u.country or "",
        "kyc_status": u.kyc_status,
        "account_status": u.account_status,
        "date_joined": u.date_joined.isoformat() if u.date_joined else None,
    }


def _mt5_for_user(user, login_id: str):
    return MT5Account.objects.filter(user=user, login_id=str(login_id)).select_related("group").first()


class AccountLeverageAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request, login_id: str):
        mt5 = _mt5_for_user(request.user, login_id)
        if not mt5:
            return not_found_response("Account not found.")
        trading = TradingAccount.objects.filter(user=request.user, mt5_account=mt5).first()
        max_allowed = 1000
        if trading and trading.account_type:
            at = TradingAccountType.objects.filter(
                account_name__iexact=trading.account_type, is_active=True
            ).first()
            if at:
                max_allowed = int(at.max_leverage or 1000)
        preferred = [100, 200, 500, 1000, 1500, 2000]
        options = [x for x in preferred if x <= max_allowed]
        if max_allowed not in options:
            options.append(max_allowed)
        if mt5.leverage not in options:
            options.append(int(mt5.leverage or 100))
        options = sorted({x for x in options if x >= 1})
        return success_response(
            {
                "login_id": mt5.login_id,
                "current_leverage": int(mt5.leverage or 0),
                "max_allowed": max_allowed,
                "options": options,
                "trading_enabled": bool(mt5.trading_enabled),
            }
        )

    def post(self, request, login_id: str):
        mt5 = _mt5_for_user(request.user, login_id)
        if not mt5:
            return not_found_response("Account not found.")
        if not mt5.trading_enabled:
            return error_response("Leverage cannot be changed while trading is disabled.")
        trading = TradingAccount.objects.filter(user=request.user, mt5_account=mt5).first()
        max_allowed = 1000
        if trading and trading.account_type:
            at = TradingAccountType.objects.filter(
                account_name__iexact=trading.account_type, is_active=True
            ).first()
            if at:
                max_allowed = int(at.max_leverage or 1000)
        preferred = [100, 200, 500, 1000, 1500, 2000]
        options = [x for x in preferred if x <= max_allowed]
        if max_allowed not in options:
            options.append(max_allowed)
        options = sorted({x for x in options if x >= 1})
        try:
            new_lev = int(request.data.get("leverage") or 0)
        except Exception:
            new_lev = 0
        if new_lev not in options:
            return error_response(f"Allowed leverage range is 1 to {max_allowed}.")
        mt5.leverage = new_lev
        mt5.save(update_fields=["leverage", "updated_at"])
        if trading:
            trading.leverage = new_lev
            trading.save(update_fields=["leverage", "updated_at"])
        return success_response(
            {"login_id": mt5.login_id, "leverage": new_lev},
            message="Leverage updated successfully.",
        )


class AccountTradingSessionAPIView(APIView):
    """
    Return credentials so the mobile app can sign into a trading platform
    account (MT5-style account switch for BTrader / platform login).
    Only the account owner may call this.
    """

    permission_classes = [IsAuthenticatedClient]

    def get(self, request, login_id: str):
        mt5 = _mt5_for_user(request.user, login_id)
        if not mt5:
            return not_found_response("Account not found.")
        if not mt5.trading_enabled:
            return error_response("Trading is disabled for this account.", status=403)
        password = (mt5.get_mt5_password() or "").strip()
        if not password:
            return error_response(
                "Trading password is not available. Reset your trading password from Account Hub first."
            )
        trading = TradingAccount.objects.filter(user=request.user, mt5_account=mt5).first()
        platform = "MT5"
        if mt5.group and getattr(mt5.group, "platform", None):
            platform = str(mt5.group.platform).upper()
        else:
            blob = f"{mt5.account_label or ''} {mt5.server or ''}".lower()
            if "btrader" in blob:
                platform = "BTRADER"
            elif "match" in blob:
                platform = "MATCH_TRADER"
        return success_response(
            {
                "login_id": mt5.login_id,
                "password": password,
                "platform": platform,
                "server": mt5.server or "",
                "account_type": mt5.account_type,
                "is_demo": mt5.account_type == MT5Account.AccountType.DEMO,
                "trading_account_id": trading.id if trading else None,
                "account_number": (trading.account_number if trading else mt5.login_id),
                "leverage": int(mt5.leverage or 0),
                "currency": (trading.currency if trading else "USD"),
            },
            message="Trading session credentials retrieved.",
        )


class AccountCredentialAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def post(self, request, login_id: str, mode: str):
        if mode not in {"trading", "investor"}:
            return error_response("Invalid credential mode.")
        mt5 = _mt5_for_user(request.user, login_id)
        if not mt5:
            return not_found_response("Account not found.")
        action = (request.data.get("action") or "").strip()
        session_key = f"acct_cred_otp_{request.user.id}_{login_id}_{mode}"
        if action == "request_otp":
            new_pass = (request.data.get("new_password") or "").strip()
            confirm_pass = (request.data.get("confirm_password") or "").strip()
            if len(new_pass) < 6:
                return error_response("Password must be at least 6 characters.")
            if new_pass != confirm_pass:
                return error_response("Password confirmation does not match.")
            otp = get_random_string(6, allowed_chars="0123456789")
            request.session[session_key] = {
                "otp": otp,
                "new_password": new_pass,
                "otp_requested": True,
            }
            if request.user.email:
                from admin_panel.email_service import send_dynamic_email

                send_dynamic_email(
                    request.user.email,
                    "Account Security OTP",
                    f"Your OTP is: {otp}",
                    user=request.user,
                )
            return success_response({"otp_requested": True}, message="OTP sent to your email.")
        if action == "verify_otp":
            otp = (request.data.get("otp_code") or "").strip()
            state = request.session.get(session_key) or {}
            if not otp or otp != (state.get("otp") or ""):
                return error_response("Invalid OTP.")
            new_pass = (state.get("new_password") or "").strip()
            if len(new_pass) < 6:
                return error_response("Password must be at least 6 characters.")
            try:
                from mt5_integration.services import mt5_change_password

                if mode == "trading":
                    mt5_change_password(int(mt5.login_id), new_pass, pass_type="MAIN")
                    mt5.set_mt5_password(new_pass)
                    mt5.save(update_fields=["mt5_password_encrypted", "updated_at"])
                else:
                    mt5_change_password(int(mt5.login_id), new_pass, pass_type="INVESTOR")
                    mt5.set_investor_password(new_pass)
                    mt5.save(update_fields=["investor_password_encrypted", "updated_at"])
            except Exception:
                return error_response("Failed to update password on MT5 server.")
            request.session.pop(session_key, None)
            return success_response({}, message="Password changed successfully.")
        return error_response("Invalid action. Use request_otp or verify_otp.")


class DemoBalanceAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def post(self, request, login_id: str):
        mt5 = MT5Account.objects.filter(
            user=request.user,
            login_id=str(login_id),
            account_type=MT5Account.AccountType.DEMO,
        ).first()
        if not mt5:
            return not_found_response("Demo account not found.")
        action = (request.data.get("action") or "").strip().lower()
        current = Decimal(str(mt5.balance or 0))
        if action == "reset":
            demo_settings = DemoAccountSettings.get_solo()
            reset_to = Decimal(str(request.data.get("amount") or demo_settings.default_balance or 10000))
            if reset_to < 0:
                reset_to = Decimal("0")
            mt5.balance = reset_to
        else:
            try:
                amount = Decimal(str(request.data.get("amount") or "0"))
            except Exception:
                amount = Decimal("0")
            if amount <= 0:
                return error_response("Enter a valid amount.")
            if action in {"withdraw", "debit", "remove"}:
                if amount > current:
                    return error_response("Insufficient demo balance.")
                mt5.balance = current - amount
            else:
                mt5.balance = current + amount
        mt5.equity = mt5.balance
        mt5.free_margin = mt5.balance
        mt5.save(update_fields=["balance", "equity", "free_margin", "updated_at"])
        TradingAccount.objects.filter(mt5_account=mt5).update(
            balance=mt5.balance, updated_at=timezone.now()
        )
        return success_response(
            {"login_id": mt5.login_id, "balance": str(mt5.balance)},
            message="Demo balance updated.",
        )


class IBTreeAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        level1_ids = _team_client_ids(request.user)
        level1 = User.objects.filter(id__in=level1_ids)
        level2 = User.objects.filter(referred_by_id__in=level1_ids)[:50]
        level2_ids = list(level2.values_list("id", flat=True))
        level3 = User.objects.filter(referred_by_id__in=level2_ids)[:50]
        return success_response(
            {
                "level1": [_user_brief(u) for u in level1],
                "level2": [_user_brief(u) for u in level2],
                "level3": [_user_brief(u) for u in level3],
            }
        )


class IBWithdrawAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        from ib.models import IBCommissionSettings, IBProfile

        ib_profile = IBProfile.objects.filter(user=request.user).first()
        if not ib_profile or request.user.role != User.Roles.IB:
            return error_response("You must be an approved IB.", status=403)
        settings_obj = IBCommissionSettings.get_solo()
        banks = VerifiedBankAccount.objects.filter(
            user=request.user, status=VerifiedBankAccount.Status.APPROVED
        )
        cryptos = VerifiedCryptoAddress.objects.filter(
            user=request.user, status=VerifiedCryptoAddress.Status.APPROVED
        )
        history = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=request.user,
                tx_type__in=[
                    Transaction.TxType.PENDING_IB_WITHDRAW,
                    Transaction.TxType.IB_WITHDRAW,
                ],
            ).order_by("-created_at")
        )[:100]
        return success_response(
            {
                "available_balance": str(_ib_wallet_balance_for_user(request.user)),
                "methods": {
                    "internal": bool(settings_obj.enable_withdraw_internal),
                    "bank": bool(settings_obj.enable_withdraw_bank),
                    "crypto": bool(settings_obj.enable_withdraw_crypto),
                    "manual": bool(settings_obj.enable_withdraw_manual),
                },
                "banks": [
                    {
                        "id": b.id,
                        "bank_name": b.bank_name,
                        "account_name": b.account_name,
                        "account_number": b.account_number,
                    }
                    for b in banks
                ],
                "cryptos": [
                    {
                        "id": c.id,
                        "wallet_name": c.wallet_name,
                        "wallet_address": c.wallet_address,
                        "network": c.network,
                    }
                    for c in cryptos
                ],
                "history": [serialize_transaction(t) for t in history],
            }
        )

    def post(self, request):
        from ib.models import IBCommissionSettings, IBProfile

        ib_profile = IBProfile.objects.filter(user=request.user).first()
        if not ib_profile or request.user.role != User.Roles.IB:
            return error_response("You must be an approved IB.", status=403)
        settings_obj = IBCommissionSettings.get_solo()
        available = _ib_wallet_balance_for_user(request.user)
        method = (request.data.get("method") or "").strip().lower()
        try:
            amount = Decimal(str(request.data.get("amount") or "0"))
        except Exception:
            amount = Decimal("0")
        notes = (request.data.get("notes") or "").strip()
        bank_id = request.data.get("bank_id")
        crypto_id = request.data.get("crypto_id")
        if amount <= 0:
            return error_response("Please enter a valid positive withdrawal amount.")
        if amount > available:
            return error_response("Insufficient available commission balance.")
        if method == "internal":
            return success_response(
                {"redirect": "internal_transfer", "from_account": "IB_WALLET"},
                message="Use Internal Transfer from IB Wallet.",
            )
        enabled = {
            "bank": settings_obj.enable_withdraw_bank,
            "crypto": settings_obj.enable_withdraw_crypto,
            "manual": settings_obj.enable_withdraw_manual,
        }.get(method, False)
        if not enabled:
            return error_response(f"Withdrawal method '{method}' is disabled.")
        account_details = (request.data.get("account_details") or "").strip()
        if method == "bank":
            selected = VerifiedBankAccount.objects.filter(
                user=request.user, status=VerifiedBankAccount.Status.APPROVED, id=bank_id
            ).first()
            if not selected:
                return error_response("Select a verified bank account.")
            account_details = (
                f"Type: BANK\nAccount Name: {selected.account_name}\nBank Name: {selected.bank_name}\n"
                f"Account Number: {selected.account_number}\nIBAN: {selected.iban}\nVerified Bank ID: {selected.id}"
            )
        elif method == "crypto":
            selected = VerifiedCryptoAddress.objects.filter(
                user=request.user, status=VerifiedCryptoAddress.Status.APPROVED, id=crypto_id
            ).first()
            if not selected:
                return error_response("Select a verified crypto address.")
            account_details = (
                f"Type: CRYPTO\nWallet Name: {selected.wallet_name or ''}\n"
                f"Wallet Address: {selected.wallet_address}\nNetwork: {selected.network}\n"
                f"Verified Crypto ID: {selected.id}"
            )
        from django.db import transaction as db_transaction

        with db_transaction.atomic():
            locked_user = User.objects.select_for_update().get(pk=request.user.pk)
            live_available = _ib_wallet_balance_for_user(locked_user)
            if amount > live_available:
                return error_response("Insufficient available commission balance.")
            tx = Transaction.objects.create(
                tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
                status=Transaction.Status.PENDING,
                actor=locked_user,
                amount=amount,
                currency="USD",
                notes=notes,
                account_details=account_details,
            )
        return success_response(
            serialize_transaction(tx),
            message="IB withdrawal request submitted.",
            status=201,
        )


class TeamReportAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request, kind: str):
        team_ids = _team_client_ids(request.user)
        if kind == "deposits":
            types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
            title = "Team Deposit Report"
        else:
            types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
            title = "Team Withdraw Report"
        qs = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor_id__in=team_ids,
                tx_type__in=types,
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
            .select_related("actor", "payment_gateway")
            .order_by("-created_at")
        )[:200]
        return success_response(
            {
                "title": title,
                "rows": [
                    {
                        **serialize_transaction(t),
                        "client": t.actor.display_name() if t.actor_id else "",
                        "client_email": t.actor.email if t.actor_id else "",
                    }
                    for t in qs
                ],
            }
        )


class MyDocumentsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        list_status = (request.query_params.get("status") or "pending").strip().lower()
        if list_status not in {"pending", "approved", "rejected", "all"}:
            list_status = "pending"
        base = Document.objects.filter(user=request.user)
        counts = {
            "pending": base.filter(status=Document.Status.PENDING).count(),
            "approved": base.filter(status=Document.Status.APPROVED).count(),
            "rejected": base.filter(status=Document.Status.REJECTED).count(),
        }
        qs = base
        if list_status != "all":
            status_map = {
                "pending": Document.Status.PENDING,
                "approved": Document.Status.APPROVED,
                "rejected": Document.Status.REJECTED,
            }
            qs = qs.filter(status=status_map[list_status])
        docs = qs.order_by("-uploaded_at")[:100]
        return success_response(
            {
                "status": list_status,
                "counts": counts,
                "documents": [
                    {
                        "id": d.id,
                        "doc_type": d.doc_type,
                        "status": d.status,
                        "file_url": d.file.url if d.file else "",
                        "uploaded_at": d.uploaded_at.isoformat() if d.uploaded_at else None,
                        "notes": getattr(d, "notes", "") or "",
                    }
                    for d in docs
                ],
            }
        )


class AccountHistoryAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
        return success_response(
            {
                "accounts": [
                    {
                        "login_id": a.login_id,
                        "account_type": a.account_type,
                        "account_label": a.account_label or "",
                        "balance": str(a.balance or 0),
                        "equity": str(a.equity or 0),
                        "leverage": int(a.leverage or 0),
                        "server": a.server or "",
                        "status": a.status,
                        "updated_at": a.updated_at.isoformat() if a.updated_at else None,
                    }
                    for a in accounts
                ]
            }
        )


class FilteredReportAPIView(APIView):
    """Deposit / withdraw / internal-transfer reports (My Data)."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request, kind: str):
        kind = (kind or "").strip().lower()
        if kind == "deposits":
            types = [
                Transaction.TxType.CLIENT_DEPOSIT,
                Transaction.TxType.WALLET_DEPOSIT,
                Transaction.TxType.PENDING_DEPOSIT,
            ]
            title = "Deposit Report"
        elif kind == "withdrawals":
            types = [
                Transaction.TxType.CLIENT_WITHDRAW,
                Transaction.TxType.WALLET_WITHDRAW,
                Transaction.TxType.PENDING_WITHDRAW,
            ]
            title = "Withdraw Report"
        elif kind in {"transfers", "internal-transfer", "internal_transfer"}:
            types = [Transaction.TxType.INTERNAL_TRANSFER]
            title = "Internal Transfer Report"
        else:
            return error_response("Invalid report kind.")
        status = (request.query_params.get("status") or "").strip().upper()
        qs = filter_real_ledger_transactions(
            Transaction.objects.filter(actor=request.user, tx_type__in=types)
            .select_related("payment_gateway")
            .order_by("-created_at")
        )
        from_date = (request.query_params.get("from") or "").strip()
        to_date = (request.query_params.get("to") or "").strip()
        if from_date:
            qs = qs.filter(created_at__date__gte=from_date)
        if to_date:
            qs = qs.filter(created_at__date__lte=to_date)
        if status in {"PENDING", "APPROVED", "COMPLETED", "REJECTED"}:
            qs = qs.filter(status=status)
        rows = [serialize_transaction(t) for t in qs[:200]]
        return success_response({"title": title, "kind": kind, "rows": rows})


class DealReportAPIView(APIView):
    """MT5 deal history — same data as `/user/my-data/deal-report/`."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        import logging
        import time
        from datetime import datetime

        logger = logging.getLogger(__name__)
        account_id = (request.query_params.get("account") or "").strip()
        from_date = (request.query_params.get("from") or "").strip()
        to_date = (request.query_params.get("to") or "").strip()
        q = (request.query_params.get("q") or "").strip()
        accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
        summary = {
            "balance": str(sum((Decimal(str(a.balance or 0)) for a in accounts), Decimal("0"))),
            "equity": str(sum((Decimal(str(a.equity or 0)) for a in accounts), Decimal("0"))),
            "profit": str(sum((Decimal(str(a.unrealized_pnl or 0)) for a in accounts), Decimal("0"))),
            "free_margin": str(sum((Decimal(str(a.free_margin or 0)) for a in accounts), Decimal("0"))),
        }
        account_list = [
            {
                "id": a.id,
                "login_id": a.login_id,
                "account_type": a.account_type,
                "account_label": a.account_label or "",
            }
            for a in accounts
        ]
        deals = []
        mt5_available = False
        try:
            from mt5_integration.services import _mt5_client, is_mt5_configured

            mt5_available = bool(is_mt5_configured())
            if mt5_available:
                with _mt5_client() as client:
                    target = accounts.filter(id=account_id) if account_id.isdigit() else accounts
                    for acc in target:
                        try:
                            from_ts = 0
                            if from_date:
                                from_ts = int(
                                    datetime.strptime(from_date, "%Y-%m-%d")
                                    .replace(tzinfo=timezone.utc)
                                    .timestamp()
                                )
                            to_ts = int(time.time()) + 86400
                            if to_date:
                                to_ts = (
                                    int(
                                        datetime.strptime(to_date, "%Y-%m-%d")
                                        .replace(tzinfo=timezone.utc)
                                        .timestamp()
                                    )
                                    + 86400
                                )
                            total_deals = client.deal_get_total(int(acc.login_id), from_ts, to_ts)
                            raw = []
                            offset = 0
                            while offset < total_deals:
                                chunk = client.deal_get_page(int(acc.login_id), from_ts, to_ts, offset, 5000)
                                if not chunk:
                                    break
                                raw.extend(chunk)
                                offset += 5000
                            for d in raw:
                                symbol_name = d.get("Symbol") or ""
                                login_str = str(d.get("Login") or "")
                                if q and q.lower() not in symbol_name.lower() and q.lower() not in login_str:
                                    continue
                                action_val = d.get("Action", 0)
                                if action_val == 0:
                                    action_str = "Buy"
                                elif action_val == 1:
                                    action_str = "Sell"
                                elif action_val == 2:
                                    action_str = "Balance"
                                else:
                                    action_str = str(action_val)
                                entry_val = d.get("Entry", 0)
                                open_price = "-"
                                close_price = "-"
                                trade_status = "-"
                                if action_val == 2:
                                    trade_status = "Balance"
                                elif entry_val == 0:
                                    open_price = d.get("Price")
                                    trade_status = "Open"
                                elif entry_val in (1, 3):
                                    open_price = d.get("PricePosition")
                                    close_price = d.get("Price")
                                    trade_status = "Closed"
                                elif entry_val == 2:
                                    open_price = d.get("PricePosition")
                                    close_price = d.get("Price")
                                    trade_status = "Reversed"
                                deals.append(
                                    {
                                        "login_id": d.get("Login"),
                                        "symbol": symbol_name,
                                        "ticket": d.get("Deal"),
                                        "time": datetime.fromtimestamp(
                                            d.get("Time", 0), tz=timezone.utc
                                        ).isoformat(),
                                        "type": action_str,
                                        "volume": round(d.get("Volume", 0) / 10000.0, 2),
                                        "open_price": open_price,
                                        "close_price": close_price,
                                        "commission": d.get("Commission"),
                                        "swap": d.get("Storage"),
                                        "profit": d.get("Profit"),
                                        "status": trade_status,
                                    }
                                )
                        except Exception as exc:
                            logger.warning("API deal_report account %s: %s", acc.login_id, exc)
        except Exception as exc:
            logger.warning("API deal_report MT5 failure: %s", exc)
            mt5_available = False
        deals.sort(key=lambda x: x.get("time") or "", reverse=True)
        return success_response(
            {
                "title": "Deal Report",
                "summary": summary,
                "accounts": account_list,
                "deals": deals[:500],
                "mt5_available": mt5_available,
                "filters": {"account": account_id, "from": from_date, "to": to_date, "q": q},
            }
        )


class SummaryReportAPIView(APIView):
    """Trading summary — same metrics as `/user/my-data/summary-report/`."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        import logging
        import time

        logger = logging.getLogger(__name__)
        accounts = MT5Account.objects.filter(user=request.user).order_by("-updated_at")
        summary = {
            "net_profit": Decimal("0.00"),
            "total_orders": 0,
            "total_volume": Decimal("0.00"),
            "total_deposits": Decimal("0.00"),
            "total_withdrawals": Decimal("0.00"),
            "accounts_count": accounts.count(),
            "balance": sum((Decimal(str(a.balance or 0)) for a in accounts), Decimal("0")),
            "equity": sum((Decimal(str(a.equity or 0)) for a in accounts), Decimal("0")),
        }
        mt5_available = False
        try:
            from mt5_integration.services import _mt5_client, is_mt5_configured

            mt5_available = bool(is_mt5_configured())
            if mt5_available:
                with _mt5_client() as client:
                    to_ts = int(time.time()) + 86400
                    from_ts = 0
                    for acc in accounts:
                        try:
                            total_deals = client.deal_get_total(int(acc.login_id), from_ts, to_ts)
                            raw = []
                            offset = 0
                            while offset < total_deals:
                                chunk = client.deal_get_page(int(acc.login_id), from_ts, to_ts, offset, 5000)
                                if not chunk:
                                    break
                                raw.extend(chunk)
                                offset += 5000
                            for d in raw:
                                action_val = d.get("Action", 0)
                                if action_val in (0, 1):
                                    summary["net_profit"] += Decimal(str(d.get("Profit", 0)))
                                    summary["total_orders"] += 1
                                    summary["total_volume"] += Decimal(
                                        str(round(d.get("Volume", 0) / 10000.0, 2))
                                    )
                                elif action_val == 2:
                                    profit = d.get("Profit", 0)
                                    if profit > 0:
                                        summary["total_deposits"] += Decimal(str(profit))
                                    elif profit < 0:
                                        summary["total_withdrawals"] += Decimal(str(abs(profit)))
                        except Exception as exc:
                            logger.warning("API summary_report account %s: %s", acc.login_id, exc)
        except Exception as exc:
            logger.warning("API summary_report MT5 failure: %s", exc)
            mt5_available = False

        # Fallback ledger totals when MT5 is offline
        if not mt5_available:
            deps = filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=request.user,
                    tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            )
            wds = filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=request.user,
                    tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW],
                    status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
                )
            )
            summary["total_deposits"] = sum((Decimal(str(t.amount or 0)) for t in deps), Decimal("0"))
            summary["total_withdrawals"] = sum((Decimal(str(t.amount or 0)) for t in wds), Decimal("0"))

        return success_response(
            {
                "title": "Summary Report",
                "mt5_available": mt5_available,
                "summary": {
                    "net_profit": str(summary["net_profit"]),
                    "total_orders": summary["total_orders"],
                    "total_volume": str(summary["total_volume"]),
                    "total_deposits": str(summary["total_deposits"]),
                    "total_withdrawals": str(summary["total_withdrawals"]),
                    "accounts_count": summary["accounts_count"],
                    "balance": str(summary["balance"]),
                    "equity": str(summary["equity"]),
                },
            }
        )


class AccountStatementAPIView(APIView):
    """Ledger statement for an account — mirrors `/user/accounts/<login>/statements/`."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request, login_id: str):
        from datetime import datetime, timedelta

        mt5 = _mt5_for_user(request.user, login_id)
        if not mt5:
            return not_found_response("Account not found.")
        period = (request.query_params.get("period") or "7d").lower()
        now = timezone.now()
        if period == "today":
            since = timezone.make_aware(datetime.combine(timezone.localdate(), datetime.min.time()))
            until = now
        elif period == "30d":
            since = now - timedelta(days=30)
            until = now
        else:
            since = now - timedelta(days=7)
            until = now
        if mt5.account_type == MT5Account.AccountType.DEMO:
            rows = []
        else:
            rows = [
                serialize_transaction(t)
                for t in filter_real_ledger_transactions(
                    Transaction.objects.filter(
                        actor=request.user, created_at__gte=since, created_at__lte=until
                    ).order_by("-created_at")
                )[:100]
            ]
        return success_response(
            {
                "login_id": mt5.login_id,
                "period": period,
                "rows": rows,
                "account": {
                    "balance": str(mt5.balance or 0),
                    "equity": str(mt5.equity or 0),
                    "account_type": mt5.account_type,
                },
            }
        )
