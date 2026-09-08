"""Deposit / withdraw adapters reusing portal forms, KYC gates, and ledger rules."""

from __future__ import annotations

import logging
import uuid
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Q, Sum
from django.urls import reverse
from django.utils import timezone
from django.utils.crypto import get_random_string

from accounts.kyc_policy import is_effective_kyc_approved, kyc_blocks_deposit, kyc_blocks_withdraw
from accounts.models import MT5Account, User, VerifiedBankAccount, VerifiedCryptoAddress
from accounts.restrictions import restriction_for_user
from admin_panel.email_service import send_dynamic_email
from admin_panel.models import ComplianceSettings, Match2PayIntegrationSettings, TradingAccount, WalletTreasurySettings
from admin_panel.templated_mail import send_event_email
from enterprise.audit import get_client_ip
from transactions.models import BalanceLedger, Match2PayTransaction, PaymentGateway, Transaction
from transactions.real_ledger import filter_real_ledger_transactions
from transactions.services.match2pay_client import (
    ALLOWED_NETWORKS,
    NETWORK_DISPLAY_ORDER,
    create_crypto_deposit,
    crypto_method_label,
)
from user_portal.views import DepositForm, WithdrawForm, _gateway_profile, _match2pay_checkout_url, _wallet_balance_for_user

logger = logging.getLogger(__name__)


def _serialize_gateway(g: PaymentGateway) -> dict:
    profile = _gateway_profile(g)
    is_m2p = profile == "MATCH2PAY"
    return {
        "id": g.id,
        "name": g.name,
        "code": g.code,
        "scope": g.scope,
        "gateway_type": g.gateway_type,
        "payment_method": g.payment_method,
        "currency": g.currency,
        "min_amount": str(g.min_amount),
        "max_amount": str(g.max_amount),
        "processing_time": g.processing_time,
        "charges": g.charges,
        "instructions": "" if is_m2p else g.instructions,
        "description": "" if is_m2p else g.description,
        "visibility_status": g.visibility_status,
        "require_payment_proof": False if is_m2p else g.require_payment_proof,
        "whitelist_required": g.whitelist_required,
        "requires_kyc_for_method": g.requires_kyc_for_method,
        "requires_2fa_for_method": g.requires_2fa_for_method,
        "profile": profile,
        "account_name": "" if is_m2p else g.account_name,
        "bank_name": "" if is_m2p else g.bank_name,
        "account_number": "" if is_m2p else g.account_number,
        "iban": "" if is_m2p else g.iban,
        "swift_code": "" if is_m2p else g.swift_code,
        "wallet_address": "" if is_m2p else g.wallet_address,
        "network": g.network,
        "can_use": g.client_can_use(),
    }


def crypto_networks_for_gateway(gateway=None) -> list[dict]:
    currency = ((getattr(gateway, "currency", None) or "USDT") if gateway else "USDT").upper()
    if currency == "USDT":
        nets = ("TRC20", "ERC20", "BEP20")
    else:
        nets = tuple(n for n in NETWORK_DISPLAY_ORDER if n in ALLOWED_NETWORKS)
    return [{"network": n, "label": crypto_method_label(n)} for n in nets]


def deposit_gateways() -> list[dict]:
    m2p = Match2PayIntegrationSettings.get_solo()
    qs = PaymentGateway.objects.filter(
        PaymentGateway.client_visible_q(),
    ).filter(
        Q(scope=PaymentGateway.Scope.DEPOSIT) | Q(scope=PaymentGateway.Scope.BOTH)
    ).order_by("display_order", "name")
    if not m2p.enabled:
        qs = qs.exclude(gateway_type=PaymentGateway.GatewayType.THIRD_PARTY)
    return [_serialize_gateway(g) for g in qs]


_DEFAULT_WITHDRAW_GATEWAYS = (
    ("bank-withdraw", "Bank Withdrawal", PaymentGateway.PaymentMethod.BANK),
    ("crypto-withdraw", "Crypto Withdrawal", PaymentGateway.PaymentMethod.CRYPTO),
)


def _withdraw_gateway_qs():
    return PaymentGateway.objects.filter(
        PaymentGateway.client_visible_q(),
    ).filter(
        Q(scope=PaymentGateway.Scope.WITHDRAW) | Q(scope=PaymentGateway.Scope.BOTH)
    ).order_by("display_order", "name")


