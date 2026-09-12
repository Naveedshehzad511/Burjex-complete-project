"""Signal handlers for automatic email notification triggers.

Listens to CRM model events and dispatches async email tasks.  The handlers
track the previous status before saving so status-based emails are only sent
when an object actually enters the relevant state.
"""

from __future__ import annotations

import logging

from django.contrib.auth.signals import user_logged_in
from django.db.models.signals import post_save, pre_save
from django.dispatch import receiver
from django.utils import timezone

logger = logging.getLogger(__name__)


def _fire_email_task(user_id: int | None, event_key: str, context: dict) -> None:
    """Queue an email task, handling import gracefully.

    In DEBUG / eager-Celery mode, dispatch on a daemon thread so SMTP failures
    cannot block login/API responses (Flutter clients otherwise hit timeouts).
    """
    try:
        from django.conf import settings

        from .tasks import send_dynamic_email_task

        def _dispatch() -> None:
            try:
                send_dynamic_email_task.delay(user_id, event_key, context)
            except Exception as exc:  # pragma: no cover - SMTP/broker errors
                logger.error("Failed to queue email task %s: %s", event_key, exc)

        eager = bool(getattr(settings, "CELERY_TASK_ALWAYS_EAGER", False))
        if getattr(settings, "DEBUG", False) or eager:
            import threading

            threading.Thread(target=_dispatch, daemon=True, name=f"email-{event_key}").start()
            return

        _dispatch()
    except Exception as exc:
        logger.error("Failed to queue email task %s: %s", event_key, exc)


def _remember_previous_status(instance, sender) -> None:
    """Attach the previous DB status to the instance before save."""
    if not getattr(instance, "pk", None):
        instance._email_previous_status = None
        return
    try:
        previous = sender.objects.only("status").filter(pk=instance.pk).first()
        instance._email_previous_status = getattr(previous, "status", None)
    except Exception:
        instance._email_previous_status = None


def _status_changed(instance) -> bool:
    previous = getattr(instance, "_email_previous_status", None)
    return previous is None or previous != getattr(instance, "status", None)


# ---------------------------------------------------------------------------
# 1. User/auth signals
# ---------------------------------------------------------------------------

@receiver(post_save, sender="accounts.User")
def on_user_created(sender, instance, created, **kwargs):
    """Send welcome email when a new client account is created."""
    if not created or not instance.email:
        return
    if getattr(instance, "_skip_auth_emails", False):
        return
    if (getattr(instance, "google_sub", "") or "").strip() or (getattr(instance, "apple_sub", "") or "").strip():
        return

    _fire_email_task(
        user_id=instance.pk,
        event_key="welcome_email",
        context={
            "to_email": instance.email,
            "user_name": instance.display_name(),
        },
    )


@receiver(user_logged_in)
def on_user_logged_in(sender, request, user, **kwargs):
    """Send a login alert after successful user login."""
    from django.conf import settings

    # Local/dev SMTP is often misconfigured; never block API login on it.
    if getattr(settings, "DEBUG", False):
        return

    if not getattr(user, "email", ""):
        return

    ip_address = ""
    if request is not None:
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
        ip_address = (forwarded.split(",")[0].strip() if forwarded else request.META.get("REMOTE_ADDR", "")) or ""

    _fire_email_task(
        user_id=user.pk,
        event_key="login_alert",
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "login_time": timezone.now().strftime("%Y-%m-%d %H:%M"),
            "ip_address": ip_address,
        },
    )


# ---------------------------------------------------------------------------
# 2. Transaction signals
# ---------------------------------------------------------------------------

@receiver(pre_save, sender="transactions.Transaction")
def remember_transaction_status(sender, instance, **kwargs):
    _remember_previous_status(instance, sender)


@receiver(post_save, sender="transactions.Transaction")
def on_transaction_status_change(sender, instance, created, **kwargs):
    """Send deposit/withdrawal confirmation when a transaction is approved."""
    if created or not _status_changed(instance):
        return

    status = getattr(instance, "status", "")
    if status not in ("APPROVED", "COMPLETED"):
        return

    user = getattr(instance, "actor", None)
    if not user or not getattr(user, "email", ""):
        return

    from transactions.models import Transaction

    event_key = None
    if tx_type := getattr(instance, "tx_type", ""):
        if tx_type in (Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT):
            event_key = "deposit_confirmation"
        elif tx_type in (Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW):
            event_key = "withdrawal_confirmation"

    if not event_key:
        return

    _fire_email_task(
        user_id=user.pk,
        event_key=event_key,
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "amount": f"{instance.amount} {instance.currency}" if instance.amount else "",
            "currency": getattr(instance, "currency", "USD"),
            "reference": getattr(instance, "reference", ""),
            "date": str(getattr(instance, "processed_at", "") or ""),
        },
    )


# ---------------------------------------------------------------------------
# 3. KYCRequest signals
# ---------------------------------------------------------------------------

_KYC_APPROVED_STATUSES = {"APPROVED", "FULLY_APPROVED"}
_KYC_REJECTED_STATUSES = {"REJECTED"}


@receiver(pre_save, sender="admin_panel.KYCRequest")
def remember_kyc_status(sender, instance, **kwargs):
    _remember_previous_status(instance, sender)


