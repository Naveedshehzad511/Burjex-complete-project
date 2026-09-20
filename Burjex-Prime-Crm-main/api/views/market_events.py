"""Cached, client-safe daily high-impact economic-calendar events."""

from __future__ import annotations

import json
from datetime import datetime
from urllib.request import Request, urlopen

from django.core.cache import cache
from django.utils import timezone
from rest_framework.views import APIView

from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response


FOREX_FACTORY_WEEK_URL = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
_CACHE_KEY = "portal:market-events:forex-factory:daily-high:v1"
_CACHE_SECONDS = 30 * 60


def _parse_event_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _load_events() -> dict:
    cached = cache.get(_CACHE_KEY)
    if cached is not None:
        return cached

    request = Request(
        FOREX_FACTORY_WEEK_URL,
        headers={
            "Accept": "application/json",
            "User-Agent": "BurjexPrimePortal/1.0 economic-calendar",
        },
    )
    with urlopen(request, timeout=8) as response:  # nosec B310: fixed public calendar URL
        payload = response.read(1_000_000)
    raw_events = json.loads(payload.decode("utf-8"))
    if not isinstance(raw_events, list):
        raise ValueError("Forex Factory calendar returned an unexpected payload.")

    today = timezone.localdate()
    events = []
    for raw in raw_events:
        if not isinstance(raw, dict) or str(raw.get("impact", "")).upper() != "HIGH":
            continue
        occurred_at = _parse_event_time(raw.get("date"))
        if occurred_at is None or timezone.localtime(occurred_at).date() != today:
            continue
        events.append(
            {
                "time": timezone.localtime(occurred_at).strftime("%H:%M"),
                "currency": str(raw.get("country") or raw.get("currency") or "").upper(),
                "impact": "High",
                "title": str(raw.get("title") or "Economic event"),
                "timestamp": occurred_at.isoformat(),
            }
        )
    events.sort(key=lambda event: event["timestamp"])
    result = {
        "date": today.isoformat(),
        "events": events,
        "source": "Forex Factory",
    }
    cache.set(_CACHE_KEY, result, _CACHE_SECONDS)
    return result


class DailyMarketEventsAPIView(APIView):
    """Serve cached major Forex Factory events without browser CORS requests."""

    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        try:
            return success_response(_load_events(), message="Daily market events retrieved.")
        except Exception:
            return error_response(
                "Daily market events are temporarily unavailable.",
                status=503,
                data={"events": []},
            )
