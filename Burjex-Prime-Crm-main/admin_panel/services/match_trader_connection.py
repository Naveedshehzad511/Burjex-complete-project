"""Multi-step Match-Trader connection test: Base URL → gRPC TCP → Bearer health (ping)."""

from __future__ import annotations

import re
import socket
import time
from typing import Any

import ssl

from .match_trader import _api_root_from_health_url, _candidate_health_urls, _normalize_base, _probe_health

GRPC_TCP_TIMEOUT = 5.0
HTTP_RETRY_ATTEMPTS = 2
HTTP_RETRY_DELAY_SEC = 0.5


def _parse_grpc_target(raw: str) -> tuple[str, int] | None:
    s = (raw or "").strip()
    if not s:
        return None
    if "]:" in s:
        m = re.match(r"^\[(?P<h>[^\]]+)\]:(?P<p>\d+)$", s)
        if m:
            return m.group("h"), int(m.group("p"))
    if s.count(":") == 1 and not s.lower().startswith("http"):
        host, _, port_s = s.partition(":")
        try:
            p = int(port_s)
        except ValueError:
            return None
        if host.strip() and 1 <= p <= 65535:
            return host.strip(), p
    return None


def check_grpc_tcp(host: str, port: int, timeout: float) -> tuple[bool, str]:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return True, ""
    except socket.timeout:
        return False, "gRPC Connection Timeout"
    except OSError as e:
        msg = (str(e).strip() or "connection refused")[:200]
        return False, msg


def validate_base_url(url: str) -> tuple[bool, str]:
    u = (url or "").strip()
    if not u:
        return False, "Base URL is required."
    low = u.lower()
    if not low.startswith(("http://", "https://")):
        return False, "Invalid Base URL"
    if low.startswith("http://"):
        return False, "Base URL must use HTTPS (port 443)."
    from urllib.parse import urlparse

    parsed = urlparse(u)
    if not parsed.netloc:
        return False, "Invalid Base URL"
    return True, ""