@receiver(post_save, sender="admin_panel.KYCRequest")
def on_kyc_status_change(sender, instance, created, **kwargs):
    """Send KYC approved/rejected email when status transitions."""
    if created or not _status_changed(instance):
        return

    status = (getattr(instance, "status", "") or "").upper()
    user = getattr(instance, "user", None)
    if not user or not getattr(user, "email", ""):
        return

    if status in _KYC_APPROVED_STATUSES:
        event_key = "kyc_approved"
    elif status in _KYC_REJECTED_STATUSES:
        event_key = "kyc_rejected"
    else:
        return

    _fire_email_task(
        user_id=user.pk,
        event_key=event_key,
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "reason": getattr(instance, "rejection_reason", ""),
            "date": str(getattr(instance, "approved_at", "") or getattr(instance, "rejected_at", "") or ""),
        },
    )


# ---------------------------------------------------------------------------
# 4. Support Ticket signals
# ---------------------------------------------------------------------------

@receiver(pre_save, sender="live_chat.SupportTicket")
def remember_support_ticket_status(sender, instance, **kwargs):
    _remember_previous_status(instance, sender)


@receiver(post_save, sender="live_chat.SupportTicket")
def on_support_ticket_change(sender, instance, created, **kwargs):
    """Send notification when a ticket is created or its status changes."""
    user = getattr(instance, "user", None)
    if not user or not getattr(user, "email", ""):
        return

    if created:
        event_key = "ticket_created"
    else:
        if not _status_changed(instance):
            return
        status = (getattr(instance, "status", "") or "").upper()
        if status == "CLOSED":
            event_key = "ticket_closed"
        elif status == "RESOLVED":
            event_key = "ticket_resolved"
        else:
            event_key = "ticket_status_updated"

    _fire_email_task(
        user_id=user.pk,
        event_key=event_key,
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "ticket_number": getattr(instance, "ticket_number", ""),
            "ticket_subject": getattr(instance, "subject", ""),
            "ticket_status": getattr(instance, "status", ""),
        },
    )


@receiver(post_save, sender="live_chat.SupportTicketReply")
def on_ticket_reply_created(sender, instance, created, **kwargs):
    """Send notification when an admin replies to a client's ticket."""
    if not created or not getattr(instance, "is_admin", False):
        return

    ticket = getattr(instance, "ticket", None)
    if not ticket:
        return

    user = getattr(ticket, "user", None)
    if not user or not getattr(user, "email", ""):
        return

    _fire_email_task(
        user_id=user.pk,
        event_key="ticket_reply",
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "ticket_number": getattr(ticket, "ticket_number", ""),
            "ticket_subject": getattr(ticket, "subject", ""),
            "reply_message": getattr(instance, "message", ""),
        },
    )


# ---------------------------------------------------------------------------
# 5. IB Request signals
# ---------------------------------------------------------------------------

@receiver(pre_save, sender="ib.IBRequest")
def remember_ib_request_status(sender, instance, **kwargs):
    _remember_previous_status(instance, sender)


@receiver(post_save, sender="ib.IBRequest")
def on_ib_request_status_change(sender, instance, created, **kwargs):
    """Send registration and approval/rejection emails for IB applications."""
    user = getattr(instance, "ib_user", None) or getattr(instance, "client_user", None)
    if not user or not getattr(user, "email", ""):
        return

    if created:
        _fire_email_task(
            user_id=user.pk,
            event_key="ib_registration",
            context={
                "to_email": user.email,
                "user_name": user.display_name(),
                "ib_status": getattr(instance, "status", ""),
                "ib_reason": getattr(instance, "notes", ""),
            },
        )
        return

    if not _status_changed(instance):
        return

    status = (getattr(instance, "status", "") or "").upper()
    if status == "APPROVED":
        event_key = "ib_request_approved"
    elif status == "REJECTED":
        event_key = "ib_request_rejected"
    else:
        return

    _fire_email_task(
        user_id=user.pk,
        event_key=event_key,
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "ib_status": status,
            "ib_reason": getattr(instance, "notes", ""),
        },
    )


# ---------------------------------------------------------------------------
# 6. Internal transfer signals
# ---------------------------------------------------------------------------

@receiver(pre_save, sender="transactions.InternalTransfer")
def remember_internal_transfer_status(sender, instance, **kwargs):
    _remember_previous_status(instance, sender)


@receiver(post_save, sender="transactions.InternalTransfer")
def on_internal_transfer_status_change(sender, instance, created, **kwargs):
    """Send confirmation when an internal transfer is approved."""
    if not _status_changed(instance):
        return

    if (getattr(instance, "status", "") or "").upper() != "APPROVED":
        return

    user = getattr(instance, "user", None)
    if not user or not getattr(user, "email", ""):
        return

    _fire_email_task(
        user_id=user.pk,
        event_key="internal_transfer_confirmation",
        context={
            "to_email": user.email,
            "user_name": user.display_name(),
            "amount": f"{instance.amount} {instance.currency}" if instance.amount else "",
            "currency": getattr(instance, "currency", "USD"),
            "from_account": getattr(instance, "from_account", ""),
            "to_account": getattr(instance, "to_account", ""),
            "transfer_type": getattr(instance, "transfer_type", ""),
            "date": str(getattr(instance, "processed_at", "") or ""),
        },
    )
