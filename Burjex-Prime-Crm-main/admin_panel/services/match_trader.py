"""Match-Trader broker API helpers (GET /health under API base)."""

from __future__ import annotations

import ssl
import socket
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse, urlunparse
from urllib.request import Request, urlopen

# Default when Base URL is left blank (demo broker API root).
DEFAULT_MATCH_TRADER_DEMO_API_BASE = "https://broker-api-demo.match-trader.com/api"

# Exact demo health URLs (tried first when host is broker-api-demo).
_BROKER_DEMO_HOST = "broker-api-demo.match-trader.com"
_DEMO_HEALTH_URLS = (
    "https://broker-api-demo.match-trader.com/api/health",
    "https://broker-api-demo.match-trader.com/api/health/",
    "https://broker-api-demo.match-trader.com/api/v1/health",
    "https://broker-api-demo.match-trader.com/api/v1/health/",
)


def _normalize_base(raw: str) -> str:
    raw = (raw or "").strip()
    if not raw:
        return ""
    if not raw.lower().startswith(("http://", "https://")):
        raw = "https://" + raw
    return raw.rstrip("/")


def _is_match_trader_host(netloc: str) -> bool:
    return "match-trader" in (netloc or "").lower()


def _add(u: str, label: str, out: list[tuple[str, str]], seen: set[str]) -> None:
    if u in seen:
        return
    seen.add(u)
    out.append((u, label))


def _candidate_health_urls(base: str) -> list[tuple[str, str]]:
    """
    Ordered GET targets: **/health** (and **/health/**) under each API base.

    For broker-api-demo.match-trader.com, canonical URLs are tried first.
    """
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    b = _normalize_base(base)
    if not b:
        return out

    if _BROKER_DEMO_HOST in b.lower():
        for u in _DEMO_HEALTH_URLS:
            _add(u, f"GET {u}", out, seen)

    p = urlparse(b)
    scheme, netloc = (p.scheme or "https"), p.netloc
    origin = f"{scheme}://{netloc}"
    api_root = f"{origin}/api"
    api_v1_root = f"{origin}/api/v1"

    def health_at(root: str, label: str) -> None:
        rs = root.rstrip("/") + "/"
        for tail, extra in (("health", ""), ("health/", " (trailing /)")):
            _add(urljoin(rs, tail), label + extra, out, seen)

    mt_host = _is_match_trader_host(netloc)

    if mt_host:
        # 1) Match-Trader: …/api/health then …/api/v1/health (e.g. broker-api-demo.match-trader.com)
        health_at(api_root, f"{api_root}/health")
        health_at(api_v1_root, f"{api_v1_root}/health")
        # 2) Configured Base URL + /health
        health_at(b, "Base URL + /health")
        # 3) Host root + /health (last resort)
        if b.lower() != origin.lower():
            health_at(origin, f"{origin}/health")
    else:
        # Non–Match-Trader host: respect configured base first
        health_at(b, "Base URL + /health")
        health_at(api_root, f"{api_root}/health")
        health_at(api_v1_root, f"{api_v1_root}/health")
        if b.lower() != origin.lower():
            health_at(origin, f"{origin}/health")

    return out


def _api_root_from_health_url(health_url: str) -> str:
    """Strip trailing /health to get the API base to store."""
    pu = urlparse(health_url)
    path = (pu.path or "").rstrip("/")
    lowered = path.lower()
    if lowered.endswith("/health"):
        path = path[: -len("/health")].rstrip("/")
    new_path = "/" + path.lstrip("/") if path else "/"
    return urlunparse((pu.scheme or "https", pu.netloc, new_path, "", "", "")).rstrip("/")


def _probe_health(url: str, api_key: str, timeout: int, ctx: ssl.SSLContext) -> tuple[bool, int | str, str]:
    if not (url or "").lower().startswith("https://"):
        return False, "HTTPS_REQUIRED", "Base URL must use HTTPS (port 443)."
    req = Request(
        url,
        method="GET",
        headers={
            "User-Agent": "ForexCRM-MatchTrader/1.0",
            "Authorization": f"Bearer {api_key.strip()}",
            "Accept": "application/json, text/plain, */*",
        },
    )
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
            return True, int(code), ""
    except HTTPError as e:
        return False, int(e.code), (e.reason or "")[:200]
    except URLError as e:
        return False, str(getattr(e, "reason", e) or e), ""
    except (TimeoutError, socket.timeout):
        return False, "timeout", ""
    except OSError as e:
        return False, str(e)[:200], ""


