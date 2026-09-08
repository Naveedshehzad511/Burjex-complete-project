"""
Match2Pay v2 REST client — create a crypto deposit and parse the address.

Official endpoint: POST https://wallet.match2pay.com/api/v2/payment/deposit
Signature: sorted keys, Java-map serialisation of ``customer``, amount with
trailing zeros stripped, SHA-384 of (concatenated values + api_secret).
"""

from __future__ import annotations

import hashlib
import json
import logging
import ssl
import time
from decimal import Decimal
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

logger = logging.getLogger(__name__)

ALLOWED_NETWORKS = frozenset({"TRC20", "ERC20", "BEP20", "BTC", "ETH", "USDT"})
NETWORK_DISPLAY_ORDER = ("TRC20", "ERC20", "BEP20")

# Client network → Match2Pay (paymentCurrency, paymentGatewayName)
NETWORK_GATEWAY = {
    "TRC20": ("USX", "USDT TRC20"),
    "USDT": ("USX", "USDT TRC20"),
    "ERC20": ("UST", "USDT ERC20"),
    "BEP20": ("USB", "USDT BEP20"),
    "BSC": ("USB", "USDT BEP20"),
    "BTC": ("BTC", "BTC"),
    "ETH": ("ETH", "ETH"),
}

_CUSTOMER_ORDER = [
    "firstName",
    "lastName",
    "address",
    "contactInformation",
    "locale",
    "dateOfBirth",
    "tradingAccountLogin",
    "tradingAccountUuid",
]
_ADDRESS_ORDER = ["address", "city", "country", "zipCode", "state"]
_CONTACT_ORDER = ["email", "phoneNumber"]

PROD_BASE = "https://wallet.match2pay.com"
DEPOSIT_PATH = "/api/v2/payment/deposit"


def network_gateway(network: str) -> tuple[str, str]:
    key = (network or "TRC20").strip().upper()
    return NETWORK_GATEWAY.get(key, ("USX", "USDT TRC20"))


def crypto_method_label(network: str) -> str:
    labels = {
        "TRC20": "USDT TRC20",
        "ERC20": "USDT ERC20",
        "BEP20": "USDT BEP20",
        "BSC": "USDT BEP20",
        "USDT": "USDT TRC20",
        "BTC": "Bitcoin",
        "ETH": "Ethereum",
    }
    n = (network or "").upper()
    return labels.get(n, n)


def _unwrap_payload(data: Any) -> dict:
    if not isinstance(data, dict):
        return {}
    for key in ("data", "result", "payload"):
        inner = data.get(key)
        if isinstance(inner, dict):
            return inner
        if isinstance(inner, list) and inner and isinstance(inner[0], dict):
            return inner[0]
    return data


def extract_create_response(data: dict) -> dict[str, str]:
    out: dict[str, str] = {"payment_id": "", "address": "", "qr_code_data": "", "checkout_url": ""}
    node = _unwrap_payload(data)
    if not isinstance(node, dict):
        node = data if isinstance(data, dict) else {}

    for k in (
        "paymentId",
        "payment_id",
        "id",
        "reference",
        "invoice_id",
        "invoiceId",
        "deposit_id",
        "depositId",
    ):
        v = node.get(k)
        if v is not None and str(v).strip():
            out["payment_id"] = str(v).strip()
            break

    for k in (
        "address",
        "depositAddress",
        "deposit_address",
        "wallet_address",
        "crypto_address",
        "payin_address",
    ):
        v = node.get(k)
        if v is not None and str(v).strip():
            out["address"] = str(v).strip()
            break

    for k in ("qr_code", "qrCode", "qr", "qrcode", "qr_url", "qrCodeUrl", "image"):
        v = node.get(k)
        if v is not None and str(v).strip():
            out["qr_code_data"] = str(v).strip()
            break

    for k in (
        "checkoutUrl",
        "checkout_url",
        "payment_url",
        "paymentUrl",
        "redirect_url",
        "redirectUrl",
        "cashier_url",
        "cashierUrl",
        "url",
    ):
        v = node.get(k)
        if v is not None and str(v).strip().lower().startswith(("http://", "https://")):
            out["checkout_url"] = str(v).strip()
            break

    return out