def ensure_default_withdraw_gateways() -> None:
    """Guarantee one payout rail per method.

    Clients choose a KYC-verified destination, never a gateway, so a missing or
    hidden Bank/Crypto withdraw rail silently breaks every withdrawal.
    """
    for code, name, method in _DEFAULT_WITHDRAW_GATEWAYS:
        if _withdraw_gateway_qs().filter(payment_method=method).exists():
            continue
        gateway, created = PaymentGateway.objects.get_or_create(
            code=code,
            defaults={
                "name": name,
                "scope": PaymentGateway.Scope.WITHDRAW,
                "gateway_type": PaymentGateway.GatewayType.LOCAL,
                "payment_method": method,
                "currency": "USD",
                "min_amount": 1,
                "max_amount": 0,
                "visibility_status": PaymentGateway.VisibilityStatus.ACTIVE,
                "is_active": True,
                "processing_mode": PaymentGateway.ProcessingMode.MANUAL,
                "whitelist_required": True,
                "instructions": "Withdraw to your KYC-verified destination. Admin approval required.",
            },
        )
        if created:
            continue
        gateway.scope = PaymentGateway.Scope.WITHDRAW
        gateway.payment_method = method
        gateway.visibility_status = PaymentGateway.VisibilityStatus.ACTIVE
        gateway.is_active = True
        gateway.save(update_fields=["scope", "payment_method", "visibility_status", "is_active"])


def withdraw_gateways() -> list[dict]:
    ensure_default_withdraw_gateways()
    return [_serialize_gateway(g) for g in _withdraw_gateway_qs()]


def withdraw_gateway_for_method(method: str) -> PaymentGateway | None:
    method = (method or "").strip().upper()
    if method in {"BANK", "CRYPTO"}:
        return _withdraw_gateway_qs().filter(payment_method=method).first()
    return None


def check_deposit_allowed(user) -> tuple[bool, str]:
    r = restriction_for_user(user)
    ws = WalletTreasurySettings.get_solo()
    if not ws.wallet_system_enabled:
        return False, "Wallet is not available."
    if not ws.allow_deposits_to_wallet:
        return False, "Deposits are disabled. Please contact support."
    if ws.wallet_deposit_maintenance:
        return False, "Deposits are temporarily under maintenance."
    if r and r.disable_deposit:
        return False, "Deposits are disabled for your account. Please contact support."
    if kyc_blocks_deposit(user, ComplianceSettings.get_solo()):
        return False, "KYC approval is required before you can deposit."
    return True, ""


def check_withdraw_allowed(user) -> tuple[bool, str]:
    r = restriction_for_user(user)
    ws = WalletTreasurySettings.get_solo()
    if not ws.wallet_system_enabled:
        return False, "Wallet is not available."
    if not ws.allow_withdrawals_from_wallet:
        return False, "Withdrawals are disabled. Please contact support."
    if ws.wallet_withdraw_maintenance:
        return False, "Withdrawals are temporarily under maintenance."
    if r and r.disable_withdraw:
        return False, "Withdrawals are disabled for your account. Please contact support."
    if kyc_blocks_withdraw(user, ComplianceSettings.get_solo()):
        return False, "KYC required before withdrawal."
    return True, ""


