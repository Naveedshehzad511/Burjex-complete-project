"""
MT5 integration service — bridges the MT5Client protocol layer with Django models.

Reads MT5 connection credentials from environment variables (or Django settings):
  MT5_SERVER_HOST       – MT5 server hostname/IP (required)
  MT5_SERVER_PORT       – MT5 server port (default 443)
  MT5_MANAGER_LOGIN     – Manager login (integer, required)
  MT5_MANAGER_PASS      – Manager password (required)
  MT5_CONNECT_TIMEOUT   – TCP timeout in seconds (default 10)
  MT5_ENCRYPT_CONN      – "1" to enable AES-256-OFB link encryption (default 0)
"""

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from decimal import Decimal
from typing import Optional

from django.db import transaction
from django.utils import timezone

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────────────
# Connection settings (read from environment)
# ─────────────────────────────────────────────────────────────────────────────
def _get_mt5_settings() -> dict:
    try:
        from admin_panel.models import TradingPlatformIntegration
        row = TradingPlatformIntegration.objects.filter(platform=TradingPlatformIntegration.Platform.MT5).first()
        if row and row.enabled:
            ext = row.extended_config or {}
            try:
                port_val = int(ext.get("port") or 443)
            except (ValueError, TypeError):
                port_val = 443
            try:
                login_val = int(row.api_key or 0)
            except (ValueError, TypeError):
                login_val = 0
            if row.api_server_url and login_val and row.secret_key:
                return {
                    "host": row.api_server_url.strip(),
                    "port": port_val,
                    "login": login_val,
                    "password": row.secret_key.strip(),
                    "timeout": float(ext.get("timeout") or 10.0),
                    "encrypt": bool(ext.get("encrypt", False)),
                }
    except Exception as e:
        logger.warning("Failed to load MT5 settings from DB (falling back to env): %s", e)

    return {
        "host":    os.environ.get("MT5_SERVER_HOST", "").strip(),
        "port":    int(os.environ.get("MT5_SERVER_PORT", "443").strip() or "443"),
        "login":   int(os.environ.get("MT5_MANAGER_LOGIN", "0").strip() or "0"),
        "password": os.environ.get("MT5_MANAGER_PASS", "").strip(),
        "timeout": float(os.environ.get("MT5_CONNECT_TIMEOUT", "3").strip() or "3"),
        "encrypt": os.environ.get("MT5_ENCRYPT_CONN", "0").strip() in ("1", "true", "yes"),
    }


def is_mt5_configured() -> bool:
    """Return True if all required MT5 connection settings are present."""
    s = _get_mt5_settings()
    return bool(s["host"] and s["login"] and s["password"])


@contextmanager
def _mt5_client():
    """Context manager that yields a connected MT5Client or raises on misconfiguration."""
    from mt5_integration.client import MT5Client, MT5ConnectionError, MT5AuthError

    cfg = _get_mt5_settings()
    if not (cfg["host"] and cfg["login"] and cfg["password"]):
        raise RuntimeError(
            "MT5 integration not configured. Set MT5_SERVER_HOST, "
            "MT5_MANAGER_LOGIN and MT5_MANAGER_PASS environment variables."
        )
    with MT5Client(
        host=cfg["host"],
        port=cfg["port"],
        login=cfg["login"],
        password=cfg["password"],
        timeout=cfg["timeout"],
        use_encryption=cfg["encrypt"],
    ) as client:
        yield client


# ─────────────────────────────────────────────────────────────────────────────
# Account snapshot sync
# ─────────────────────────────────────────────────────────────────────────────
def sync_account(mt5_login_id: int) -> Optional[dict]:
    """
    Fetch live balance/equity/margin for a single MT5 login and persist to
    accounts.models.MT5Account.

    Returns the raw JSON dict returned by USER_ACCOUNT_GET, or None on error.
    """
    from accounts.models import MT5Account

    try:
        with _mt5_client() as client:
            data = client.user_account_get(mt5_login_id)
    except Exception as exc:
        logger.warning("MT5 sync_account(%s) failed: %s", mt5_login_id, exc)
        return None

    if not data:
        return None

    _persist_account_data(mt5_login_id, data)
    return data


