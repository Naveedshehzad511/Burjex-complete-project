"""
Celery periodic tasks for BTrader account balance/equity synchronization.
"""

from __future__ import annotations

import logging

try:
    from celery import shared_task
except ImportError:  # pragma: no cover

    def shared_task(*args, **kwargs):
        def decorator(f):
            def delay(*a, **kw):
                return f(*a, **kw)

            f.delay = delay
            return f

        if args and callable(args[0]):
            return decorator(args[0])
        return decorator


logger = logging.getLogger(__name__)


@shared_task(name="btrader_integration.tasks.btrader_account_sync_task", bind=False)
def btrader_account_sync_task() -> None:
    """
    Periodic task: pull live balance/equity/freeMargin for all BTrader CRM accounts.
    Complements outbound webhooks so admin + app stay near real-time even if a
    webhook was missed.
    """
    from btrader_integration.services import is_btrader_configured, sync_all_btrader_accounts

    if not is_btrader_configured():
        logger.debug("BTrader sync skipped — integration not configured")
        return

    ok, errors = sync_all_btrader_accounts()
    if errors:
        logger.warning("BTrader sync completed with %s errors (%s ok)", errors, ok)
    else:
        logger.info("BTrader sync: %s accounts updated", ok)


@shared_task(name="btrader_integration.tasks.btrader_single_account_sync_task", bind=False)
def btrader_single_account_sync_task(login: str) -> None:
    from btrader_integration.services import is_btrader_configured, sync_account

    if not is_btrader_configured():
        return
    result = sync_account(str(login))
    if result:
        logger.info(
            "BTrader single sync login=%s: ok (balance=%s equity=%s)",
            login,
            result.get("balance"),
            result.get("equity"),
        )
    else:
        logger.warning("BTrader single sync login=%s: failed or no data", login)
