"""
Celery periodic tasks for MT5 account synchronization.

Beat schedule entry (added automatically to settings.CELERY_BEAT_SCHEDULE):
  - mt5-account-sync-60s: runs sync_all_active_accounts() every 60 seconds
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


@shared_task(name="mt5_integration.tasks.mt5_account_sync_task", bind=False)
def mt5_account_sync_task() -> None:
    """
    Periodic task: fetch live balance/equity/margin for all active MT5 accounts
    from the MT5 Manager API and update local CRM snapshots.

    Scheduled every 60 seconds in CELERY_BEAT_SCHEDULE (see settings.py).
    """
    from mt5_integration.services import is_mt5_configured, sync_all_active_accounts, sync_mt5_deals, sync_mt5_trading_deals
    if not is_mt5_configured():
        logger.debug("MT5 sync skipped — MT5_SERVER_HOST / MT5_MANAGER_LOGIN / MT5_MANAGER_PASS not set")
        return

    ok, errors = sync_all_active_accounts()
    if errors:
        logger.warning("MT5 sync completed with %s errors (%s ok)", errors, ok)
    else:
        logger.info("MT5 sync: %s accounts updated", ok)
        
    try:
        deal_ok, deal_errors = sync_mt5_deals()
        if deal_errors:
            logger.warning("MT5 deal sync completed with %s errors (%s ok)", deal_errors, deal_ok)
    except Exception as exc:
        logger.warning("MT5 deal sync failed: %s", exc)
        
    try:
        t_deal_ok, t_deal_errors = sync_mt5_trading_deals()
        if t_deal_errors:
            logger.warning("MT5 trading deal sync completed with %s errors (%s ok)", t_deal_errors, t_deal_ok)
    except Exception as exc:
        logger.warning("MT5 trading deal sync failed: %s", exc)


@shared_task(name="mt5_integration.tasks.mt5_single_account_sync_task", bind=False)
def mt5_single_account_sync_task(mt5_login: int) -> None:
    """
    On-demand task: refresh a single MT5 account snapshot by login.
    Enqueue via: mt5_single_account_sync_task.delay(login_id)
    """
    from mt5_integration.services import is_mt5_configured, sync_account

    if not is_mt5_configured():
        logger.debug("MT5 single sync skipped — not configured")
        return

    result = sync_account(int(mt5_login))
    if result:
        logger.info("MT5 single sync login=%s: ok (balance=%.2f)", mt5_login, result.get("Balance", 0))
    else:
        logger.warning("MT5 single sync login=%s: failed or no data", mt5_login)