def sync_all_active_accounts() -> tuple[int, int]:
    """
    Sync every active MT5Account row.

    Returns (success_count, error_count).
    """
    from accounts.models import MT5Account
    from mt5_integration.client import MT5APIError, MT5ConnectionError, MT5AuthError

    qs = MT5Account.objects.filter(status=MT5Account.Status.ACTIVE).values_list(
        "login_id", flat=True
    )
    # login_id is stored as CharField; convert to int for API call
    logins = list(qs)
    if not logins:
        logger.debug("MT5 sync: no active accounts to sync")
        return 0, 0

    try:
        ok_count = err_count = 0
        batch_size = 10
        for i in range(0, len(logins), batch_size):
            batch = logins[i:i+batch_size]
            try:
                with _mt5_client() as client:
                    for login in batch:
                        try:
                            login_int = int(login)
                            data = client.user_account_get(login_int)
                            if data:
                                _persist_account_data(login_int, data)
                                ok_count += 1
                        except MT5APIError as exc:
                            logger.debug("MT5 USER_ACCOUNT_GET(%s): retcode %s", login, exc.retcode)
                            err_count += 1
                        except Exception as exc:
                            logger.warning("MT5 account sync error for login %s: %s", login, exc)
                            err_count += 1
            except (MT5ConnectionError, MT5AuthError, RuntimeError) as exc:
                logger.error("MT5 connection/auth failed during bulk sync batch: %s", exc)
                return ok_count, err_count + (len(logins) - ok_count)
    except Exception as exc:
        logger.error("Unexpected error in sync_all_active_accounts: %s", exc)
        return ok_count, err_count + (len(logins) - ok_count)

    logger.info(
        "MT5 sync complete: %s ok, %s errors out of %s accounts",
        ok_count, err_count, len(logins),
    )
    return ok_count, err_count


def _persist_account_data(login_id: int, data: dict) -> None:
    """
    Save the live MT5 account snapshot into the accounts.MT5Account row.

    Field mapping (MT5 JSON → Django model):
      Login         → login_id  (PK lookup)
      Balance       → balance
      Equity        → equity
      MarginFree    → free_margin
      Profit        → unrealized_pnl
      Margin        → (used_margin = equity - free_margin, derived)
      Credit        → credit
    """
    from accounts.models import MT5Account

    try:
        balance     = Decimal(str(data.get("Balance",     0) or 0))
        equity      = Decimal(str(data.get("Equity",      0) or 0))
        free_margin = Decimal(str(data.get("MarginFree",  0) or 0))
        pnl         = Decimal(str(data.get("Profit",      0) or 0))
        credit      = Decimal(str(data.get("Credit",      0) or 0))

        updated = MT5Account.objects.filter(login_id=str(login_id)).update(
            balance=balance,
            equity=equity,
            free_margin=free_margin,
            unrealized_pnl=pnl,
            last_sync_at=timezone.now(),
        )
        if not updated:
            logger.debug(
                "MT5 persist: no MT5Account row found for login_id=%s (not in CRM)", login_id
            )
    except Exception as exc:
        logger.error("MT5 _persist_account_data(%s) DB error: %s", login_id, exc)


