"""
CRM-facing helpers for BTrader (settings from TradingPlatformIntegration row).

Config fields (Integration → Trading Platforms → BTrader):
  - api_server_url  → gateway base URL (e.g. http://localhost:4100 or https://api.broker.com)
  - api_key         → X-BT-Key (keyId minted in BTrader Admin → CRM / Integrations)
  - secret_key      → HMAC secret (shown once when the key is minted)
  - server_name     → display label for opened accounts
  - extended_config.tenant_header → optional X-BT-Tenant (platform-scope keys only)
  - extended_config.webhook_secret → HMAC secret for BTrader → CRM outbound webhooks
"""
from __future__ import annotations

import logging
from decimal import Decimal, InvalidOperation
from typing import Any, Iterable, Optional

from django.db.models import Q
from django.utils import timezone

from .client import BTraderAPIError, BTraderClient

logger = logging.getLogger(__name__)


def _get_btrader_row():
    from admin_panel.models import TradingPlatformIntegration

    TradingPlatformIntegration.ensure_defaults()
    return TradingPlatformIntegration.objects.filter(
        platform=TradingPlatformIntegration.Platform.BTRADER,
    ).first()


def get_btrader_settings() -> dict[str, Any] | None:
    row = _get_btrader_row()
    if not row or not row.enabled:
        return None
    base = (row.api_server_url or "").strip()
    key_id = (row.api_key or "").strip()
    secret = (row.secret_key or "").strip()
    if not base or not key_id or not secret:
        return None
    ext = row.extended_config or {}
    return {
        "base_url": base,
        "key_id": key_id,
        "secret": secret,
        "server_name": (row.server_name or "").strip() or "BTrader",
        "tenant_header": str(ext.get("tenant_header") or "").strip(),
        "webhook_secret": str(ext.get("webhook_secret") or "").strip(),
    }


def get_webhook_secret() -> str:
    """Outbound webhook HMAC secret (BTrader → CRM). Falls back to inbound secret if unset."""
    row = _get_btrader_row()
    if not row:
        return ""
    ext = row.extended_config or {}
    wh = str(ext.get("webhook_secret") or "").strip()
    if wh:
        return wh
    # Convenient local-dev fallback: many brokers reuse one secret for both directions.
    return (row.secret_key or "").strip()


def is_btrader_configured() -> bool:
    return get_btrader_settings() is not None


def _client_from_settings(settings: dict[str, Any] | None = None) -> BTraderClient:
    cfg = settings or get_btrader_settings()
    if not cfg:
        raise BTraderAPIError("BTrader integration is not configured or disabled.")
    return BTraderClient(
        base_url=cfg["base_url"],
        key_id=cfg["key_id"],
        secret=cfg["secret"],
        tenant_header=cfg.get("tenant_header") or "",
    )


def test_btrader_connection(
    *,
    base_url: str = "",
    key_id: str = "",
    secret: str = "",
    tenant_header: str = "",
) -> tuple[bool, str]:
    """Test with posted form values, falling back to saved settings."""
    cfg = get_btrader_settings() or {}
    url = (base_url or cfg.get("base_url") or "").strip()
    kid = (key_id or cfg.get("key_id") or "").strip()
    sec = (secret or cfg.get("secret") or "").strip()
    th = (tenant_header or cfg.get("tenant_header") or "").strip()
    if not url:
        return False, "Missing gateway base URL (e.g. http://localhost:4100)."
    if not kid:
        return False, "Missing API Key ID (X-BT-Key / keyId from BTrader Admin)."
    if not sec:
        return False, "Missing HMAC secret (shown once when minting the CRM key)."
    client = BTraderClient(base_url=url, key_id=kid, secret=sec, tenant_header=th)
    return client.ping()


def list_btrader_engine_symbols() -> tuple[list[str], str]:
    """Enabled BTrader engine symbols the broker created (XAUUSD.s), not raw feed names."""
    if not is_btrader_configured():
        return [], "BTrader integration is not configured."
    try:
        client = _client_from_settings()
        rows = client.list_symbols()
        names: list[str] = []
        seen: set[str] = set()
        for row in rows:
            name = ""
            if isinstance(row, str):
                name = row.strip()
            elif isinstance(row, dict):
                name = str(row.get("symbol") or row.get("name") or "").strip()
            if not name:
                continue
            key = name.upper()
            if key in seen:
                continue
            seen.add(key)
            names.append(name)
        return names, ""
    except Exception as exc:
        logger.warning("BTrader engine symbol list failed: %s", exc)
        return [], str(exc)[:250]


