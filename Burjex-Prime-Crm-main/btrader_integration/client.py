"""
HMAC client for B-Trader gateway `/v1/crm/*` (docs/11-crm-integration.md).

Headers: X-BT-Key, X-BT-Timestamp, X-BT-Signature
Signature: HMAC_SHA256(secret, "{timestamp}.{rawBody}") hex — GET signs over "{}".
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time
import urllib.error
import urllib.request
from typing import Any

logger = logging.getLogger(__name__)


class BTraderAPIError(Exception):
    def __init__(self, message: str, *, status: int | None = None, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body


class BTraderClient:
    def __init__(
        self,
        *,
        base_url: str,
        key_id: str,
        secret: str,
        tenant_header: str = "",
        timeout: float = 20.0,
    ):
        self.base_url = (base_url or "").rstrip("/")
        # Accept either http://host:4100 or http://host:4100/v1
        if self.base_url.endswith("/v1"):
            self.api_root = self.base_url
        else:
            self.api_root = f"{self.base_url}/v1"
        self.key_id = (key_id or "").strip()
        self.secret = (secret or "").strip()
        self.tenant_header = (tenant_header or "").strip()
        self.timeout = timeout

    def _sign(self, timestamp: str, raw_body: str) -> str:
        msg = f"{timestamp}.{raw_body}".encode("utf-8")
        return hmac.new(self.secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()

    @staticmethod
    def _json_ready(value: Any) -> Any:
        """Normalize payload so JSON matches Node/Nest re-stringify (500 not 500.0)."""
        if isinstance(value, float) and value.is_integer():
            return int(value)
        if isinstance(value, dict):
            return {k: BTraderClient._json_ready(v) for k, v in value.items()}
        if isinstance(value, list):
            return [BTraderClient._json_ready(v) for v in value]
        return value

    def request(self, method: str, path: str, body: dict | None = None) -> Any:
        method = method.upper()
        if not path.startswith("/"):
            path = "/" + path
        url = f"{self.api_root}{path}"

        if method == "GET":
            raw = "{}"
            data_bytes = None
        else:
            raw = json.dumps(
                self._json_ready(body if body is not None else {}),
                separators=(",", ":"),
                ensure_ascii=False,
            )
            data_bytes = raw.encode("utf-8")

        ts = str(int(time.time() * 1000))
        sig = self._sign(ts, raw)
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "BurjexCRM-BTrader/1.0",
            "X-BT-Key": self.key_id,
            "X-BT-Timestamp": ts,
            "X-BT-Signature": sig,
        }
        if self.tenant_header:
            headers["X-BT-Tenant"] = self.tenant_header

        req = urllib.request.Request(url, data=data_bytes, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                text = resp.read().decode("utf-8", errors="replace")
                if not text:
                    return {}
                return json.loads(text)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace") if e.fp else ""
            raise BTraderAPIError(
                f"BTrader HTTP {e.code}: {err_body[:500] or e.reason}",
                status=e.code,
                body=err_body,
            ) from e
        except urllib.error.URLError as e:
            raise BTraderAPIError(f"BTrader connection error: {e.reason}") from e
        except json.JSONDecodeError as e:
            raise BTraderAPIError(f"BTrader returned invalid JSON: {e}") from e

    def list_groups(self) -> list[dict]:
        data = self.request("GET", "/crm/groups")
        if isinstance(data, list):
            return data
        if isinstance(data, dict) and isinstance(data.get("groups"), list):
            return data["groups"]
        return []

    def create_account(self, payload: dict) -> dict:
        return self.request("POST", "/crm/accounts", payload)

    def get_account(self, login: str) -> dict:
        return self.request("GET", f"/crm/accounts/{login}")

    def batch_accounts(self, logins: list[str]) -> dict:
        """POST /crm/accounts/batch → {login: accountInfo, ...}."""
        data = self.request("POST", "/crm/accounts/batch", {"logins": [str(x) for x in logins]})
        if isinstance(data, dict):
            # Some gateways wrap as {"accounts": {...}}
            inner = data.get("accounts")
            if isinstance(inner, dict):
                return inner
            return data
        return {}

    def balance_op(self, login: str, payload: dict) -> dict:
        return self.request("POST", f"/crm/accounts/{login}/balance", payload)

    def ping(self) -> tuple[bool, str]:
        """Health/auth check via GET /crm/groups (crm.read)."""
        try:
            groups = self.list_groups()
            return True, f"Authenticated OK ({len(groups)} trading group(s))."
        except BTraderAPIError as e:
            return False, str(e)[:500]
        except Exception as e:
            return False, str(e)[:500]
