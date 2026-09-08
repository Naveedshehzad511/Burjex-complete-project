from __future__ import annotations

from enterprise.audit import get_client_ip


def portal_client_meta(request):
    """Client IP for authenticated portal users (templates: portal_client_ip)."""
    if not getattr(request, "user", None) or not request.user.is_authenticated:
        return {"portal_client_ip": ""}
    ip = get_client_ip(request)
    return {"portal_client_ip": (ip.strip() if ip else "") or "—"}