def create_manual_deposit(user, data, files=None) -> tuple[bool, dict]:
    ok, msg = check_deposit_allowed(user)
    if not ok:
        return False, {"message": msg}

    ws = WalletTreasurySettings.get_solo()
    m2p_settings = Match2PayIntegrationSettings.get_solo()
    form = DepositForm(data, files or {})
    if not form.is_valid():
        return False, {
            "message": "Validation failed.",
            "errors": {k: [str(e) for e in v] for k, v in form.errors.items()},
        }

    gateway = form.cleaned_data["gateway"]
    if _gateway_profile(gateway) == "MATCH2PAY":
        if not m2p_settings.enabled:
            return False, {"message": "This deposit method is not available."}
        return False, {"message": "Use the cryptocurrency deposit endpoint for this method."}
    if not gateway.client_can_use():
        return False, {"message": "This deposit method is temporarily under maintenance."}

    amt = form.cleaned_data["amount"]
    if ws.wallet_min_deposit > 0 and amt < ws.wallet_min_deposit:
        return False, {"message": f"Minimum deposit amount is {ws.wallet_min_deposit}."}
    if ws.wallet_max_deposit > 0 and amt > ws.wallet_max_deposit:
        return False, {"message": f"Maximum deposit amount is {ws.wallet_max_deposit}."}

    profile = _gateway_profile(gateway)
    need_proof = gateway.require_payment_proof or profile == "MANUAL"
    if need_proof and not form.cleaned_data.get("payment_screenshot"):
        return False, {"message": "Payment proof upload is required for this method."}

    trading_account_selection = (data.get("trading_account") or "").strip()
    if trading_account_selection and trading_account_selection != "wallet":
        base_notes = f"Target Account: {trading_account_selection}\nManual deposit request from client portal."
    else:
        base_notes = "Target Account: Wallet\nManual deposit request from client portal."
    client_notes = (form.cleaned_data.get("notes") or "").strip()
    if client_notes:
        base_notes += f"\n\nClient Notes:\n{client_notes}"

    try:
        with transaction.atomic():
            tx = Transaction.objects.create(
                tx_type=Transaction.TxType.CLIENT_DEPOSIT,
                status=Transaction.Status.PENDING,
                actor=user,
                amount=form.cleaned_data["amount"],
                currency=form.cleaned_data["currency"],
                reference=form.cleaned_data.get("reference", "") or "",
                payment_gateway=gateway,
                payment_screenshot=form.cleaned_data.get("payment_screenshot"),
                notes=base_notes,
            )
    except Exception:
        logger.exception("API deposit create failed user=%s", user.id)
        return False, {"message": "Unable to submit deposit request. Please try again."}

    return True, {
        "transaction_id": tx.id,
        "reference": tx.reference,
        "status": tx.status,
        "amount": str(tx.amount),
        "currency": tx.currency,
        "message": "Deposit request submitted successfully.",
    }


def create_crypto_deposit_session(user, data: dict) -> tuple[bool, dict]:
    ok, msg = check_deposit_allowed(user)
    if not ok:
        return False, {"message": msg}

    ws = WalletTreasurySettings.get_solo()
    m2p_settings = Match2PayIntegrationSettings.get_solo()
    if not m2p_settings.enabled:
        return False, {"message": "This deposit method is not available."}

    gateway_qs = PaymentGateway.objects.filter(
        PaymentGateway.client_visible_q(),
    ).filter(
        Q(scope=PaymentGateway.Scope.DEPOSIT) | Q(scope=PaymentGateway.Scope.BOTH)
    )
    gateway = gateway_qs.filter(id=data.get("gateway")).first()
    if not gateway or not gateway.client_can_use():
        return False, {"message": "Invalid deposit method."}
    if _gateway_profile(gateway) != "MATCH2PAY":
        return False, {"message": "Invalid deposit method."}

    network = (data.get("crypto_network") or "").strip().upper()
    if network not in ALLOWED_NETWORKS:
        return False, {"message": "Unsupported network."}

    acc_str = (data.get("trading_account") or "").strip()
    selected_account = None
    if acc_str and acc_str != "wallet":
        selected_account = (
            TradingAccount.objects.select_related("mt5_account")
            .filter(
                account_number=acc_str,
                user=user,
                status=TradingAccount.Status.ACTIVE,
                mt5_account__account_type=MT5Account.AccountType.LIVE,
                mt5_account__deposit_enabled=True,
            )
            .first()
        )
        if not selected_account:
            return False, {"message": "Select a valid live account."}

    try:
        amt = Decimal(str(data.get("amount") or "0"))
    except Exception:
        amt = Decimal("0")
    if amt <= 0:
        return False, {"message": "Enter a valid amount."}
    if ws.wallet_min_deposit > 0 and amt < ws.wallet_min_deposit:
        return False, {"message": f"Minimum deposit amount is {ws.wallet_min_deposit}."}
    if ws.wallet_max_deposit > 0 and amt > ws.wallet_max_deposit:
        return False, {"message": f"Maximum deposit amount is {ws.wallet_max_deposit}."}

    currency = (gateway.currency or "USD").strip().upper()[:10] or "USD"
    ok, result = create_crypto_deposit(
        m2p_settings,
        user=user,
        gateway=gateway,
        amount=amt,
        currency=currency,
        network=network,
        trading_account_login=selected_account.account_number if selected_account else "",
    )
    if not ok:
        logger.warning("API Match2Pay create failed user=%s detail=%s", user.id, result)
        detail = result if isinstance(result, str) else "Unable to generate payment address, please try again."
        return False, {"message": detail}

    parsed = result
    try:
        with transaction.atomic():
            m2p_tx = Match2PayTransaction.objects.create(
                user=user,
                payment_gateway=gateway,
                amount=amt,
                currency=currency,
                network=network,
                payment_id=parsed["payment_id"][:120],
                address=(parsed.get("address") or "")[:255],
                qr_code_data=parsed.get("qr_code_data") or "",
                raw_create_response={
                    **(parsed.get("raw") or {}),
                    "checkout_url": _match2pay_checkout_url(parsed),
                    "trading_account": selected_account.account_number if selected_account else "wallet",
                },
            )
    except Exception:
        logger.exception("API Match2Pay session save failed user=%s", user.id)
        return False, {"message": "Unable to generate payment address, please try again."}

    return True, {
        "payment_id": m2p_tx.payment_id,
        "address": m2p_tx.address,
        "network": m2p_tx.network,
        "amount": str(m2p_tx.amount),
        "currency": m2p_tx.currency,
        "qr_code_data": m2p_tx.qr_code_data,
        "checkout_url": _match2pay_checkout_url(parsed),
        "message": "Payment session generated.",
    }


