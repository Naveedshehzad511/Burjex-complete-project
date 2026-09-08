from __future__ import annotations

import logging
from decimal import Decimal

from django.db.models import Q
from django.utils.crypto import get_random_string
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.views import APIView

from accounts.models import MT5Account, MT5Group
from accounts.restrictions import restriction_for_user
from admin_panel.models import DemoAccountSettings, TradingAccount, TradingAccountType
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, not_found_response, success_response, validation_error_response
from api.views.dashboard import _serialize_trading_account
from user_portal.views import (
    PORTAL_OPEN_ACCOUNT_CURRENCIES,
    _btrader_client_open_enabled,
    _build_leverage_options_open_account,
    _count_mt5_same_kind,
    _demo_server_name,
    _ensure_mt5_group_for_match_trader,
    _match_trader_broker_group_for_account_type,
    _match_trader_client_open_enabled,
    _open_account_type_payload,
    _open_account_type_supports_btrader,
    _open_account_type_supports_match_trader,
    _open_account_type_supports_mt5,
    _resolve_btrader_group,
    _resolve_demo_mt5_group,
    _resolve_real_mt5_group,
)

logger = logging.getLogger(__name__)


def _open_account_types_queryset():
    account_type_field_names = {f.name for f in TradingAccountType._meta.get_fields()}
    qs = TradingAccountType.objects.select_related(
        "crm_group",
        "crm_group__match_trader_broker_group",
        "demo_group",
    ).all()
    if "status" in account_type_field_names:
        qs = qs.filter(status=True)
    elif "is_active" in account_type_field_names:
        qs = qs.filter(is_active=True)
    return qs.order_by("display_order", "account_name")


def _filtered_open_account_types():
    raw_types = list(_open_account_types_queryset())
    account_types = [
        t
        for t in raw_types
        if (
            _open_account_type_supports_mt5(t)
            or _open_account_type_supports_match_trader(t)
            or _open_account_type_supports_btrader(t)
        )
    ]
    demo_types_exist = any(getattr(t, "demo_enabled", False) for t in raw_types)
    return account_types, demo_types_exist


def _open_account_options_payload(request, *, kind: str | None = None) -> dict:
    account_types, demo_types_exist = _filtered_open_account_types()
    demo_settings = DemoAccountSettings.get_solo()
    initial_kind = (kind or request.query_params.get("kind") or "real").strip().lower()
    if initial_kind not in {"demo", "real"}:
        initial_kind = "real"
    is_demo_flow = initial_kind == "demo"
    account_types_payload = [
        _open_account_type_payload(t, demo_types_exist=demo_types_exist, is_demo_flow=is_demo_flow)
        for t in account_types
    ]
    my_accounts = TradingAccount.objects.filter(user=request.user).order_by("-created_at")[:20]
    return {
        "account_types": account_types_payload,
        "match_trader_enabled": _match_trader_client_open_enabled(),
        "btrader_enabled": _btrader_client_open_enabled(),
        "portal_currencies": sorted(PORTAL_OPEN_ACCOUNT_CURRENCIES),
        "my_accounts": [_serialize_trading_account(a) for a in my_accounts],
        "demo_settings": {
            "default_balance": str(demo_settings.default_balance or 10000),
        },
        "demo_types_exist": demo_types_exist,
        "initial_kind": initial_kind,
    }


class TradingAccountListAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        qs = (
            TradingAccount.objects.filter(user=request.user)
            .select_related("mt5_account", "mt5_account__group")
            .order_by("-created_at")
        )
        return success_response(
            {"accounts": [_serialize_trading_account(a) for a in qs]},
            message="Trading accounts retrieved successfully.",
        )


class TradingAccountTypesAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        return success_response(
            _open_account_options_payload(request),
            message="Account types retrieved successfully.",
        )


class TradingAccountDetailAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request, account_id: str):
        account = (
            TradingAccount.objects.filter(user=request.user)
            .filter(Q(account_number=account_id) | Q(mt5_account__login_id=account_id))
            .select_related("mt5_account", "mt5_account__group")
            .first()
        )
        if not account:
            return not_found_response("Trading account not found.")
        mt5 = account.mt5_account
        margin = Decimal("0")
        if mt5:
            margin = Decimal(str(mt5.equity or 0)) - Decimal(str(mt5.free_margin or 0))
        data = _serialize_trading_account(account)
        data["margin_used"] = str(margin)
        if mt5:
            data["login_id"] = mt5.login_id
            data["account_label"] = mt5.account_label
            data["deposit_enabled"] = mt5.deposit_enabled
            data["withdraw_enabled"] = mt5.withdraw_enabled
            data["trading_enabled"] = mt5.trading_enabled
        return success_response(data, message="Trading account retrieved successfully.")


class OpenAccountAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]
    parser_classes = [JSONParser, FormParser, MultiPartParser]

    def get(self, request):
        r = restriction_for_user(request.user)
        if r and r.disable_create_mt5:
            return error_response(
                "Creating new trading accounts is disabled for your account. Please contact support.",
                status=403,
            )
        return success_response(
            _open_account_options_payload(request),
            message="Open account options retrieved successfully.",
        )

    def post(self, request):
        r = restriction_for_user(request.user)
        if r and r.disable_create_mt5:
            return error_response(
                "Creating new trading accounts is disabled for your account. Please contact support.",
                status=403,
            )

        data = request.data
        account_types_qs = _open_account_types_queryset()
        demo_settings = DemoAccountSettings.get_solo()

        kind = (data.get("account_kind") or "").strip().lower()
        if not kind:
            # Mobile may send is_demo instead of account_kind.
            raw_demo = data.get("is_demo")
            if raw_demo in (True, "true", "1", 1, "yes"):
                kind = "demo"
            else:
                kind = "real"
        is_demo = kind == "demo"
        account_type_id = data.get("account_type")
        currency = (data.get("currency") or "USD").strip().upper()
        leverage = data.get("leverage") or "100"
        main_password = (data.get("main_password") or "").strip()
        investor_password = (data.get("investor_password") or "").strip()
        account_type = account_types_qs.filter(id=account_type_id).first()
        if not account_type:
            return error_response("Selected account type is not available.")
        if not (
            _open_account_type_supports_mt5(account_type)
            or _open_account_type_supports_match_trader(account_type)
            or _open_account_type_supports_btrader(account_type)
        ):
            return error_response("Selected account type is not available.")

        trading_platform = (data.get("trading_platform") or "").strip().upper()
        if trading_platform not in ("MT5", "MATCH_TRADER", "BTRADER"):
            # Infer when mobile omits trading_platform.
            if _open_account_type_supports_btrader(account_type):
                trading_platform = "BTRADER"
            elif _open_account_type_supports_match_trader(account_type):
                trading_platform = "MATCH_TRADER"
            else:
                trading_platform = "MT5"

        if currency not in PORTAL_OPEN_ACCOUNT_CURRENCIES:
            return error_response("Please choose a valid account currency.")

        if trading_platform == "MATCH_TRADER" and not _open_account_type_supports_match_trader(account_type):
            return error_response("Match-Trader is not available for this account type.")
        if trading_platform == "BTRADER" and not _open_account_type_supports_btrader(account_type):
            return error_response("BTrader is not available for this account type.")
        if trading_platform == "MT5" and not _open_account_type_supports_mt5(account_type):
            return error_response("MT5 is not available for this account type.")

        if is_demo:
            cat = getattr(account_type, "account_category", "LIVE")
            demo_sel = (cat == "DEMO") or (cat == "LIVE" and getattr(account_type, "demo_enabled", False))
            if not demo_sel:
                return error_response("This account type is not enabled for demo accounts.")
            min_demo = Decimal(str(getattr(account_type, "min_demo_balance", "100.00")))
            max_demo = Decimal(str(getattr(account_type, "max_demo_balance", "100000.00")))
            try:
                opening_bal = Decimal(str(data.get("initial_demo_balance") or "").strip() or "10000")
            except Exception:
                opening_bal = Decimal("10000")
            if opening_bal < min_demo or opening_bal > max_demo:
                return error_response(f"Demo balance must be between {min_demo} and {max_demo}.")
            mt5_mode = MT5Account.AccountType.DEMO
            dep_ok = False
            wdr_ok = False
        else:
            mt5_mode = MT5Account.AccountType.LIVE
            opening_bal = Decimal("0")
            dep_ok = True
            wdr_ok = True

        try:
            leverage_val = int(leverage)
        except Exception:
            leverage_val = 100
        allowed_leverage_options = _build_leverage_options_open_account(
            getattr(account_type, "max_leverage", 100),
            getattr(account_type, "leverage_options", None),
        )
        if leverage_val not in allowed_leverage_options:
            leverage_val = allowed_leverage_options[0]

        # Auto-generate passwords when the client (e.g. mobile) omits them.
        if len(main_password) < 8:
            main_password = get_random_string(12, allowed_chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        if len(investor_password) < 8:
            # #3B: BTRADER now honours a distinct investor password as a read-only
            # login, so it no longer copies the main password — every platform
            # gets its own random investor password when the client omits one.
            investor_password = get_random_string(
                12, allowed_chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            )

        max_n = (account_type.max_demo_accounts if is_demo else account_type.max_live_accounts) or 0
        if max_n > 0:
            cur = _count_mt5_same_kind(request.user, account_type, live=not is_demo)
            if cur >= max_n:
                kind_label = "demo" if is_demo else "live"
                return error_response(
                    f"You have reached the maximum number of {kind_label} accounts for this type."
                )

        if is_demo:
            default_bal = Decimal(str(demo_settings.default_balance or 10000))
            mode = (data.get("demo_balance_preset") or "default").strip().lower()
            custom_raw = (data.get("demo_balance_custom") or "").strip()
            presets = {
                "10000": Decimal("10000"),
                "50000": Decimal("50000"),
                "100000": Decimal("100000"),
                "default": default_bal,
            }
            if mode == "custom" and custom_raw:
                try:
                    opening_bal = Decimal(custom_raw)
                except Exception:
                    opening_bal = default_bal
            else:
                opening_bal = presets.get(mode, default_bal)
            if opening_bal < Decimal("100"):
                opening_bal = Decimal("100")
            if opening_bal > Decimal("10000000"):
                opening_bal = Decimal("10000000")
            mt5_mode = MT5Account.AccountType.DEMO
            dep_ok = False
            wdr_ok = False
            if trading_platform == "MATCH_TRADER":
                brg = _match_trader_broker_group_for_account_type(account_type)
                if not brg:
                    return error_response(
                        "Match-Trader is not mapped for this account type's CRM group. Configure it in Admin → Group Management."
                    )
                group = _ensure_mt5_group_for_match_trader(brg)
                if not group:
                    return error_response("Could not prepare Match-Trader group mapping.")
                server_name = f"Match-Trader Demo — {brg.name}"
                account_label = f"Demo (Match-Trader) — {account_type.account_name}"
            elif trading_platform == "BTRADER":
                group = _resolve_btrader_group(account_type, is_demo=True, demo_settings=demo_settings)
                if not group:
                    return error_response(
                        "BTrader is not mapped for this account type's CRM group. Configure it in Admin → Group Management."
                    )
                from btrader_integration.services import get_btrader_settings
                bt_cfg = get_btrader_settings() or {}
                server_name = f"{bt_cfg.get('server_name') or 'BTrader'} Demo"
                account_label = f"Demo (BTrader) — {account_type.account_name}"
            else:
                group = _resolve_demo_mt5_group(account_type, demo_settings)
                if not group:
                    return error_response("No MT5 group is configured for demo accounts. Please contact support.")
                server_name = _demo_server_name()
                account_label = f"Demo — {account_type.account_name}"
        else:
            mt5_mode = MT5Account.AccountType.LIVE
            opening_bal = Decimal("0")
            dep_ok = True
            wdr_ok = True
            if trading_platform == "MATCH_TRADER":
                brg = _match_trader_broker_group_for_account_type(account_type)
                if not brg:
                    return error_response(
                        "Match-Trader is not mapped for this account type's CRM group. Configure it in Admin → Group Management."
                    )
                group = _ensure_mt5_group_for_match_trader(brg)
                if not group:
                    return error_response("Could not prepare Match-Trader group mapping.")
                server_name = f"Match-Trader — {brg.name}"
                account_label = f"Real (Match-Trader) — {account_type.account_name}"
            elif trading_platform == "BTRADER":
                group = _resolve_btrader_group(account_type, is_demo=False)
                if not group:
                    return error_response(
                        "BTrader is not mapped for this account type's CRM group. Configure it in Admin → Group Management."
                    )
                from btrader_integration.services import get_btrader_settings
                bt_cfg = get_btrader_settings() or {}
                server_name = (account_type.server_name or "").strip() or (bt_cfg.get("server_name") or "BTrader")
                account_label = f"Real (BTrader) — {account_type.account_name}"
            else:
                group = _resolve_real_mt5_group(account_type)
                if not group:
                    code = (account_type.account_code or "GRP").lower().replace(" ", "-")
                    group = MT5Group.objects.create(
                        crm_group_name=account_type.account_name,
                        platform=MT5Group.BrokerPlatform.MT5,
                        platform_group_name=f"{code}-default",
                        name=f"{code}-default",
                        is_active=True,
                        description="Auto-created fallback group (link a CRM group in Account Types).",
                    )
                    account_type.crm_group = group
                    account_type.save(update_fields=["crm_group", "updated_at"])
                server_name = (account_type.server_name or "").strip() or f"{account_type.platform}-Live"
                account_label = f"Real — {account_type.account_name}"

        def _unique_digits(length=8):
            while True:
                candidate = get_random_string(length, allowed_chars="0123456789")
                if not MT5Account.objects.filter(login_id=candidate).exists():
                    return candidate

        account_number = _unique_digits(8)
        mt5_login_str = account_number

        if trading_platform == "MT5":
            from mt5_integration.services import _mt5_client, is_mt5_configured

            if is_mt5_configured():
                try:
                    with _mt5_client() as client:
                        group_str = getattr(group, "platform_group_name", "") or getattr(group, "name", "")
                        full_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
                        country_val = getattr(request.user, "country", "")
                        phone_val = getattr(request.user, "phone", "")
                        new_mt5_login = client.user_add(
                            group=group_str,
                            name=full_name,
                            password=main_password,
                            investor_password=investor_password or main_password,
                            leverage=leverage_val,
                            email=request.user.email,
                            country=country_val,
                            phone=phone_val,
                        )
                        mt5_login_str = str(new_mt5_login)
                        if is_demo and opening_bal > 0:
                            try:
                                client.user_deposit_change(
                                    new_mt5_login, float(opening_bal), "Initial Deposit", deal_type=2
                                )
                            except Exception as dep_err:
                                logger.error("Failed to deposit demo balance to MT5: %s", dep_err)
                except Exception as e:
                    logger.error("Failed to create MT5 account via API: %s", e)
                    err_str = str(e)
                    if "retcode 3006" in err_str:
                        return error_response(
                            "Failed: Password does not meet MT5 security requirements (must contain uppercase, lowercase, and numbers)."
                        )
                    if "retcode 8" in err_str:
                        return error_response("Failed: Group not found on MT5 server. Please contact support.")
                    return error_response("Failed to create MT5 account on server. Please try again or contact support.")
            else:
                return error_response("MT5 Integration is not configured. Cannot create MT5 account.")
        elif trading_platform == "BTRADER":
            from btrader_integration.client import BTraderAPIError
            from btrader_integration.services import (
                create_btrader_account,
                deposit_btrader_balance,
                is_btrader_configured,
            )

            if not is_btrader_configured():
                return error_response("BTrader integration is not configured. Cannot create trading account.")
            try:
                group_str = getattr(group, "platform_group_name", "") or getattr(group, "name", "")
                full_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
                phone_val = getattr(request.user, "phone", "") or ""
                provisional_id = f"crm-{request.user.id}-{account_number}"
                created = create_btrader_account(
                    crm_user_id=str(request.user.id),
                    crm_account_id=provisional_id,
                    email=request.user.email or f"user{request.user.id}@crm.local",
                    name=full_name,
                    phone=phone_val,
                    password=main_password,
                    investor_password=investor_password,
                    group=group_str,
                    currency=currency,
                    leverage=leverage_val,
                    is_demo=is_demo,
                )
                mt5_login_str = created["login"]
                if is_demo and opening_bal > 0:
                    try:
                        deposit_btrader_balance(
                            login=mt5_login_str,
                            amount=float(opening_bal),
                            comment="Initial demo deposit",
                            external_ref=f"crm-demo-{mt5_login_str}-{provisional_id}",
                        )
                    except Exception as dep_err:
                        logger.error("Failed to deposit demo balance to BTrader: %s", dep_err)
            except BTraderAPIError as e:
                logger.error("Failed to create BTrader account: %s", e)
                return error_response(f"Failed to create BTrader account: {e}")
            except Exception as e:
                logger.error("Failed to create BTrader account: %s", e)
                return error_response("Failed to create BTrader account on server. Please try again or contact support.")

        account_number = mt5_login_str
        mt5 = MT5Account(
            user=request.user,
            account_type=mt5_mode,
            login_id=account_number,
            server=server_name,
            group=group,
            leverage=leverage_val,
            account_label=account_label,
            balance=opening_bal,
            equity=opening_bal,
            free_margin=opening_bal,
            deposit_enabled=dep_ok,
            withdraw_enabled=wdr_ok,
        )
        mt5.set_mt5_password(main_password)
        mt5.set_investor_password(investor_password)
        mt5.save()

        trading = TradingAccount.objects.create(
            user=request.user,
            account_number=account_number,
            account_type=account_label,
            leverage=leverage_val,
            currency=currency,
            status=TradingAccount.Status.ACTIVE,
            server=server_name,
            balance=opening_bal,
            mt5_account=mt5,
        )

        message = (
            f"{account_label} created with virtual balance {opening_bal} {currency}."
            if is_demo
            else "Trading account created successfully."
        )
        platform_label = (
            "BTrader"
            if trading_platform == "BTRADER"
            else ("Match-Trader" if trading_platform == "MATCH_TRADER" else "MT5")
        )
        return success_response(
            {
                "account": _serialize_trading_account(trading),
                "credentials": {
                    "account_number": account_number,
                    "login_id": account_number,
                    "main_password": main_password,
                    "investor_password": investor_password,
                    "server": server_name,
                    "leverage": leverage_val,
                    "platform": platform_label,
                },
            },
            message=message,
            status=201,
        )


class AccountPositionsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        from mt5_integration.services import is_mt5_configured

        if not is_mt5_configured():
            return success_response(
                {"positions": [], "mt5_unavailable": True},
                message="Open positions retrieved successfully.",
            )

        accounts = MT5Account.objects.filter(user=request.user, status=MT5Account.Status.ACTIVE)
        positions = []
        try:
            from mt5_integration.services import _mt5_client

            with _mt5_client() as client:
                for acc in accounts:
                    try:
                        total = client.position_get_total(int(acc.login_id))
                        if total > 0:
                            raw_pos = client.position_get_page(int(acc.login_id), 0, total)
                            for p in raw_pos:
                                vol = float(p.get("Volume") or 0) / 10000.0
                                action = "Buy" if str(p.get("Action") or "0") == "0" else "Sell"
                                positions.append(
                                    {
                                        "login_id": acc.login_id,
                                        "symbol": p.get("Symbol") or "-",
                                        "type": action,
                                        "volume": f"{vol:.2f}",
                                        "price_open": f"{float(p.get('PriceOpen') or 0):.5f}",
                                        "price_current": f"{float(p.get('PriceCurrent') or 0):.5f}",
                                        "profit": float(p.get("Profit") or 0),
                                    }
                                )
                    except Exception as ex:
                        logger.warning("Failed to fetch positions for %s: %s", acc.login_id, ex)
        except Exception as e:
            logger.warning("AccountPositionsAPIView: MT5 unavailable: %s", e)
            return success_response(
                {"positions": [], "mt5_unavailable": True},
                message="Open positions retrieved successfully.",
            )

        positions.sort(key=lambda x: x["profit"], reverse=True)
        for p in positions:
            p["profit"] = f"{p['profit']:.2f}"

        return success_response(
            {"positions": positions, "mt5_unavailable": False},
            message="Open positions retrieved successfully.",
        )
