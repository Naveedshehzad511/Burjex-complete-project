"""Match-Trader broker gRPC connection test (TLS channel handshake)."""

from __future__ import annotations

import re
import sys
import time
from typing import Any
from urllib.parse import urlparse

from .match_trader import _normalize_base
from .match_trader_connection import check_grpc_tcp, validate_base_url


def parse_grpc_target(raw: str, default_port: int = 443) -> tuple[str, int] | None:
    """
    host, host:port, or [ipv6]:port. Host-only uses default_port (443).
    """
    s = (raw or "").strip()
    if not s or s.lower().startswith("http"):
        return None
    if "]:" in s:
        m = re.match(r"^\[(?P<h>[^\]]+)\]:(?P<p>\d+)$", s)
        if m:
            return m.group("h"), int(m.group("p"))
    if s.count(":") == 1:
        host, _, port_s = s.partition(":")
        try:
            p = int(port_s)
        except ValueError:
            return None
        if host.strip() and 1 <= p <= 65535:
            return host.strip(), p
    if "/" in s or " " in s:
        return None
    return s, default_port


def match_trader_api_root_for_catalog(https_base: str) -> str:
    """Derive REST catalog base from HTTPS broker URL (e.g. …/api for host-only URLs)."""
    b = _normalize_base(https_base)
    if not b:
        return ""
    low = b.lower()
    if low.endswith("/api") or "/api/" in low:
        return b.rstrip("/")
    p = urlparse(b)
    path = (p.path or "").rstrip("/")
    if not path:
        return f"{p.scheme}://{p.netloc}/api".rstrip("/")
    return b.rstrip("/")


def match_trader_grpc_handshake(
    grpc_host: str,
    grpc_port: int,
    api_key: str,
    *,
    timeout: float = 18.0,
) -> tuple[bool, str, int | None]:
    """
    Wait for a secure gRPC channel to become READY (TLS handshake with the broker).
    API key must be non-empty (used for broker operations; channel itself is anonymous TLS).
    """
    key = (api_key or "").strip()
    if not key:
        return False, "Secret API key is required.", None

    target = f"{grpc_host}:{grpc_port}"
    t0 = time.monotonic()

    try:
        import grpc
    except ImportError:
        ms = int((time.monotonic() - t0) * 1000)
        py = sys.executable or "python"
        return (
            False,
            "The grpcio package is not installed for the Python that runs Django. "
            f"Install it into this exact environment, then restart the server:\n\n"
            f'  "{py}" -m pip install "grpcio>=1.60,<2"\n\n'
            "If you use a virtualenv, activate it first or use that venv’s python.exe. "
            "TCP-only checks are not accepted for Match-Trader.",
            ms,
        )

    class _BearerMetadata(grpc.AuthMetadataPlugin):
        def __init__(self, token: str) -> None:
            self._token = (token or "").strip()

        def __call__(self, context, callback):  # noqa: ARG002
            if self._token:
                callback((("authorization", f"Bearer {self._token}"),), None)
            else:
                callback((), None)

    ssl_creds = grpc.ssl_channel_credentials()
    call_creds = grpc.metadata_call_credentials(_BearerMetadata(api_key))
    creds = grpc.composite_channel_credentials(ssl_creds, call_creds)
    channel = grpc.secure_channel(target, creds)
    try:
        grpc.channel_ready_future(channel).result(timeout=timeout)
        ms = int((time.monotonic() - t0) * 1000)
        return True, f"gRPC TLS handshake OK ({target})", ms
    except grpc.FutureTimeoutError:
        ms = int((time.monotonic() - t0) * 1000)
        return False, f"gRPC handshake timed out ({target}, {int(timeout)}s).", ms
    except Exception as exc:  # pragma: no cover - network / SSL
        ms = int((time.monotonic() - t0) * 1000)
        return False, str(exc).strip()[:500] or "gRPC handshake failed.", ms
    finally:
        channel.close()


def match_trader_test_grpc_connection(
    *,
    base_url: str,
    grpc_address: str,
    api_key: str,
    timeout: int = 20,
) -> dict[str, Any]:
    """
    Validate HTTPS base URL, parse gRPC target, run TLS gRPC handshake.
    """
    ok_b, err_b = validate_base_url(base_url)
    if not ok_b:
        return {
            "ok": False,
            "user_error": err_b or "Invalid Base URL",
            "detail": err_b or "Invalid Base URL",
            "resolved_base": "",
            "latency_ms": None,
        }

    if not (api_key or "").strip():
        return {
            "ok": False,
            "user_error": "Secret API key is required",
            "detail": "API key cannot be empty for gRPC and REST validation.",
            "resolved_base": "",
            "latency_ms": None,
        }

    parsed = parse_grpc_target(grpc_address)
    if not parsed:
        return {
            "ok": False,
            "user_error": "Invalid gRPC address",
            "detail": "Enter the gRPC host (e.g. grpc-broker-api.match-trader.com) or host:port.",
            "resolved_base": "",
            "latency_ms": None,
        }

    host, port = parsed
    gh_ok, gh_msg, latency_ms = match_trader_grpc_handshake(host, port, api_key, timeout=float(timeout))

    api_root = match_trader_api_root_for_catalog(base_url)

    if gh_ok:
        return {
            "ok": True,
            "user_error": "",
            "user_message": "gRPC TLS handshake OK (REST API key not verified yet)",
            "detail": gh_msg,
            "resolved_base": api_root[:500],
            "latency_ms": latency_ms,
        }

    return {
        "ok": False,
        "user_error": gh_msg,
        "detail": gh_msg,
        "resolved_base": "",
        "latency_ms": latency_ms,
    }
