"""Best-effort outbound public IP for admin UI (IP whitelist instructions)."""

from __future__ import annotations

from urllib.request import Request, urlopen


def get_server_outbound_public_ip(timeout: float = 3.0) -> str:
    """
    IPv4/IPv6 string as seen by a simple echo service, or "" if unavailable.
    Used only to help admins paste the CRM server's IP into Match-Trader whitelist.
    """
    endpoints = (
        "https://api.ipify.org?format=text",
        "https://ifconfig.me/ip",
    )
    for url in endpoints:
        try:
            req = Request(url, headers={"User-Agent": "ForexCRM-MatchTrader/1.1"})
            with urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace").strip()
                if not raw:
                    continue
                text = raw.split()[0].strip()
                if 6 <= len(text) <= 64 and not any(c in text for c in "\n\r\t<>\"'"):
                    return text
        except Exception:
            continue
    return ""
