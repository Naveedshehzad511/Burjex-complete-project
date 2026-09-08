"""
Match2Pay webhook: parse payloads, idempotently credit wallet or trading account on DONE.
"""

from __future__ import annotations

import logging
from decimal import Decimal, InvalidOperation
from typing import Any

from django.db import transaction as db_transaction
from django.utils import timezone

logger = logging.getLogger(__name__)


def _unwrap_payload(data: Any) -> dict:
    if not isinstance(data, dict):
        return {}
    for key in ("data", "result", "payload", "payment", "event"):
        inner = data.get(key)
        if isinstance(inner, dict):
            return inner
        if isinstance(inner, list) and inner and isinstance(inner[0], dict):
            return inner[0]
    return data


def _pick_status(parsed: dict) -> str:
    node = _unwrap_payload(parsed)
    if not isinstance(node, dict):
        node = parsed if isinstance(parsed, dict) else {}
    for k in ("status", "payment_status", "state", "event_status"):
        v = node.get(k)
        if v is not None and str(v).strip():
            return str(v).strip().lower()
    return ""


def _is_completed_status(s: str) -> bool:
    return s in ("completed", "complete", "paid", "success", "confirmed", "done", "settled")


def _pick_payment_id(parsed: dict) -> str:
    node = _unwrap_payload(parsed)
    if not isinstance(node, dict):
        node = parsed if isinstance(parsed, dict) else {}
    for k in (
        "paymentId",
        "payment_id",
        "id",
        "reference",
        "invoice_id",
        "invoiceId",
        "deposit_id",
        "depositId",
        "payment_reference",
    ):
        v = node.get(k)
        if v is not None and str(v).strip():
            return str(v).strip()
    return ""


def _pick_txid(parsed: dict) -> str:
    node = _unwrap_payload(parsed)
    if not isinstance(node, dict):
        node = parsed if isinstance(parsed, dict) else {}
    for k in ("txid", "tx_hash", "txHash", "transaction_hash", "hash", "blockchain_txid"):
        v = node.get(k)
        if v is not None and str(v).strip():
            return str(v).strip()[:200]
    info = node.get("cryptoTransactionInfo") or parsed.get("cryptoTransactionInfo")
    if isinstance(info, list) and info and isinstance(info[0], dict):
        v = info[0].get("txid") or info[0].get("txHash")
        if v is not None and str(v).strip():
            return str(v).strip()[:200]
    return ""


def _pick_book_currency(parsed: dict, fallback: str = "USD") -> str:
    """Book in Match2Pay finalCurrency (fiat), not the on-chain ticker."""
    node = _unwrap_payload(parsed)
    if not isinstance(node, dict):
        node = parsed if isinstance(parsed, dict) else {}
    for k in ("finalCurrency", "settlementCurrency"):
        v = node.get(k)
        if v is not None and str(v).strip():
            cur = str(v).strip().upper()[:10]
            if cur in {"USX", "UST", "USB", "USDT"}:
                return "USD"
            return cur
    fb = (fallback or "USD").upper()[:10]
    if fb in {"USX", "UST", "USB", "USDT"}:
        return "USD"
    return fb or "USD"


def _pick_book_amount(parsed: dict) -> Decimal | None:
    """Credit finalAmount (fiat). Never book raw on-chain transactionAmount."""
    node = _unwrap_payload(parsed)
    if not isinstance(node, dict):
        node = parsed if isinstance(parsed, dict) else {}
    for k in ("finalAmount", "settlementAmount"):
        v = node.get(k)
        if v is None:
            continue
        try:
            d = Decimal(str(v))
            if d > 0:
                return d
        except (InvalidOperation, TypeError, ValueError):
            continue
    return None


def _target_trading_account(row) -> str:
    raw = row.raw_create_response if isinstance(row.raw_create_response, dict) else {}
    for key in ("trading_account", "tradingAccount", "tradingAccountLogin"):
        val = str(raw.get(key) or "").strip()
        if val and val.lower() != "wallet":
            return val
    return ""


