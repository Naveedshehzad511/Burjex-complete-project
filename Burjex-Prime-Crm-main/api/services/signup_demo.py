"""Auto-provision a BTrader DEMO trading account for newly registered clients.

Used on signup (and as a short first-login fallback) so Quotes has symbols
immediately after registration without leaving the user on a Create Account CTA.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from decimal import Decimal
from typing import Any

from django.db import transaction
from django.utils import timezone
from django.utils.crypto import get_random_string

logger = logging.getLogger(__name__)

# First-login safety net only for very new clients (covers email-verify delay /
# signup provision race). Existing clients with zero accounts keep the CTA.
_FIRST_LOGIN_DEMO_WINDOW = timedelta(hours=48)


def _user_has_trading_account(user) -> bool:
    from accounts.models import MT5Account
    from admin_panel.models import TradingAccount

    if MT5Account.objects.filter(user=user).exists():
        return True
    if TradingAccount.objects.filter(user=user).exists():
        return True
    return False


def _pick_demo_account_type(demo_cfg):
    """Prefer admin default, else first active BTrader type that allows demo."""
    from admin_panel.models import TradingAccountType
    from user_portal.views import (
        _open_account_type_supports_btrader,
        _resolve_btrader_group,
    )

    def _demo_capable(t) -> bool:
        if not t or not getattr(t, "is_active", False):
            return False
        if not _open_account_type_supports_btrader(t):
            return False
        cat = getattr(t, "account_category", "LIVE")
        demo_ok = (cat == "DEMO") or (cat == "LIVE" and getattr(t, "demo_enabled", False))
        if not demo_ok:
            return False
        return bool(_resolve_btrader_group(t, is_demo=True, demo_settings=demo_cfg))

    preferred = getattr(demo_cfg, "default_account_type", None)
    if _demo_capable(preferred):
        return preferred

    qs = (
        TradingAccountType.objects.filter(is_active=True)
        .select_related("crm_group", "demo_group")
        .order_by("id")
    )
    for t in qs:
        if getattr(t, "account_category", "LIVE") == "DEMO" and _demo_capable(t):
            return t
    for t in qs:
        if _demo_capable(t):
            return t
    return None


def provision_signup_demo_account(user) -> dict[str, Any] | None:
    """
    Create one BTrader DEMO account for ``user`` if they have none yet.

    Returns credentials dict on success, None if skipped/failed.
    Never raises — signup/login must not fail because of demo provision.
    """
    try:
        if user is None or not getattr(user, "pk", None):
            return None
        if _user_has_trading_account(user):
            return None

        from accounts.models import MT5Account
        from admin_panel.models import DemoAccountSettings, TradingAccount
        from btrader_integration.client import BTraderAPIError
        from btrader_integration.services import (
            create_btrader_account,
            deposit_btrader_balance,
            get_btrader_settings,
            is_btrader_configured,
        )
        from user_portal.views import (
            _build_leverage_options_open_account,
            _resolve_btrader_group,
        )

        if not is_btrader_configured():
            logger.warning(
                "signup_demo skipped: BTrader not configured user_id=%s", user.pk
            )
            return None

        demo_cfg = DemoAccountSettings.get_solo()
        if not getattr(demo_cfg, "auto_create_on_signup", False):
            logger.info(
                "signup_demo skipped: auto_create_on_signup disabled user_id=%s",
                user.pk,
            )
            return None

        account_type = _pick_demo_account_type(demo_cfg)
        if account_type is None:
            logger.warning(
                "signup_demo skipped: no BTrader demo-capable account type user_id=%s",
                user.pk,
            )
            return None

        group = _resolve_btrader_group(account_type, is_demo=True, demo_settings=demo_cfg)
        if group is None:
            logger.warning(
                "signup_demo skipped: no BTrader demo group for type=%s user_id=%s",
                account_type.pk,
                user.pk,
            )
            return None

        currency = (getattr(account_type, "currency", None) or "USD").strip().upper() or "USD"
        leverage_opts = _build_leverage_options_open_account(
            getattr(account_type, "max_leverage", 100),
            getattr(account_type, "leverage_options", None),
        )
        leverage_val = int(demo_cfg.default_leverage or 100)
        if leverage_val not in leverage_opts:
            leverage_val = leverage_opts[0] if leverage_opts else 100

        opening_bal = Decimal(str(demo_cfg.default_balance or 10000))
        if opening_bal < Decimal("100"):
            opening_bal = Decimal("10000")

        main_password = get_random_string(
            12,
            allowed_chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        )
        investor_password = main_password

        provisional = get_random_string(8, allowed_chars="0123456789")
        group_str = getattr(group, "platform_group_name", "") or getattr(group, "name", "")
        full_name = f"{user.first_name} {user.last_name}".strip() or user.username
        phone_val = getattr(user, "phone", "") or ""
        provisional_id = f"crm-{user.id}-signup-{provisional}"

        try:
            created = create_btrader_account(
                crm_user_id=str(user.id),
                crm_account_id=provisional_id,
                email=user.email or f"user{user.id}@crm.local",
                name=full_name,
                phone=phone_val,
                password=main_password,
                group=group_str,
                currency=currency,
                leverage=leverage_val,
                is_demo=True,
            )
        except BTraderAPIError as exc:
            logger.error("signup_demo BTrader create failed user_id=%s: %s", user.pk, exc)
            return None
        except Exception:
            logger.exception("signup_demo BTrader create failed user_id=%s", user.pk)
            return None

        login_id = created["login"]
        if opening_bal > 0:
            try:
                deposit_btrader_balance(
                    login=login_id,
                    amount=float(opening_bal),
                    comment="Signup auto demo deposit",
                    external_ref=f"crm-signup-demo-{login_id}-{provisional_id}",
                )
            except Exception as dep_err:
                logger.error(
                    "signup_demo deposit failed login=%s user_id=%s: %s",
                    login_id,
                    user.pk,
                    dep_err,
                )

        bt_cfg = get_btrader_settings() or {}
        server_name = f"{bt_cfg.get('server_name') or 'BTrader'} Demo"
        type_name = (account_type.account_name or "Standard").strip()
        account_label = f"Demo — {type_name}"

        with transaction.atomic():
            if _user_has_trading_account(user):
                logger.info(
                    "signup_demo aborted after create: user already has account user_id=%s login=%s",
                    user.pk,
                    login_id,
                )
                return None

            mt5 = MT5Account(
                user=user,
                account_type=MT5Account.AccountType.DEMO,
                login_id=login_id,
                server=server_name,
                group=group,
                leverage=leverage_val,
                account_label=account_label,
                balance=opening_bal,
                equity=opening_bal,
                free_margin=opening_bal,
                deposit_enabled=False,
                withdraw_enabled=False,
            )
            mt5.set_mt5_password(main_password)
            mt5.set_investor_password(investor_password)
            mt5.save()

            TradingAccount.objects.create(
                user=user,
                account_number=login_id,
                account_type=account_label,
                leverage=leverage_val,
                currency=currency,
                status=TradingAccount.Status.ACTIVE,
                server=server_name,
                balance=opening_bal,
                mt5_account=mt5,
            )

        try:
            from admin_panel.templated_mail import send_event_email

            send_event_email(
                "demo_account_created",
                to_email=user.email,
                user=user,
                extra_context={"account_number": login_id},
            )
        except Exception:
            logger.exception("signup_demo email failed user_id=%s", user.pk)

        logger.info(
            "signup_demo created user_id=%s login=%s type=%s (%s)",
            user.pk,
            login_id,
            account_type.pk,
            type_name,
        )
        return {
            "login_id": login_id,
            "password": main_password,
            "platform": "BTRADER",
            "account_kind": "demo",
            "account_type_id": account_type.pk,
            "account_type_name": type_name,
            "leverage": leverage_val,
            "balance": str(opening_bal),
            "currency": currency,
            "auto_provisioned": True,
        }
    except Exception:
        logger.exception("signup_demo unexpected failure user_id=%s", getattr(user, "pk", None))
        return None


def ensure_signup_demo_for_new_client(user, *, force: bool = False) -> dict[str, Any] | None:
    """
    Provision demo on signup (force=True) or within the first-login window
    when the client still has zero trading accounts.
    """
    if user is None:
        return None
    if force:
        return provision_signup_demo_account(user)
    if _user_has_trading_account(user):
        return None
    joined = getattr(user, "date_joined", None)
    if joined is None:
        return None
    if timezone.now() - joined > _FIRST_LOGIN_DEMO_WINDOW:
        return None
    return provision_signup_demo_account(user)