def _normalise_amount(value) -> str:
    d = Decimal(str(value))
    text = format(d.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def _serialise_map(d: dict, order) -> str:
    parts = []
    for key in order:
        if key not in d or d[key] is None:
            continue
        val = d[key]
        if key == "address" and isinstance(val, dict):
            parts.append(f"{key}={_serialise_map(val, _ADDRESS_ORDER)}")
        elif key == "contactInformation" and isinstance(val, dict):
            parts.append(f"{key}={_serialise_map(val, _CONTACT_ORDER)}")
        else:
            parts.append(f"{key}={val}")
    return "{" + ", ".join(parts) + "}"


def sign_request(body: dict, api_secret: str) -> str:
    parts = []
    for key in sorted(k for k in body if k != "signature"):
        value = body[key]
        if key == "customer" and isinstance(value, dict):
            parts.append(_serialise_map(value, _CUSTOMER_ORDER))
        elif key == "amount":
            parts.append(_normalise_amount(value))
        else:
            parts.append(str(value))
    raw = "".join(parts) + (api_secret or "")
    return hashlib.sha384(raw.encode("utf-8")).hexdigest()


def _wallet_base(api_url: str) -> str:
    raw = (api_url or "").strip().rstrip("/")
    if not raw:
        return PROD_BASE
    lower = raw.lower()
    for suffix in (
        "/api/v2/deposit/crypto_agent",
        "/api/v2/payment/deposit",
        "/api/v1/crypto-deposit",
    ):
        if lower.endswith(suffix):
            return raw[: -len(suffix)]
    if lower.endswith("/api"):
        return raw[: -len("/api")]
    return raw


def _build_create_url(api_url: str, currencies_config: dict) -> str:
    cfg = currencies_config if isinstance(currencies_config, dict) else {}
    override = (cfg.get("deposit_create_url") or "").strip()
    if override.lower().startswith(("http://", "https://")):
        return override
    path = (cfg.get("deposit_create_path") or DEPOSIT_PATH).strip()
    if not path.startswith("/"):
        path = "/" + path
    # Always prefer the official v2 deposit path unless an explicit full URL is set.
    if path in {"/api/v2/deposit/crypto_agent", "/api/v1/crypto-deposit"}:
        path = DEPOSIT_PATH
    return f"{_wallet_base(api_url)}{path}"


def _build_customer_payload(user, trading_account_login: str = "") -> dict:
    address_payload = {}
    for src, dest in (
        ("address", "address"),
        ("city", "city"),
        ("country", "country"),
        ("postal_code", "zipCode"),
        ("zip_code", "zipCode"),
        ("state", "state"),
    ):
        val = (getattr(user, src, "") or "").strip()
        if val and dest not in address_payload:
            address_payload[dest] = val

    contact_info = {}
    email = (getattr(user, "email", "") or "").strip()
    if email:
        contact_info["email"] = email
    phone = (getattr(user, "phone", "") or "").strip()
    if phone:
        contact_info["phoneNumber"] = phone

    customer: dict[str, Any] = {}
    first_name = (getattr(user, "first_name", "") or "").strip() or "Client"
    last_name = (getattr(user, "last_name", "") or "").strip() or "User"
    customer["firstName"] = first_name[:80]
    customer["lastName"] = last_name[:80]
    if address_payload:
        customer["address"] = address_payload
    if contact_info:
        customer["contactInformation"] = contact_info
    locale = (getattr(user, "language_code", "") or "").strip() or "en_US"
    customer["locale"] = locale
    dob = getattr(user, "date_of_birth", None)
    if dob:
        customer["dateOfBirth"] = str(dob)
    username = (trading_account_login or getattr(user, "username", "") or "").strip()
    if username:
        customer["tradingAccountLogin"] = username[:120]
    user_id = str(getattr(user, "id", "") or "")[:120]
    if user_id:
        customer["tradingAccountUuid"] = user_id
    return customer


def _build_v2_deposit_body(
    settings,
    user,
    gateway,
    network: str,
    amount: Decimal,
    currency: str,
    trading_account_login: str = "",
) -> dict:
    cfg = settings.currencies_config if isinstance(settings.currencies_config, dict) else {}
    callback_url = (cfg.get("callback_url") or settings.webhook_url or "").strip()
    success_url = (cfg.get("success_url") or callback_url).strip()
    failure_url = (cfg.get("failure_url") or callback_url).strip()
    pay_currency, gateway_name = network_gateway(network)
    if cfg.get("payment_currency"):
        pay_currency = str(cfg.get("payment_currency")).strip()
    if cfg.get("payment_gateway_name"):
        gateway_name = str(cfg.get("payment_gateway_name")).strip()
    fiat = (cfg.get("currency") or currency or "USD").strip().upper() or "USD"
    if fiat in {"USDT", "USX", "UST", "USB"}:
        fiat = "USD"
    amt = float(amount)
    if amt == int(amt):
        amt_value: int | float = int(amt)
    else:
        amt_value = amt
    body: dict[str, Any] = {
        "amount": amt_value,
        "apiToken": (settings.api_token or "").strip(),
        "callbackUrl": callback_url,
        "currency": fiat,
        "customer": _build_customer_payload(user, trading_account_login),
        "failureUrl": failure_url or callback_url or "https://example.com/deposit/failed",
        "paymentCurrency": pay_currency,
        "paymentGatewayName": gateway_name[:120],
        "paymentMethod": "CRYPTO_AGENT",
        "successUrl": success_url or callback_url or "https://example.com/deposit/success",
        "timestamp": int(time.time()),
    }
    extra = cfg.get("deposit_create_body")
    if isinstance(extra, dict):
        body.update(extra)
        body["paymentMethod"] = "CRYPTO_AGENT"
        body["timestamp"] = int(time.time())
        body["apiToken"] = (settings.api_token or "").strip()
    secret = (getattr(settings, "api_secret", "") or "").strip()
    if secret:
        body.pop("signature", None)
        body["signature"] = sign_request(body, secret)
    return body


def create_crypto_deposit(
    settings,
    *,
    user,
    gateway,
    amount: Decimal,
    currency: str,
    network: str,
    trading_account_login: str = "",
) -> tuple[bool, str | dict]:
    """Call Match2Pay to reserve a deposit address."""
    network_u = (network or "").strip().upper()
    if network_u not in ALLOWED_NETWORKS:
        return False, "Unsupported network."

    token = (settings.api_token or "").strip()
    if not token:
        return False, "API token is not configured."

    api_url = (settings.api_url or "").strip()
    if api_url and not api_url.lower().startswith(("http://", "https://")):
        return False, "API URL must start with http:// or https://"

    cfg = settings.currencies_config if isinstance(settings.currencies_config, dict) else {}
    url = _build_create_url(api_url or PROD_BASE, cfg)
    body = _build_v2_deposit_body(
        settings,
        user,
        gateway,
        network_u,
        amount,
        currency,
        trading_account_login,
    )
    payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "ForexCRM-Match2Pay/2.0",
    }
    req = Request(url, data=payload, method="POST", headers=headers)
    ctx = ssl.create_default_context()
    try:
        with urlopen(req, timeout=45, context=ctx) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.getcode()
    except HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace")
        except Exception:
            raw = str(e.reason)
        logger.warning("Match2Pay create HTTP %s url=%s body=%s", e.code, url, raw[:800])
        stripped = raw.lstrip().lower()
        if stripped.startswith("<!doctype") or stripped.startswith("<html"):
            return False, (
                "Match2Pay blocked the request (HTTP 403 HTML). "
                "Ask Match2Pay support to whitelist this server IP 5.226.139.8."
            )
        try:
            err = json.loads(raw)
            msg = err.get("errorMessage") or err.get("message") or err.get("error") or raw[:300]
        except Exception:
            msg = raw[:300]
        return False, f"Match2Pay API error ({e.code}): {msg}"
    except URLError as e:
        logger.exception("Match2Pay create network error")
        return False, f"Could not reach Match2Pay API: {e.reason!s}"[:200]
    except Exception as e:
        logger.exception("Match2Pay create failed")
        return False, str(e)[:200]

    if status and int(status) >= 400:
        return False, f"Match2Pay API returned HTTP {status}."

    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return False, "Match2Pay API returned non-JSON response."

    parsed = extract_create_response(data if isinstance(data, dict) else {})
    if isinstance(data, dict):
        err = data.get("errorMessage") or data.get("error") or data.get("message")
        if err and not parsed.get("payment_id"):
            msg = err if isinstance(err, str) else json.dumps(err, default=str)[:300]
            return False, f"Match2Pay API: {msg}"

    if not parsed.get("payment_id"):
        logger.warning("Match2Pay create missing paymentId: %s", raw[:800])
        return False, "Payment provider did not return a payment id. Check API response mapping."

    parsed["raw"] = data if isinstance(data, dict) else {}
    parsed["network"] = network_u
    return True, parsed