def fetch_btrader_groups() -> tuple[bool, list[str]]:
    """Return (connected, group_names) for Group Management tree."""
    if not is_btrader_configured():
        return False, []
    try:
        client = _client_from_settings()
        rows = client.list_groups()
        names: list[str] = []
        for g in rows:
            if not isinstance(g, dict):
                continue
            name = (g.get("name") or "").strip()
            if name and g.get("enabled", True) is not False:
                names.append(name)
        return True, names
    except Exception as exc:
        logger.warning("BTrader group fetch failed: %s", exc)
        return False, []


def create_btrader_account(
    *,
    crm_user_id: str,
    crm_account_id: str,
    email: str,
    name: str,
    phone: str,
    password: str,
    group: str,
    currency: str,
    leverage: int,
    is_demo: bool,
    account_type: str = "STANDARD",
    investor_password: str = "",
) -> dict[str, str]:
    """
    POST /v1/crm/accounts — returns {accountId, login}.
    """
    client = _client_from_settings()
    payload = {
        "crmUserId": str(crm_user_id),
        "crmAccountId": str(crm_account_id),
        "email": email,
        "name": name or email,
        "phone": phone or "",
        "password": password,
        # #3B: read-only investor password. Sent only when distinct from the
        # main password, so btrader stores it as a separate read-only credential.
        **(
            {"investorPassword": investor_password}
            if investor_password and investor_password != password
            else {}
        ),
        "type": "DEMO" if is_demo else (account_type or "STANDARD"),
        "currency": currency or "USD",
        "leverage": int(leverage or 100),
        "isDemo": bool(is_demo),
    }
    group_name = (group or "").strip()
    if group_name:
        payload["group"] = group_name
    result = client.create_account(payload)
    login = str(result.get("login") or "").strip()
    account_id = str(result.get("accountId") or "").strip()
    if not login:
        raise BTraderAPIError("BTrader createAccount response missing login.")
    return {"login": login, "accountId": account_id}


def deposit_btrader_balance(
    *,
    login: str,
    amount: float,
    comment: str,
    external_ref: str,
) -> dict:
    client = _client_from_settings()
    result = client.balance_op(
        login,
        {
            "type": "DEPOSIT",
            "amount": float(amount),
            "comment": comment or "CRM deposit",
            "externalRef": external_ref,
        },
    )
    try:
        sync_account(str(login))
    except Exception as exc:
        logger.warning("BTrader post-deposit sync failed login=%s: %s", login, exc)
    return result


def withdraw_btrader_balance(
    *,
    login: str,
    amount: float,
    comment: str,
    external_ref: str,
) -> dict:
    client = _client_from_settings()
    result = client.balance_op(
        login,
        {
            "type": "WITHDRAWAL",
            "amount": float(amount),
            "comment": comment or "CRM withdrawal",
            "externalRef": external_ref,
        },
    )
    try:
        sync_account(str(login))
    except Exception as exc:
        logger.warning("BTrader post-withdraw sync failed login=%s: %s", login, exc)
    return result


def _dec(value: Any, default: str = "0") -> Decimal:
    try:
        if value is None or value == "":
            return Decimal(default)
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return Decimal(default)


def is_btrader_account_row(trading_account=None, mt5_account=None) -> bool:
    """Detect BTrader-backed CRM account (group platform or label/server heuristic)."""
    mt5 = mt5_account
    if trading_account is not None and mt5 is None:
        mt5 = getattr(trading_account, "mt5_account", None)
    if mt5 is not None:
        group = getattr(mt5, "group", None)
        if group is not None and str(getattr(group, "platform", "") or "").upper() == "BTRADER":
            return True
        server = str(getattr(mt5, "server", "") or "").lower()
        label = str(getattr(mt5, "account_label", "") or "").lower()
        if "btrader" in server or "btrader" in label:
            return True
    if trading_account is not None:
        blob = f"{getattr(trading_account, 'account_type', '')} {getattr(trading_account, 'server', '')}".lower()
        if "btrader" in blob:
            return True
    return False