def run_match_trader_connection_test(
    base_url: str,
    grpc_address: str,
    api_key: str,
    *,
    environment: str = "LIVE",
    http_timeout: int = 18,
) -> dict[str, Any]:
    steps: list[dict[str, Any]] = []
    env_label = "Live" if (environment or "").upper() == "LIVE" else "Sandbox"

    ok_url, err_url = validate_base_url(base_url)
    steps.append({"step": 1, "name": "validate_base_url", "ok": ok_url, "detail": err_url or "OK"})
    if not ok_url:
        return {
            "ok": False,
            "error_code": "INVALID_BASE_URL",
            "error_message": "Connection failed: Invalid Base URL",
            "user_error": "❌ Invalid Base URL",
            "latency_ms": None,
            "environment_label": env_label,
            "steps": steps,
            "health_url": "",
            "resolved_base_url": "",
        }

    if not (grpc_address or "").strip():
        grpc_ok = False
        grpc_detail = "gRPC address is required"
    else:
        parsed = _parse_grpc_target(grpc_address)
        if not parsed:
            grpc_ok = False
            grpc_detail = "Invalid gRPC address (expected host:port)"
        else:
            host, port = parsed
            grpc_ok, grpc_err = check_grpc_tcp(host, port, GRPC_TCP_TIMEOUT)
            grpc_detail = "TCP reachable" if grpc_ok else grpc_err
    steps.append({"step": 2, "name": "grpc_tcp", "ok": grpc_ok, "detail": grpc_detail})
    if not grpc_ok:
        if grpc_detail == "gRPC Connection Timeout":
            em = "Connection failed: gRPC Connection Timeout"
            ue = "❌ gRPC Connection Timeout"
            code = "GRPC_TIMEOUT"
        else:
            em = f"Connection failed: Server Unreachable ({grpc_detail})"
            ue = "❌ Server Unreachable"
            code = "GRPC_UNREACHABLE"
        return {
            "ok": False,
            "error_code": code,
            "error_message": em,
            "user_error": ue,
            "latency_ms": None,
            "environment_label": env_label,
            "steps": steps,
            "health_url": "",
            "resolved_base_url": "",
        }

    key = (api_key or "").strip()
    if not key:
        steps.append({"step": 3, "name": "authenticate", "ok": False, "detail": "API key required"})
        return {
            "ok": False,
            "error_code": "INVALID_API_KEY",
            "error_message": "Connection failed: Invalid API Key",
            "user_error": "❌ Invalid API Key",
            "latency_ms": None,
            "environment_label": env_label,
            "steps": steps,
            "health_url": "",
            "resolved_base_url": "",
        }
    steps.append({"step": 3, "name": "authenticate", "ok": True, "detail": "API key present"})

    raw_base = _normalize_base(base_url)
    ctx = ssl.create_default_context()
    candidates = _candidate_health_urls(base_url)
    if not candidates:
        steps.append({"step": 4, "name": "ping", "ok": False, "detail": "No health candidates"})
        return {
            "ok": False,
            "error_code": "SERVER_UNREACHABLE",
            "error_message": "Connection failed: Server Unreachable",
            "user_error": "❌ Server Unreachable",
            "latency_ms": None,
            "environment_label": env_label,
            "steps": steps,
            "health_url": "",
            "resolved_base_url": raw_base,
        }

    last_url = ""
    last_code: int | str = 0
    success_url = ""
    latency_ms: int | None = None

    for attempt in range(HTTP_RETRY_ATTEMPTS + 1):
        for url, _hint in candidates:
            t0 = time.monotonic()
            hok, code_or_err, _reason = _probe_health(url, key, http_timeout, ctx)
            dt_ms = int((time.monotonic() - t0) * 1000)
            last_url = url
            last_code = code_or_err
            if hok and isinstance(code_or_err, int) and code_or_err == 200:
                success_url = url
                latency_ms = dt_ms
                break
        if success_url:
            break
        if isinstance(last_code, str) and last_code == "timeout" and attempt < HTTP_RETRY_ATTEMPTS:
            time.sleep(HTTP_RETRY_DELAY_SEC)
            continue
        break

    if success_url:
        try:
            resolved = _api_root_from_health_url(success_url)
        except Exception:
            resolved = raw_base
        if not (resolved or "").strip():
            resolved = raw_base
        steps.append(
            {
                "step": 4,
                "name": "ping",
                "ok": True,
                "detail": f"GET {success_url} → 200 ({latency_ms} ms)",
            }
        )
        steps.append({"step": 5, "name": "result", "ok": True, "detail": "Connected"})
        return {
            "ok": True,
            "error_code": None,
            "error_message": "",
            "user_error": "",
            "latency_ms": latency_ms,
            "resolved_base_url": resolved[:500] if resolved else "",
            "environment_label": env_label,
            "steps": steps,
            "health_url": success_url,
        }

    steps.append({"step": 4, "name": "ping", "ok": False, "detail": str(last_code)})

    if isinstance(last_code, int):
        if last_code == 401:
            em, ue, code = "Connection failed: Invalid API Key", "❌ Invalid API Key", "INVALID_API_KEY"
        elif last_code == 403:
            em, ue, code = "Connection failed: Authentication Failed", "❌ Authentication Failed", "AUTH_FAILED"
        else:
            em = f"Connection failed: HTTP {last_code}"
            ue = "❌ Server Unreachable"
            code = "HTTP_ERROR"
    else:
        err_s = str(last_code)
        if err_s == "timeout":
            em = "Connection failed: gRPC timeout"
            ue = "❌ gRPC Connection Timeout"
            code = "HTTP_TIMEOUT"
        else:
            em = f"Connection failed: Server Unreachable ({err_s})"
            ue = "❌ Server Unreachable"
            code = "SERVER_UNREACHABLE"

    steps.append({"step": 5, "name": "result", "ok": False, "detail": em})
    return {
        "ok": False,
        "error_code": code,
        "error_message": em,
        "user_error": ue,
        "latency_ms": None,
        "environment_label": env_label,
        "steps": steps,
        "health_url": last_url,
        "resolved_base_url": "",
    }