def _credit_trading_account(*, user, login: str, amount: Decimal, payment_id: str) -> tuple[bool, str]:
    from admin_panel.models import TradingAccount
    from btrader_integration.services import deposit_btrader_balance, is_btrader_account_row, sync_account as sync_btrader

    t_acc = (
        TradingAccount.objects.select_related("mt5_account", "mt5_account__group")
        .filter(account_number=login, user=user)
        .first()
    )
    if not t_acc:
        return False, "trading_account_not_found"
    platform_login = str(getattr(getattr(t_acc, "mt5_account", None), "login_id", None) or login)
    if is_btrader_account_row(trading_account=t_acc):
        deposit_btrader_balance(
            login=platform_login,
            amount=float(amount),
            comment=f"Match2Pay {payment_id}",
            external_ref=f"m2p-{payment_id}"[:80],
        )
        t_acc.refresh_from_db()
        if t_acc.mt5_account_id:
            t_acc.mt5_account.refresh_from_db()
            t_acc.balance = Decimal(str(t_acc.mt5_account.balance or 0))
            t_acc.save(update_fields=["balance", "updated_at"])
        try:
            sync_btrader(platform_login)
        except Exception:
            logger.warning("BTrader post-Match2Pay sync failed login=%s", platform_login, exc_info=True)
        return True, "btrader"
    from mt5_integration.services import mt5_balance_deposit, sync_account

    mt5_balance_deposit(int(platform_login), float(amount), f"Match2Pay {payment_id}")
    try:
        sync_account(int(platform_login))
    except Exception:
        logger.warning("MT5 post-Match2Pay sync failed login=%s", platform_login, exc_info=True)
    return True, "mt5"


def credit_match2pay_if_completed(
    *,
    parsed: dict,
    raw_payload: dict | None = None,
) -> tuple[bool, str]:
    """
    If payload indicates completion (DONE), credit wallet or the selected trading account once.

    Books Match2Pay ``finalAmount`` / ``finalCurrency`` (fiat), never on-chain ``transactionAmount``.
    """
    from accounts.models import User
    from transactions.models import BalanceLedger, Match2PayTransaction, Transaction

    status = _pick_status(parsed)
    if not status or not _is_completed_status(status):
        return True, "ignored_non_completed"

    payment_id = _pick_payment_id(parsed)
    if not payment_id:
        logger.warning("Match2Pay webhook completed event without payment_id")
        return True, "missing_payment_id"

    txid = _pick_txid(parsed)
    webhook_amt = _pick_book_amount(parsed)

    hook_user_id: int | None = None
    hook_amount: Decimal | None = None
    hook_currency: str | None = None
    hook_payment_id: str = payment_id

    try:
        with db_transaction.atomic():
            row = (
                Match2PayTransaction.objects.select_for_update()
                .select_related("user", "payment_gateway")
                .filter(payment_id=payment_id)
                .first()
            )
            if not row:
                logger.info("Match2Pay webhook: unknown payment_id=%s", payment_id)
                return True, "unknown_payment"

            if row.status == Match2PayTransaction.Status.COMPLETED:
                return True, "duplicate_ok"

            idem_uid = (f"{payment_id}:{txid}" if txid else payment_id)[:64]
            if Transaction.objects.filter(
                request_uid=idem_uid,
                status=Transaction.Status.COMPLETED,
            ).exists() or Transaction.objects.filter(
                request_uid=payment_id[:64],
                tx_type=Transaction.TxType.WALLET_DEPOSIT,
                status=Transaction.Status.COMPLETED,
            ).exists():
                row.status = Match2PayTransaction.Status.COMPLETED
                row.txid = txid or row.txid
                row.completed_at = timezone.now()
                row.save(update_fields=["status", "txid", "completed_at"])
                return True, "duplicate_tx_row"

            credit_amt = webhook_amt if webhook_amt is not None else row.amount
            if credit_amt <= 0:
                credit_amt = row.amount
            currency = _pick_book_currency(parsed, fallback=row.currency or "USD")

            user = User.objects.select_for_update().get(id=row.user_id)
            target_login = _target_trading_account(row)
            credited_via = "wallet"

            if target_login:
                ok_ta, via = _credit_trading_account(
                    user=user,
                    login=target_login,
                    amount=credit_amt,
                    payment_id=payment_id,
                )
                if not ok_ta:
                    logger.error(
                        "Match2Pay trading credit failed payment_id=%s login=%s",
                        payment_id,
                        target_login,
                    )
                    return False, "trading_credit_error"
                credited_via = via
                wallet_before = Decimal(str(user.wallet_balance or 0))
                wallet_after = wallet_before
            else:
                wallet_before = Decimal(str(user.wallet_balance or 0))
                user.wallet_balance = wallet_before + credit_amt
                user.save(update_fields=["wallet_balance"])
                wallet_after = user.wallet_balance

            notes = (
                f"Target Account: {target_login or 'Wallet'}\n"
                f"Crypto deposit confirmed ({credited_via})."
            )
            Transaction.objects.create(
                tx_type=Transaction.TxType.WALLET_DEPOSIT if not target_login else Transaction.TxType.CLIENT_DEPOSIT,
                status=Transaction.Status.COMPLETED,
                actor=user,
                amount=credit_amt,
                currency=currency,
                reference=f"M2P:{payment_id}",
                request_uid=idem_uid,
                payment_gateway=row.payment_gateway,
                notes=notes,
            )

            BalanceLedger.objects.create(
                user=user,
                entry_type=BalanceLedger.EntryType.DEPOSIT_APPROVE,
                amount=credit_amt,
                currency=currency,
                wallet_before=wallet_before,
                wallet_after=wallet_after,
                pending_before=Decimal(str(user.pending_withdraw or 0)),
                pending_after=Decimal(str(user.pending_withdraw or 0)),
                reference=payment_id[:120],
                note="Match2Pay crypto deposit",
            )

            row.status = Match2PayTransaction.Status.COMPLETED
            row.txid = txid or row.txid
            row.amount = credit_amt
            row.currency = currency
            row.completed_at = timezone.now()
            row.save(update_fields=["status", "txid", "amount", "currency", "completed_at"])

            hook_user_id = row.user_id
            hook_amount = credit_amt
            hook_currency = currency

    except Exception:
        logger.exception("Match2Pay webhook credit failed payment_id=%s", payment_id)
        return False, "credit_error"

    if hook_user_id is not None and hook_amount is not None and hook_currency:
        _post_credit_hooks(
            user_id=hook_user_id,
            amount=hook_amount,
            currency=hook_currency,
            payment_id=hook_payment_id,
        )
    return True, "credited"