def fetch_deposit_status(settings, payment_id: str) -> tuple[bool, dict | str]:
    """Poll provider for a deposit session status (optional)."""
    token = (settings.api_token or "").strip()
    if not token:
        return False, "API token is not configured."
    pid = (payment_id or "").strip()
    if not pid or len(pid) > 200:
        return False, "Invalid payment id."

    api_url = (settings.api_url or "").strip() or PROD_BASE
    cfg = settings.currencies_config if isinstance(settings.currencies_config, dict) else {}
    path_tpl = (cfg.get("deposit_status_path") or "/api/v2/payment/{payment_id}").strip()
    method = (cfg.get("deposit_status_method") or "GET").strip().upper()
    if "{payment_id}" in path_tpl:
        path = path_tpl.replace("{payment_id}", quote(str(pid), safe=""))
    else:
        path = path_tpl
    if not path.startswith("/"):
        path = "/" + path
    url = f"{_wallet_base(api_url)}{path}"
    if method == "GET" and "payment_id" not in url.lower():
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}{urlencode({'paymentId': pid})}"

    headers = {
        "Accept": "application/json",
        "User-Agent": "ForexCRM-Match2Pay/2.0",
    }
    ctx = ssl.create_default_context()
    try:
        if method == "GET":
            req = Request(url, method="GET", headers=headers)
        else:
            headers["Content-Type"] = "application/json"
            body_dict = {"paymentId": pid, "apiToken": token}
            extra = cfg.get("deposit_status_body")
            if isinstance(extra, dict):
                body_dict.update(extra)
            req = Request(
                url,
                data=json.dumps(body_dict, separators=(",", ":")).encode("utf-8"),
                method="POST",
                headers=headers,
            )
        with urlopen(req, timeout=30, context=ctx) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.getcode()
    except HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace")
        except Exception:
            raw = str(e.reason)
        logger.warning("Match2Pay status HTTP %s: %s", e.code, raw[:500])
        return False, f"status_http_{e.code}"
    except URLError as e:
        logger.warning("Match2Pay status network error: %s", e)
        return False, "status_network_error"
    except Exception as e:
        logger.exception("Match2Pay status failed")
        return False, str(e)[:200]

    if status and int(status) >= 400:
        return False, f"status_http_{status}"

    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return False, "non_json_status"
    if not isinstance(data, dict):
        return False, "invalid_status_payload"
    return True, data