def persist_account_snapshot(login: str, data: dict) -> bool:
    """
    Save live BTrader account snapshot into MT5Account + TradingAccount rows.
    Field mapping mirrors MT5 sync (balance/equity/free_margin/unrealized_pnl).
    """
    from accounts.models import MT5Account
    from admin_panel.models import TradingAccount

    login_s = str(login or "").strip()
    if not login_s or not isinstance(data, dict):
        return False

    balance = _dec(data.get("balance"))
    equity = _dec(data.get("equity"), str(balance))
    free_margin = _dec(
        data.get("freeMargin") if data.get("freeMargin") is not None else data.get("free_margin"),
        str(max(Decimal("0"), equity)),
    )
    pnl = _dec(
        data.get("floatingPL") if data.get("floatingPL") is not None else data.get("unrealized_pnl")
    )
    credit = _dec(data.get("credit"))
    now = timezone.now()

    updated = MT5Account.objects.filter(login_id=login_s).update(
        balance=balance,
        equity=equity,
        free_margin=free_margin,
        unrealized_pnl=pnl,
        credit=credit,
        last_sync_at=now,
    )
    TradingAccount.objects.filter(account_number=login_s).update(balance=balance, updated_at=now)
    if not updated:
        # Fallback: trading row may point at MT5Account with matching login via OneToOne.
        ta = (
            TradingAccount.objects.select_related("mt5_account")
            .filter(Q(account_number=login_s) | Q(mt5_account__login_id=login_s))
            .first()
        )
        if ta and ta.mt5_account:
            MT5Account.objects.filter(pk=ta.mt5_account_id).update(
                balance=balance,
                equity=equity,
                free_margin=free_margin,
                unrealized_pnl=pnl,
                credit=credit,
                last_sync_at=now,
            )
            TradingAccount.objects.filter(pk=ta.pk).update(balance=balance, updated_at=now)
            return True
        logger.debug("BTrader persist: no CRM account for login=%s", login_s)
        return False
    return True


def fetch_account(login: str) -> Optional[dict]:
    if not is_btrader_configured():
        return None
    client = _client_from_settings()
    data = client.get_account(str(login))
    return data if isinstance(data, dict) else None


def sync_account(login: str) -> Optional[dict]:
    """Fetch one BTrader login and persist balance/equity/freeMargin into CRM."""
    try:
        data = fetch_account(login)
    except Exception as exc:
        logger.warning("BTrader sync_account(%s) failed: %s", login, exc)
        return None
    if not data:
        return None
    persist_account_snapshot(str(login), data)
    return data


def sync_accounts(logins: Iterable[str]) -> tuple[int, int]:
    """Batch-sync many logins. Returns (ok, errors)."""
    uniq = [str(x).strip() for x in logins if str(x).strip()]
    if not uniq:
        return 0, 0
    if not is_btrader_configured():
        return 0, len(uniq)
    ok = err = 0
    try:
        client = _client_from_settings()
        # Prefer batch; fall back to per-login on failure.
        try:
            mapping = client.batch_accounts(uniq)
        except Exception as batch_exc:
            logger.warning("BTrader batch sync failed, falling back per-login: %s", batch_exc)
            mapping = {}
            for login in uniq:
                try:
                    info = client.get_account(login)
                    if isinstance(info, dict):
                        mapping[login] = info
                except Exception:
                    err += 1
        for login in uniq:
            info = mapping.get(login) or mapping.get(str(login))
            if isinstance(info, dict) and persist_account_snapshot(login, info):
                ok += 1
            else:
                # Already counted err for per-login failures above when mapping empty.
                if login not in mapping and str(login) not in mapping:
                    err += 1
    except Exception as exc:
        logger.error("BTrader sync_accounts failed: %s", exc)
        return ok, err + max(0, len(uniq) - ok)
    return ok, err


def btrader_logins_queryset():
    """Active CRM logins that belong to BTrader groups / labels."""
    from accounts.models import MT5Account

    return (
        MT5Account.objects.filter(status=MT5Account.Status.ACTIVE)
        .filter(
            Q(group__platform="BTRADER")
            | Q(server__icontains="btrader")
            | Q(account_label__icontains="btrader")
        )
        .values_list("login_id", flat=True)
    )


