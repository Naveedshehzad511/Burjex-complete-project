"""Celery tasks for email_notifications.

Provides async email dispatch with exponential backoff on SMTP failures.
Falls back to synchronous execution when Celery is not available.
"""

from __future__ import annotations

import logging
from smtplib import SMTPException
from typing import Any

logger = logging.getLogger(__name__)

try:
    from celery import shared_task

    @shared_task(
        bind=True,
        name="email_notifications.tasks.send_dynamic_email_task",
        max_retries=5,
        default_retry_delay=30,
        autoretry_for=(SMTPException, ConnectionError, OSError, TimeoutError),
        retry_backoff=True,
        retry_backoff_max=600,
        retry_jitter=True,
        acks_late=True,
    )
    def send_dynamic_email_task(
        self,
        user_id: int | None,
        event_key: str,
        context_data: dict[str, Any],
    ) -> dict[str, str]:
        """Async email dispatch with exponential backoff.

        Args:
            user_id: The recipient user's PK (or None for non-user recipients).
            event_key: Template routing key (e.g. 'welcome_email').
            context_data: Dict of template variables (must include 'to_email'
                          when user_id is None).

        Returns:
            Dict with status and event_key for Celery result tracking.
        """
        from .utils import send_notification

        try:
            success = send_notification(user_id, event_key, context_data)
            return {
                "status": "sent" if success else "skipped",
                "event_key": event_key,
            }
        except (SMTPException, ConnectionError, OSError, TimeoutError):
            # Let Celery's autoretry_for handle the retry
            raise
        except Exception as exc:
            logger.error(
                "send_dynamic_email_task hard failure: event_key=%s user_id=%s error=%s",
                event_key,
                user_id,
                exc,
            )
            return {
                "status": "failed",
                "event_key": event_key,
                "error": str(exc)[:500],
            }

except ImportError:
    # Celery not installed — provide a synchronous fallback
    def send_dynamic_email_task(user_id, event_key, context_data):
        """Synchronous fallback when Celery is not available."""
        from .utils import send_notification

        success = send_notification(user_id, event_key, context_data)
        return {
            "status": "sent" if success else "failed",
            "event_key": event_key,
        }

    # Provide .delay() for callers that expect a Celery-like interface
    send_dynamic_email_task.delay = send_dynamic_email_task  # type: ignore[attr-defined]
