from __future__ import annotations

import logging
from celery import shared_task
from .services import sync_mt5_deals_and_calculate_rebates

logger = logging.getLogger(__name__)


@shared_task(name="ib.tasks.frequent_ib_rebate_sync_task", bind=False)
def frequent_ib_rebate_sync_task() -> dict:
    """
    Frequent Celery beat task to automatically fetch MT5 closed trades,
    calculate symbol-wise rebates for live accounts, credit the IB wallet,
    and log the processed deals. 
    Only queries last 1 day to reduce MT5 API load for frequent polling.
    """
    logger.info("Executing periodic frequent IB rebate sync task...")
    try:
        res = sync_mt5_deals_and_calculate_rebates(days_back=1)
        logger.info(f"Frequent IB rebate sync task completed: {res}")
        return res
    except Exception as exc:
        logger.error(f"Frequent IB rebate sync task failed: {exc}", exc_info=True)
        return {"status": "error", "message": str(exc)}

@shared_task(name="ib.tasks.daily_ib_rebate_sync_task", bind=False)
def daily_ib_rebate_sync_task() -> dict:
    """
    Daily Celery beat task to automatically fetch MT5 closed trades from the last 30 days
    to catch any missed syncs.
    """
    logger.info("Executing periodic daily IB rebate sync task (30 days)...")
    try:
        res = sync_mt5_deals_and_calculate_rebates(days_back=30)
        logger.info(f"Daily IB rebate sync task completed: {res}")
        return res
    except Exception as exc:
        logger.error(f"Daily IB rebate sync task failed: {exc}", exc_info=True)
        return {"status": "error", "message": str(exc)}