# ─────────────────────────────────────────────────────────────────────────────
# Account creation
# ─────────────────────────────────────────────────────────────────────────────
def create_mt5_account(
    crm_user,
    group: str,
    password: str,
    investor_password: str = "",
    leverage: int = 100,
    name: str = "",
    email: str = "",
    country: str = "",
    phone: str = "",
    comment: str = "",
) -> "MT5Account":
    """
    Create a new MT5 trading account via the Manager API and persist it in the
    CRM as an accounts.MT5Account linked to crm_user.

    Returns the created MT5Account instance.
    Raises RuntimeError / MT5* exceptions on failure.
    """
    from accounts.models import MT5Account, MT5Group

    full_name = name or (
        f"{crm_user.first_name} {crm_user.last_name}".strip() or crm_user.username
    )
    email_addr = email or getattr(crm_user, "email", "")

    with _mt5_client() as client:
        new_login = client.user_add(
            group=group,
            name=full_name,
            password=password,
            investor_password=investor_password or password,
            leverage=leverage,
            email=email_addr,
            country=country,
            phone=phone,
            comment=comment,
        )

    # Find or stub-create the MT5Group model entry (MT5Group.name is the unique key)
    mt5_group = MT5Group.objects.filter(name=group).first()
    if mt5_group is None:
        # Create a placeholder MT5Group so the FK constraint is satisfied.
        # The group record can be updated later with proper server/platform info.
        mt5_group, _ = MT5Group.objects.get_or_create(
            name=group,
            defaults={
                "crm_group_name": group,
                "platform_group_name": group,
                "platform": MT5Group.BrokerPlatform.MT5,
                "description": "Auto-created by MT5 API integration",
            },
        )

    with transaction.atomic():
        account = MT5Account.objects.create(
            user=crm_user,
            login_id=new_login,
            group=mt5_group,
            status=MT5Account.Status.ACTIVE,
            leverage=leverage,
        )
    logger.info(
        "Created MT5 account login=%s for user=%s in group=%s",
        new_login, crm_user.pk, group,
    )
    return account


# ─────────────────────────────────────────────────────────────────────────────
# Balance operations
# ─────────────────────────────────────────────────────────────────────────────
import time

def mt5_balance_deposit(mt5_login: int, amount: float, comment: str = "Deposit", check_unique: bool = True) -> None:
    """Credit the MT5 account balance (deposit)."""
    with _mt5_client() as client:
        if check_unique:
            current_time = int(time.time())
            from_time = current_time - (86400 * 30)  # Check last 30 days
            total = client.deal_get_total(mt5_login, from_time, current_time)
            if total > 0:
                offset = max(0, total - 100) # Only fetch the last 100 deals
                deals = client.deal_get_page(mt5_login, from_time, current_time, offset, 100)
                if any(d.get("Comment") == comment and d.get("Action") == 2 and abs(float(d.get("Profit", 0))) == abs(amount) for d in deals):
                    logger.info("MT5 deposit idempotency hit: %s", comment)
                    return # Already processed!
        client.user_deposit_change(mt5_login, abs(amount), comment, deal_type=2)
    logger.info("MT5 deposit: login=%s amount=%.2f", mt5_login, amount)


def mt5_balance_withdrawal(mt5_login: int, amount: float, comment: str = "Withdrawal", check_unique: bool = True) -> None:
    """Debit the MT5 account balance (withdrawal)."""
    with _mt5_client() as client:
        if check_unique:
            current_time = int(time.time())
            from_time = current_time - (86400 * 30)  # Check last 30 days
            total = client.deal_get_total(mt5_login, from_time, current_time)
            if total > 0:
                offset = max(0, total - 100) # Only fetch the last 100 deals
                deals = client.deal_get_page(mt5_login, from_time, current_time, offset, 100)
                # For withdrawals, Action is 2 and Profit is negative
                if any(d.get("Comment") == comment and d.get("Action") == 2 and abs(float(d.get("Profit", 0))) == abs(amount) for d in deals):
                    logger.info("MT5 withdrawal idempotency hit: %s", comment)
                    return # Already processed!
        # Negative amount = debit
        client.user_deposit_change(mt5_login, -abs(amount), comment, deal_type=2)
    logger.info("MT5 withdrawal: login=%s amount=%.2f", mt5_login, amount)


