import json
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from accounts.models import User


class DailyMarketEventsApiTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username="market_events_client",
            email="market.events@example.com",
            password="testpassword123",
            role=User.Roles.CLIENT,
        )
        token = Token.objects.create(user=self.user)
        self.api = APIClient()
        self.api.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        cache.clear()

    @patch("api.views.market_events.urlopen")
    def test_returns_only_todays_high_impact_events(self, mocked_urlopen):
        now = timezone.now()
        response = MagicMock()
        response.read.return_value = json.dumps(
            [
                {
                    "date": now.isoformat(),
                    "country": "USD",
                    "impact": "High",
                    "title": "Federal Reserve Rate Decision",
                },
                {
                    "date": now.isoformat(),
                    "country": "USD",
                    "impact": "Low",
                    "title": "Low priority release",
                },
            ]
        ).encode()
        mocked_urlopen.return_value.__enter__.return_value = response

        result = self.api.get("/api/v1/market-events/")

        self.assertEqual(result.status_code, 200)
        events = result.json()["data"]["events"]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["currency"], "USD")
        self.assertEqual(events[0]["impact"], "High")
        self.assertEqual(events[0]["title"], "Federal Reserve Rate Decision")