def _post_credit_hooks(*, user_id: int, amount: Decimal, currency: str, payment_id: str) -> None:
    try:
        from django.urls import reverse

        from admin_panel.email_service import send_dynamic_email
        from admin_panel.templated_mail import send_event_email
        from enterprise.staff_notify import broadcast_staff_notification

        from accounts.models import User

        user = User.objects.filter(id=user_id).first()
        if not user:
            return

        try:
            from ib.level_progress import bump_team_deposit_from_transaction, maybe_queue_level_upgrade
            from ib.models import IBRequest

            bump_team_deposit_from_transaction(user_id, amount)
            lk = IBRequest.objects.filter(client_user_id=user_id, status=IBRequest.Status.APPROVED).first()
            if lk:
                maybe_queue_level_upgrade(lk.ib_user)
        except Exception:
            pass

        tok = f"[m2p_deposit:{payment_id}]"
        broadcast_staff_notification(
            "New Match2Pay deposit received",
            f"{tok} {user.display_name()} · {amount} {currency} · payment {payment_id}",
            action_url=reverse("admin-pending-deposit"),
            dedupe_body_contains=tok,
        )

        try:
            ok, _ = send_event_email(
                "deposit_approved",
                to_email=user.email,
                user=user,
                extra_context={"amount": f"{amount} {currency}"},
            )
            if not ok:
                send_dynamic_email(
                    user.email,
                    "Deposit received",
                    "Deposit received successfully.",
                    user=user,
                    event_key="deposit_approved",
                )
        except Exception:
            logger.exception("Match2Pay user deposit email failed user_id=%s", user_id)
    except Exception:
        logger.exception("Match2Pay post-credit hooks failed user_id=%s", user_id)