# ─────────────────────────────────────────────────────────────────────────────
# Password management
# ─────────────────────────────────────────────────────────────────────────────
def mt5_change_password(mt5_login: int, new_password: str, pass_type: str = "MAIN") -> None:
    """Change MT5 account password. pass_type: MAIN | INVESTOR."""
    with _mt5_client() as client:
        client.user_password_change(mt5_login, new_password, pass_type)
    logger.info("MT5 password changed: login=%s type=%s", mt5_login, pass_type)


# ─────────────────────────────────────────────────────────────────────────────
# Server info
# ─────────────────────────────────────────────────────────────────────────────
def get_server_info() -> dict:
    """
    Retrieve MT5 server common config (name, license info, totals).
    Returns empty dict when MT5 is not configured.
    """
    if not is_mt5_configured():
        return {}
    try:
        with _mt5_client() as client:
            return client.common_get()
    except Exception as exc:
        logger.warning("MT5 get_server_info failed: %s", exc)
        return {}


# ─────────────────────────────────────────────────────────────────────────────
# Deal sync
# ─────────────────────────────────────────────────────────────────────────────
def sync_mt5_deals() -> tuple[int, int]:
    """
    Fetch recent DEAL_BALANCE deals from MT5 for all active accounts,
    and create CRM Transactions for any direct deposits/withdrawals
    that the CRM doesn't already know about.
    """
    from accounts.models import MT5Account
    from transactions.models import Transaction

    qs = MT5Account.objects.filter(status=MT5Account.Status.ACTIVE).select_related("user")
    if not qs.exists():
        return 0, 0

    to_time = int(timezone.now().timestamp())
    from_time = to_time - 86400 * 30  # Last 30 days

    ok_count = err_count = 0

    try:
        batch_size = 10
        qs_list = list(qs)
        for i in range(0, len(qs_list), batch_size):
            batch = qs_list[i:i+batch_size]
            try:
                with _mt5_client() as client:
                    for acc in batch:
                        try:
                            login_int = int(acc.login_id)
                            total_deals = client.deal_get_total(login_int, from_time, to_time)
                            if total_deals > 0:
                                deals = client.deal_get_page(login_int, from_time, to_time, 0, min(total_deals, 5000))
                                for deal in deals:
                                    action = int(deal.get("Action", -1))
                                    if action == 2:  # DEAL_BALANCE
                                        ticket = str(deal.get("Deal", deal.get("Ticket", "")))
                                        if not ticket:
                                            continue
                                        ref = f"MT5DEAL_{ticket}"
                                        
                                        # Skip if it was initiated from CRM
                                        comment = deal.get("Comment", "")
                                        if "CRM Transfer" in comment:
                                            continue
        
                                        if not Transaction.objects.filter(reference=ref).exists():
                                            amount = Decimal(str(deal.get("Profit", 0)))
                                            if amount == 0:
                                                continue
                                                
                                            tx_type = Transaction.TxType.CLIENT_DEPOSIT if amount > 0 else Transaction.TxType.CLIENT_WITHDRAW
                                            
                                            with transaction.atomic():
                                                Transaction.objects.create(
                                                    actor=acc.user,
                                                    tx_type=tx_type,
                                                    status=Transaction.Status.COMPLETED,
                                                    amount=abs(amount),
                                                    currency="USD",
                                                    reference=ref,
                                                    account_details=f"MT5 Account: {login_int}",
                                                    notes=comment,
                                                    processed_at=timezone.now(),
                                                )
                                                ok_count += 1
                        except Exception as exc:
                            logger.warning("MT5 deal sync error for login %s: %s", acc.login_id, exc)
                            err_count += 1
            except Exception as exc:
                logger.error("MT5 connection failed during deal sync batch: %s", exc)
                return ok_count, qs.count()
    except Exception as exc:
        logger.error("MT5 connection failed during deal sync: %s", exc)
        return 0, qs.count()

    if ok_count > 0 or err_count > 0:
        logger.info("MT5 deal sync complete: %s new transactions, %s errors", ok_count, err_count)
    return ok_count, err_count