def _with_resolved_gateway(data: dict) -> tuple[dict, str]:
    """Let clients post only a KYC destination; derive the payout rail from it."""
    payload = data.dict() if hasattr(data, "dict") else dict(data)
    if payload.get("gateway"):
        return payload, ""

    ensure_default_withdraw_gateways()
    method = (payload.get("method") or payload.get("payment_method") or "").strip().upper()
    if not method:
        if payload.get("crypto_address"):
            method = PaymentGateway.PaymentMethod.CRYPTO
        elif payload.get("bank_account"):
            method = PaymentGateway.PaymentMethod.BANK
    if not method:
        return payload, "Select a withdrawal method (bank or crypto)."

    gateway = withdraw_gateway_for_method(method)
    if gateway is None:
        return payload, "This withdrawal method is not available. Please contact support."
    payload["gateway"] = gateway.id
    return payload, ""


def create_withdraw(request, user, data: dict) -> tuple[bool, dict]:
    """Mirror withdraw_feature POST business rules (wallet-only, KYC, OTP, ledger hold)."""
    ok, msg = check_withdraw_allowed(user)
    if not ok:
        return False, {"message": msg}

    ws = WalletTreasurySettings.get_solo()
    data, gateway_error = _with_resolved_gateway(data)
    if gateway_error:
        return False, {"message": gateway_error}
    form = WithdrawForm(data, user=user)
    if not form.is_valid():
        return False, {
            "message": "Validation failed.",
            "errors": {k: [str(e) for e in v] for k, v in form.errors.items()},
        }

    compliance_settings = ComplianceSettings.get_solo()
    gateway = form.cleaned_data["gateway"]
    if not gateway.client_can_use():
        return False, {"message": "This withdrawal method is temporarily under maintenance."}

    withdraw_from = (data.get("withdraw_from") or "wallet").strip().lower()
    if withdraw_from != "wallet":
        return False, {
            "message": "Withdrawals are only allowed from Wallet. Please transfer funds to Wallet first.",
        }

    if (
        compliance_settings.withdrawal_requires_compliance
        or gateway.requires_kyc_for_method
        or ws.require_kyc_wallet_withdraw
    ):
        if not is_effective_kyc_approved(user, compliance_settings):
            return False, {"message": "Complete KYC identity approval before withdrawal."}

    request_uid = (data.get("request_uid") or "").strip() or uuid.uuid4().hex
    method = gateway.payment_method

    if method == PaymentGateway.PaymentMethod.BANK:
        selected_bank = form.cleaned_data.get("bank_account")
        has_approved_banks = VerifiedBankAccount.objects.filter(
            user=user, status=VerifiedBankAccount.Status.APPROVED
        ).exists()
        if selected_bank:
            account_details = (
                f"Type: BANK\nAccount Name: {selected_bank.account_name}\nBank Name: {selected_bank.bank_name}\n"
                f"Account Number: {selected_bank.account_number}\nIBAN: {selected_bank.iban}\nVerified Bank ID: {selected_bank.id}"
            )
        elif has_approved_banks:
            return False, {"message": "Please select a bank account from your KYC verified accounts."}
        elif gateway.whitelist_required:
            return False, {"message": "Add and verify a bank account before requesting withdrawal."}
        else:
            manual_bank = form.cleaned_data.get("manual_bank_name")
            manual_acc_name = form.cleaned_data.get("manual_account_name")
            manual_acc_num = form.cleaned_data.get("manual_account_number")
            manual_iban = form.cleaned_data.get("manual_iban")
            manual_swift = form.cleaned_data.get("manual_swift_code")
            if not manual_bank or not manual_acc_name or (not manual_acc_num and not manual_iban):
                return False, {
                    "message": "Please fill in all required bank details. Alternatively, select a verified bank account.",
                }
            account_details = (
                f"Type: BANK (Manual)\nAccount Name: {manual_acc_name}\nBank Name: {manual_bank}\n"
                f"Account Number: {manual_acc_num}\nIBAN: {manual_iban}\nSWIFT Code: {manual_swift}"
            )
    elif method == PaymentGateway.PaymentMethod.CRYPTO:
        selected_crypto = form.cleaned_data.get("crypto_address")
        has_approved_crypto = VerifiedCryptoAddress.objects.filter(
            user=user, status=VerifiedCryptoAddress.Status.APPROVED
        ).exists()
        if selected_crypto:
            wn = (selected_crypto.wallet_name or "").strip()
            account_details = (
                f"Type: CRYPTO\n"
                + (f"Wallet Name: {wn}\n" if wn else "")
                + f"Wallet Address: {selected_crypto.wallet_address}\nNetwork: {selected_crypto.network}\n"
                f"Verified Crypto ID: {selected_crypto.id}"
            )
        elif has_approved_crypto:
            return False, {"message": "Please select a crypto address from your KYC verified accounts."}
        elif gateway.whitelist_required:
            return False, {"message": "Add and verify a crypto wallet before requesting withdrawal."}
        else:
            manual_addr = form.cleaned_data.get("manual_crypto_address")
            manual_net = form.cleaned_data.get("manual_crypto_network")
            if not manual_addr or not manual_net:
                return False, {
                    "message": "Please fill in all required manual crypto details. Alternatively, select a verified crypto address.",
                }
            account_details = (
                f"Type: CRYPTO (Manual)\nWallet Address: {manual_addr}\nNetwork: {manual_net}"
            )
    else:
        return False, {"message": "Unsupported withdrawal method. Use Bank or Crypto only."}

    amount = form.cleaned_data["amount"]
    if gateway.min_amount > 0 and amount < gateway.min_amount:
        return False, {
            "message": f"Minimum withdrawal amount for this method is {gateway.min_amount} {gateway.currency}.",
        }
    if gateway.max_amount > 0 and amount > gateway.max_amount:
        return False, {
            "message": f"Maximum withdrawal amount for this method is {gateway.max_amount} {gateway.currency}.",
        }
    if ws.wallet_min_withdraw > 0 and amount < ws.wallet_min_withdraw:
        return False, {"message": f"Minimum withdrawal amount is {ws.wallet_min_withdraw}."}
    if ws.wallet_max_withdraw > 0 and amount > ws.wallet_max_withdraw:
        return False, {"message": f"Maximum withdrawal amount is {ws.wallet_max_withdraw}."}

    if ws.wallet_daily_withdraw_limit > 0:
        today_sum = (
            filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=user,
                    tx_type__in=[
                        Transaction.TxType.CLIENT_WITHDRAW,
                        Transaction.TxType.WALLET_WITHDRAW,
                        Transaction.TxType.PENDING_WITHDRAW,
                    ],
                    created_at__date=timezone.localdate(),
                    status__in=[
                        Transaction.Status.PENDING,
                        Transaction.Status.APPROVED,
                        Transaction.Status.COMPLETED,
                    ],
                )
            ).aggregate(s=Sum("amount"))["s"]
            or 0
        )
        if Decimal(str(today_sum)) + amount > ws.wallet_daily_withdraw_limit:
            return False, {"message": "Daily withdrawal limit reached."}

    if ws.wallet_max_pending_withdrawals > 0:
        pend_n = filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=user,
                tx_type__in=[
                    Transaction.TxType.CLIENT_WITHDRAW,
                    Transaction.TxType.WALLET_WITHDRAW,
                    Transaction.TxType.PENDING_WITHDRAW,
                ],
                status=Transaction.Status.PENDING,
            )
        ).count()
        if pend_n >= ws.wallet_max_pending_withdrawals:
            return False, {"message": "Maximum pending withdrawals reached. Please wait for processing."}

    otp_required = (
        compliance_settings.otp_email_enabled
        or compliance_settings.otp_sms_enabled
        or gateway.requires_2fa_for_method
        or ws.require_2fa_wallet_withdraw
    )
    if otp_required:
        session_key = f"withdraw_otp_{user.id}_{gateway.id}"
        submitted_otp = (data.get("otp_code") or "").strip()
        if not submitted_otp:
            otp = get_random_string(6, allowed_chars="0123456789")
            request.session[session_key] = otp
            if compliance_settings.otp_email_enabled and user.email:
                try:
                    send_dynamic_email(
                        user.email,
                        "Withdrawal OTP",
                        f"Your withdrawal OTP is: {otp}",
                        user=user,
                    )
                except Exception:
                    logger.exception("Withdrawal OTP email failed", extra={"user_id": user.id})
            return True, {
                "otp_required": True,
                "gateway_id": gateway.id,
                "request_uid": request_uid,
                "message": "OTP sent. Enter OTP to submit withdrawal.",
            }
        expected_otp = request.session.get(session_key, "")
        if not expected_otp or submitted_otp != expected_otp:
            return False, {"message": "Invalid OTP.", "errors": {"otp_code": ["Invalid OTP."]}}
        request.session.pop(session_key, None)

    try:
        with transaction.atomic():
            locked_user = User.objects.select_for_update().get(id=user.id)
            if filter_real_ledger_transactions(
                Transaction.objects.select_for_update().filter(
                    actor=locked_user,
                    request_uid=request_uid,
                )
            ).exists():
                return False, {"message": "Duplicate withdrawal request blocked."}
            duplicate_cutoff = timezone.now() - timedelta(seconds=8)
            if filter_real_ledger_transactions(
                Transaction.objects.filter(
                    actor=locked_user,
                    tx_type=Transaction.TxType.CLIENT_WITHDRAW,
                    status=Transaction.Status.PENDING,
                    amount=amount,
                    payment_gateway=gateway,
                    created_at__gte=duplicate_cutoff,
                )
            ).exists():
                return False, {"message": "Duplicate withdrawal blocked. Please wait a moment."}

            wallet_bal = Decimal(str(locked_user.wallet_balance or 0))
            pending_before = Decimal(str(locked_user.pending_withdraw or 0))
            if amount <= 0:
                return False, {"message": "Withdrawal amount must be greater than zero."}
            # Pending wallet→* internal transfers also reduce spendable balance.
            from transactions.models import InternalTransfer as _IT

            pending_xfer = (
                _IT.objects.select_for_update()
                .filter(
                    user=locked_user,
                    from_account="WALLET",
                    status=_IT.Status.PENDING,
                )
                .aggregate(s=Sum("amount"))["s"]
                or 0
            )
            available = wallet_bal - pending_before - Decimal(str(pending_xfer))
            if available < amount:
                return False, {
                    "message": "Insufficient wallet balance for this withdrawal (pending requests reduce available funds).",
                }

            locked_user.pending_withdraw = pending_before + amount
            locked_user.save(update_fields=["pending_withdraw"])
            refreshed = User.objects.select_for_update().get(id=locked_user.id)

            tx = Transaction.objects.create(
                tx_type=Transaction.TxType.CLIENT_WITHDRAW,
                status=Transaction.Status.PENDING,
                actor=locked_user,
                amount=amount,
                currency=form.cleaned_data["currency"],
                reference=form.cleaned_data.get("reference", "") or "",
                account_details=account_details,
                payment_gateway=gateway,
                notes=form.cleaned_data.get("notes", "") or "Withdraw request from client portal.",
                request_uid=request_uid,
                balance_snapshot_wallet=refreshed.wallet_balance,
                balance_snapshot_pending=refreshed.pending_withdraw,
            )
            if refreshed.wallet_balance != wallet_bal:
                raise ValueError("Wallet balance changed unexpectedly during withdrawal submit")
            if refreshed.pending_withdraw != pending_before + amount:
                raise ValueError("Pending withdrawal reservation mismatch")

            BalanceLedger.objects.create(
                user=locked_user,
                entry_type=BalanceLedger.EntryType.WITHDRAW_HOLD,
                amount=amount,
                currency=tx.currency,
                wallet_before=wallet_bal,
                wallet_after=refreshed.wallet_balance,
                pending_before=pending_before,
                pending_after=refreshed.pending_withdraw,
                reference=str(tx.id),
                note="Withdrawal requested — amount reserved until admin approval (wallet not debited yet)",
            )
    except Exception:
        logger.exception("API withdrawal create failed", extra={"user_id": user.id})
        return False, {"message": "Unable to create withdrawal request. Please retry."}

    try:
        from enterprise.staff_notify import broadcast_staff_notification

        wdr_tok = f"[withdraw_tx:{tx.id}]"
        submitted_local = timezone.localtime(timezone.now()).strftime("%Y-%m-%d %H:%M")
        broadcast_staff_notification(
            "New Withdrawal Request",
            f"{wdr_tok} {user.display_name()} · {amount} {tx.currency} · "
            f"{gateway.get_payment_method_display()} ({gateway.name}) · {submitted_local} · Ref #{tx.id}",
            action_url=reverse("admin-pending-withdraw"),
            dedupe_body_contains=wdr_tok,
        )
    except Exception:
        logger.exception("Withdrawal staff notification failed", extra={"tx_id": tx.id})

    try:
        send_event_email(
            "withdrawal_submitted",
            to_email=user.email,
            user=user,
            extra_context={"amount": f"{amount} {form.cleaned_data['currency']}", "status": "Pending"},
        )
    except Exception:
        logger.exception("Withdrawal submitted email failed", extra={"tx_id": tx.id})

    return True, {
        "otp_required": False,
        "transaction_id": tx.id,
        "status": tx.status,
        "amount": str(tx.amount),
        "currency": tx.currency,
        "request_uid": request_uid,
        "message": "Your withdrawal request has been successfully submitted",
    }


