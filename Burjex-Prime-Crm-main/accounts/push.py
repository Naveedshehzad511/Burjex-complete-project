"""Push delivery for deposit / withdrawal notifications (FCM HTTP v1; iOS via FCM's APNs bridge).

Configure with env:
  FCM_PROJECT_ID              Firebase project id
  FCM_SERVICE_ACCOUNT_FILE    path to the service-account JSON (needs google-auth + requests)
When unset, sending is recorded as failed so it is visible, never silent.
"""

from __future__ import annotations

import logging
import os

from celery import shared_task
from celery.exceptions import Retry
from django.db import IntegrityError, transaction
from django.db.models.signals import post_save
from django.dispatch import receiver

from accounts.models import ClientNotification, PushDelivery, PushDevice

logger = logging.getLogger(__name__)

PUSH_TYPES = {ClientNotification.NotificationType.DEPOSIT, ClientNotification.NotificationType.WITHDRAWAL}
_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_session = None


def _authed_session():
    global _session
    if _session is None:
        from google.auth.transport.requests import AuthorizedSession
        from google.oauth2 import service_account

        creds = service_account.Credentials.from_service_account_file(
            os.environ["FCM_SERVICE_ACCOUNT_FILE"], scopes=[_SCOPE]
        )
        _session = AuthorizedSession(creds)
    return _session


def _send_one(device: PushDevice, n: ClientNotification) -> tuple[bool, str, bool]:
    """Returns (ok, error, token_dead)."""
    project = os.environ.get("FCM_PROJECT_ID", "").strip()
    if not project or not os.environ.get("FCM_SERVICE_ACCOUNT_FILE"):
        return False, "FCM not configured", False
    body = {
        "message": {
            "token": device.token,
            "notification": {"title": n.title, "body": n.message},
            "data": {"type": n.notification_type, "notification_id": str(n.id)},
            "apns": {"headers": {"apns-priority": "10"}, "payload": {"aps": {"sound": "default"}}},
            "android": {"priority": "HIGH"},
        }
    }
    try:
        r = _authed_session().post(
            f"https://fcm.googleapis.com/v1/projects/{project}/messages:send", json=body, timeout=10
        )
    except Exception as exc:  # network / auth
        return False, str(exc)[:250], False
    if r.status_code == 200:
        return True, "", False
    dead = r.status_code in (400, 404) and ("UNREGISTERED" in r.text or "INVALID_ARGUMENT" in r.text)
    return False, f"{r.status_code} {r.text[:200]}", dead


@shared_task(name="accounts.push.send_notification_push", bind=True, max_retries=3, default_retry_delay=15)
def send_notification_push(self, notification_id: int) -> dict:
    n = ClientNotification.objects.filter(pk=notification_id).first()
    if n is None:
        return {"sent": 0}
    sent = failed = 0
    for device in PushDevice.objects.filter(user_id=n.user_id, is_active=True):
        try:
            delivery, _ = PushDelivery.objects.get_or_create(notification=n, device=device)
        except IntegrityError:
            continue
        if delivery.status == "sent":
            continue  # idempotent on retry: never push the same notification twice
        ok, err, dead = _send_one(device, n)
        delivery.attempts += 1
        delivery.status = "sent" if ok else "failed"
        delivery.error = err
        delivery.save(update_fields=["attempts", "status", "error"])
        if ok:
            sent += 1
        else:
            failed += 1
            logger.warning("push failed user=%s device=%s: %s", n.user_id, device.pk, err)
            if dead:
                PushDevice.objects.filter(pk=device.pk).update(is_active=False, last_error=err[:255])
    if failed and sent == 0 and self.request.retries < self.max_retries:
        raise self.retry()
    return {"sent": sent, "failed": failed}


@receiver(post_save, sender=ClientNotification)
def _push_on_transaction_notification(sender, instance: ClientNotification, created: bool, **kwargs):
    if not created or instance.notification_type not in PUSH_TYPES:
        return

    def _enqueue():
        try:
            send_notification_push.delay(instance.pk)
        except Retry:
            pass  # eager mode surfaces the scheduled retry as an exception; the delivery row is already recorded
        except Exception as exc:  # a broker outage must never break the approval flow
            logger.warning("could not enqueue push for notification %s: %s", instance.pk, exc)

    transaction.on_commit(_enqueue)