def sync_all_btrader_accounts() -> tuple[int, int]:
    logins = list(btrader_logins_queryset())
    if not logins:
        return 0, 0
    return sync_accounts(logins)


def sync_user_btrader_accounts(user) -> tuple[int, int]:
    """Live-pull all BTrader accounts for one CRM user (dashboard / transfer)."""
    from admin_panel.models import TradingAccount

    rows = (
        TradingAccount.objects.filter(user=user, status=TradingAccount.Status.ACTIVE)
        .select_related("mt5_account", "mt5_account__group")
    )
    logins = []
    for row in rows:
        if is_btrader_account_row(trading_account=row):
            login = (row.mt5_account.login_id if row.mt5_account else row.account_number) or ""
            if login:
                logins.append(str(login))
    return sync_accounts(logins)


def live_withdrawable(login: str) -> tuple[Optional[Decimal], Optional[dict], str]:
    """
    Fetch live freeMargin/equity/balance from BTrader.
    Returns (max_withdrawable, snapshot, error_message).
    Max = max(0, min(balance, freeMargin)) — credit is non-withdrawable and
    must not inflate cash-out capacity via freeMargin/equity.
    """
    try:
        data = fetch_account(login)
    except BTraderAPIError as exc:
        return None, None, f"Unable to read live trading balance: {exc}"
    except Exception as exc:
        return None, None, f"Unable to read live trading balance: {exc}"
    if not data:
        return None, None, "Trading account not found on BTrader."
    persist_account_snapshot(str(login), data)
    free_margin = _dec(
        data.get("freeMargin") if data.get("freeMargin") is not None else data.get("free_margin")
    )
    balance = _dec(data.get("balance"))
    equity = _dec(data.get("equity"), str(balance))
    # Prefer cash balance over equity so bonus/credit cannot be withdrawn.
    allowed = max(Decimal("0"), min(balance, free_margin, equity))
    return allowed, data, ""


def validate_trading_debit_amount(trading_account, amount: Decimal) -> Optional[str]:
    """
    Guard for Trading→Wallet / Trading→Trading / admin debit.
    BTrader: live freeMargin. MT5: synced free_margin/equity snapshot (refresh when possible).
    """
    amount = Decimal(str(amount or 0))
    if amount <= 0:
        return "Amount must be greater than zero."

    mt5 = getattr(trading_account, "mt5_account", None)
    if not mt5:
        return "Source trading account not found."

    login = str(mt5.login_id or trading_account.account_number or "").strip()

    if is_btrader_account_row(trading_account=trading_account, mt5_account=mt5):
        if not is_btrader_configured():
            return "BTrader integration is not configured."
        allowed, snapshot, err = live_withdrawable(login)
        if err:
            return err
        if allowed is None or amount > allowed:
            bal = _dec((snapshot or {}).get("balance"))
            eq = _dec((snapshot or {}).get("equity"), str(bal))
            fm = _dec((snapshot or {}).get("freeMargin"), str(allowed or 0))
            return (
                f"Insufficient free margin for this withdrawal/transfer. "
                f"Requested {amount}, available {allowed or Decimal('0')} "
                f"(balance {bal}, equity {eq}, free margin {fm}). "
                f"Close or reduce open positions, or request a smaller amount. "
                f"/ مارجن دستیاب نہیں — اوپن پوزیشنز کی وجہ سے زیادہ رقم نہیں نکل سکتی۔"
            )
        return None

    # MT5 path — mirror existing CRM rule; best-effort live refresh.
    try:
        from mt5_integration.services import is_mt5_configured, sync_account as mt5_sync

        if is_mt5_configured():
            mt5_sync(int(login))
            mt5.refresh_from_db()
    except Exception as exc:
        logger.debug("MT5 live refresh before debit skipped: %s", exc)

    free_margin = _dec(mt5.free_margin)
    equity = _dec(mt5.equity, str(_dec(mt5.balance)))
    allowed = max(Decimal("0"), min(free_margin, equity))
    if amount > allowed:
        return (
            f"Insufficient free margin for this withdrawal/transfer. "
            f"Requested {amount}, available {allowed} "
            f"(equity {equity}, free margin {free_margin}). "
            f"Close or reduce open positions, or request a smaller amount."
        )
    return None