def wallet_summary(user) -> dict:
    user.refresh_from_db(fields=["wallet_balance", "pending_withdraw"])
    ws = WalletTreasurySettings.get_solo()
    wallet_balance = _wallet_balance_for_user(user)
    reserved = Decimal(str(user.pending_withdraw or 0))
    available = max(Decimal("0"), wallet_balance - reserved)
    total_deposit = (
        filter_real_ledger_transactions(
            Transaction.objects.filter(
                actor=user,
                tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT],
                status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            )
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    return {
        "wallet_system_enabled": ws.wallet_system_enabled,
        "wallet_balance": str(wallet_balance),
        "pending_withdraw": str(reserved),
        "available_balance": str(available),
        "total_deposits": str(total_deposit),
        "allow_deposits": ws.allow_deposits_to_wallet and not ws.wallet_deposit_maintenance,
        "allow_withdrawals": ws.allow_withdrawals_from_wallet and not ws.wallet_withdraw_maintenance,
        "min_deposit": str(ws.wallet_min_deposit),
        "max_deposit": str(ws.wallet_max_deposit),
        "min_withdraw": str(ws.wallet_min_withdraw),
        "max_withdraw": str(ws.wallet_max_withdraw),
        "allowed_crypto_networks": list(ALLOWED_NETWORKS),
    }


def serialize_transaction(tx: Transaction) -> dict:
    return {
        "id": tx.id,
        "tx_type": tx.tx_type,
        "status": tx.status,
        "amount": str(tx.amount),
        "currency": tx.currency,
        "reference": tx.reference,
        "notes": tx.notes,
        "account_details": getattr(tx, "account_details", "") or "",
        "gateway": tx.payment_gateway.name if tx.payment_gateway_id else None,
        "gateway_id": tx.payment_gateway_id,
        "created_at": tx.created_at.isoformat() if tx.created_at else None,
    }


def list_user_transactions(user, *, tx_types=None, limit=50):
    qs = Transaction.objects.filter(actor=user).select_related("payment_gateway").order_by("-created_at")
    if tx_types:
        qs = qs.filter(tx_type__in=tx_types)
    qs = filter_real_ledger_transactions(qs)
    return [serialize_transaction(tx) for tx in qs[:limit]]
