"""Simple cache-backed rate limits for abuse-prone public endpoints."""

from __future__ import annotations

from django.core.cache import cache

from .utils import get_client_ip


def allow_ip_action(ip: str, key: str, limit: int, window_seconds: int) -> bool:
    """
    Return True if under limit; increment counter atomically-ish via cache.
    """
    if not ip:
        ip = "unknown"
    ckey = f"rl:{key}:{ip}"
    try:
        n = cache.incr(ckey)
    except ValueError:
        cache.add(ckey, 1, timeout=window_seconds)
        n = 1
    return n <= limit


def client_ip_rate_allow(request, key: str, limit: int, window_seconds: int) -> bool:
    return allow_ip_action(get_client_ip(request) or "unknown", key, limit, window_seconds)
