"""Celery tasks for payment integrations."""

from __future__ import annotations

import logging
from datetime import timedelta

from celery import shared_task
from django.utils import timezone

logger = logging.getLogger(__name__)


@shared_task(name="transactions.match2pay_poll_pending_deposits")
def match2pay_poll_pending_deposits() -> dict:
    """
    Mark stale sessions expired and poll Match2Pay for pending crypto deposits (~30s beat).

    Credits wallet idempotently via the same processor as webhooks when status is completed.
    """
    from admin_panel.models import Match2PayIntegrationSettings
    from transactions.models import Match2PayTransaction
    from transactions.services.match2pay_client import fetch_deposit_status
    from transactions.services.match2pay_webhook_processor import credit_match2pay_if_completed

    settings = Match2PayIntegrationSettings.get_solo()
    if not settings.enabled:
        return {"ok": True, "skipped": "integration_disabled"}
    if not (settings.api_token or "").strip():
        return {"ok": True, "skipped": "missing_api_token"}

    now = timezone.now()
    expire_cutoff = now - timedelta(minutes=30)

    expired_n = Match2PayTransaction.objects.filter(
        status=Match2PayTransaction.Status.PENDING,
        created_at__lt=expire_cutoff,
    ).update(status=Match2PayTransaction.Status.EXPIRED)

    pending_qs = Match2PayTransaction.objects.filter(
        status=Match2PayTransaction.Status.PENDING,
        created_at__gte=expire_cutoff,
    ).order_by("id")[:400]

    polled = 0
    credited = 0
    errors = 0
    for row in pending_qs:
        polled += 1
        ok, data = fetch_deposit_status(settings, row.payment_id)
        if not ok:
            errors += 1
            continue
        if not isinstance(data, dict):
            continue
        try:
            ok_credit, detail = credit_match2pay_if_completed(parsed=data, raw_payload=data)
            if ok_credit and detail == "credited":
                credited += 1
        except Exception:
            logger.exception("Match2Pay poller credit error payment_id=%s", row.payment_id)
            errors += 1

    return {"ok": True, "expired": expired_n, "polled": polled, "credited": credited, "errors": errors}