def sync_mt5_trading_deals() -> tuple[int, int]:
    """
    Fetch recent trading deals (Buy/Sell, entry/exit) from MT5 for all active accounts
    and sync them into mt5_integration.models.MT5Deal. This is used for the Risk Monitor.
    """
    from accounts.models import MT5Account
    from mt5_integration.models import MT5Deal
    from django.utils import timezone
    from decimal import Decimal

    qs = MT5Account.objects.filter(status=MT5Account.Status.ACTIVE).select_related("user")
    if not qs.exists():
        return 0, 0

    to_time = int(timezone.now().timestamp())
    # Sync last 1 hour of deals frequently, no need for 30 days if it runs every minute
    from_time = to_time - 3600  

    ok_count = err_count = 0

    try:
        batch_size = 10
        qs_list = list(qs)
        for i in range(0, len(qs_list), batch_size):
            batch = qs_list[i:i+batch_size]
            try:
                with _mt5_client() as client:
                    for acc in batch:
                        try:
                            login_int = int(acc.login_id)
                            total_deals = client.deal_get_total(login_int, from_time, to_time)
                            if total_deals > 0:
                                deals = client.deal_get_page(login_int, from_time, to_time, 0, min(total_deals, 5000))
                                
                                to_create = []
                                existing_tickets = set(MT5Deal.objects.filter(
                                    login=acc.login_id,
                                    time__gte=timezone.datetime.fromtimestamp(from_time, tz=timezone.utc)
                                ).values_list("deal_ticket", flat=True))
                                
                                for deal in deals:
                                    # 0: DEAL_BUY, 1: DEAL_SELL, 2: DEAL_BALANCE, etc.
                                    action = int(deal.get("Action", -1))
                                    if action not in (0, 1):
                                        continue
                                        
                                    ticket = str(deal.get("Deal", deal.get("Ticket", "")))
                                    if not ticket or ticket in existing_tickets:
                                        continue
                                        
                                    deal_time = deal.get("Time", 0)
                                    deal_dt = timezone.datetime.fromtimestamp(deal_time, tz=timezone.utc) if deal_time else timezone.now()
                                    
                                    to_create.append(MT5Deal(
                                        deal_ticket=ticket,
                                        order_ticket=str(deal.get("Order", "")),
                                        position_ticket=str(deal.get("PositionID", deal.get("Position", ""))),
                                        login=str(login_int),
                                        client=acc.user,
                                        symbol=deal.get("Symbol", ""),
                                        action=action,
                                        entry_type=int(deal.get("Entry", 0)),
                                        volume=Decimal(str(deal.get("Volume", 0))),
                                        price=Decimal(str(deal.get("Price", 0))),
                                        profit=Decimal(str(deal.get("Profit", 0))),
                                        commission=Decimal(str(deal.get("Commission", 0))),
                                        swap=Decimal(str(deal.get("Storage", 0))),
                                        time=deal_dt,
                                        time_msc=deal.get("TimeMsc", 0)
                                    ))
                                    existing_tickets.add(ticket)
                                    
                                if to_create:
                                    MT5Deal.objects.bulk_create(to_create, ignore_conflicts=True)
                                    ok_count += len(to_create)
                        except Exception as exc:
                            logger.warning("MT5 trading deal sync error for login %s: %s", acc.login_id, exc)
                            err_count += 1
            except Exception as exc:
                logger.error("MT5 connection failed during trading deal sync batch: %s", exc)
                return ok_count, qs.count()
    except Exception as exc:
        logger.error("MT5 connection failed during trading deal sync: %s", exc)
        return 0, qs.count()

    if ok_count > 0 or err_count > 0:
        logger.info("MT5 trading deal sync complete: %s new deals, %s errors", ok_count, err_count)
    return ok_count, err_count