def match_trader_simple_health_check(base_url: str, api_key: str, timeout: int = 15) -> tuple[bool, int, str]:
    """
    Single GET request: {BASE_URL}/health with Authorization: Bearer {API_KEY}.
    Success only when the broker returns HTTP 200.
    """
    key = (api_key or "").strip()
    b = _normalize_base(base_url)
    if not b or not key:
        return False, 0, ""
    path_lower = (urlparse(b).path or "").rstrip("/").lower()
    if path_lower.endswith("/health"):
        health_url = b.rstrip("/")
    else:
        health_url = b.rstrip("/") + "/health"
    ctx = ssl.create_default_context()
    req = Request(
        health_url,
        method="GET",
        headers={
            "User-Agent": "ForexCRM-MatchTrader/2.0",
            "Authorization": f"Bearer {key}",
            "Accept": "application/json, text/plain, */*",
        },
    )
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            code = int(getattr(resp, "status", None) or resp.getcode())
            return (code == 200, code, health_url)
    except HTTPError as e:
        return (False, int(e.code), health_url)
    except URLError:
        return (False, 0, health_url)
    except (TimeoutError, OSError, socket.timeout):
        return (False, 0, health_url)


def matchtrader_health_check(
    base_url: str, api_key: str, timeout: int = 15
) -> tuple[bool, str, str | None]:
    """
    Probe **GET {api_base}/health** (Bearer token). Tries /api/health and /api/v1/health
    first on Match-Trader hosts, then the configured Base URL + /health.
    """
    raw_in = (base_url or "").strip()
    raw = raw_in or DEFAULT_MATCH_TRADER_DEMO_API_BASE
    used_default_base = not bool(raw_in)
    if not (api_key or "").strip():
        return False, "API key is required.", None

    ctx = ssl.create_default_context()
    candidates = _candidate_health_urls(raw)
    if not candidates:
        return False, "Could not build health check URLs from Base URL.", None

    errors: list[str] = []
    for url, hint in candidates:
        ok, code_or_err, reason = _probe_health(url, api_key, timeout, ctx)
        if ok and isinstance(code_or_err, int) and 200 <= code_or_err < 300:
            resolved = _api_root_from_health_url(url)
            msg = f"Connected (HTTP {code_or_err}). GET /health OK — {hint}"
            if resolved and resolved.rstrip("/").lower() != _normalize_base(raw).lower():
                msg += f". API base stored: {resolved}"
            if used_default_base:
                msg += (
                    f" Default Base URL was used ({DEFAULT_MATCH_TRADER_DEMO_API_BASE}); "
                    "click Save configuration to store it."
                )
            return True, msg, resolved

        if isinstance(code_or_err, int):
            if code_or_err == 401:
                return (
                    False,
                    "Invalid API key (HTTP 401). Create a new active broker API key in Match-Trader, paste it here, "
                    "and retry. Authorization header must be: Bearer <API_KEY>.",
                    None,
                )
            if code_or_err == 403:
                errors.append(f"{hint} → HTTP 403")
                continue
            if code_or_err == 404:
                errors.append(f"{hint} → HTTP 404")
                continue
            if code_or_err >= 500:
                return (
                    False,
                    f"Broker server error (HTTP {code_or_err}). Check Base URL or try again later.",
                    None,
                )
            err = f"{hint} → HTTP {code_or_err}"
            if reason:
                err += f" ({reason})"
            errors.append(err)
        else:
            err_s = str(code_or_err)
            if err_s == "timeout":
                return False, "Connection timed out — check Base URL, firewall, and IP whitelist.", None
            return False, (f"Server unreachable: {err_s}")[:500], None

    if errors and all("403" in e for e in errors):
        return (
            False,
            "HTTP 403 on all tried /health endpoints — IP whitelisting is mandatory. "
            "In Match-Trader dashboard, add this CRM server's public outbound IP to the API whitelist, "
            "then test again. Also confirm the API key is active.",
            None,
        )
    if errors and all("404" in e for e in errors):
        return (
            False,
            "GET /health returned HTTP 404 for all tried URLs (e.g. https://broker-api-demo.match-trader.com/api/health). "
            "Set Base URL to https://broker-api-demo.match-trader.com/api or …/api/v1, save, then test. "
            "Ensure API key is active and server IP is whitelisted.",
            None,
        )
    if errors:
        tail = "; ".join(errors[:5])
        if len(errors) > 5:
            tail += f" … (+{len(errors) - 5} more)"
        return False, f"Could not reach /health. {tail}", None
    return False, "Connection check failed.", None
