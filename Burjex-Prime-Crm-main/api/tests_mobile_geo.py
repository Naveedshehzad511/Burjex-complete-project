from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from admin_panel.models import MobileAppAccessPolicy, MobileGeoVerification
from api.services import geo_access

# Points well inside each country.
KARACHI = {"latitude": 24.86, "longitude": 67.01, "accuracy": 30}
LAHORE = {"latitude": 31.52, "longitude": 74.36, "accuracy": 30}
DUBAI = {"latitude": 25.20, "longitude": 55.27, "accuracy": 30}
LONDON = {"latitude": 51.50, "longitude": -0.12, "accuracy": 30}

IOS = {"HTTP_X_CLIENT_PLATFORM": "ios"}


def net(country):
    return {"HTTP_CF_IPCOUNTRY": country}


class CountryMapTest(TestCase):
    def test_countries_from_positions(self):
        self.assertEqual(geo_access.country_at(24.86, 67.01), "PK")  # Karachi
        self.assertEqual(geo_access.country_at(31.52, 74.36), "PK")  # Lahore, near the border
        self.assertEqual(geo_access.country_at(33.69, 73.05), "PK")  # Islamabad
        self.assertEqual(geo_access.country_at(30.18, 66.98), "PK")  # Quetta
        self.assertEqual(geo_access.country_at(31.63, 74.87), "IN")  # Amritsar, across the border
        self.assertEqual(geo_access.country_at(25.20, 55.27), "AE")
        self.assertEqual(geo_access.country_at(14.01, -60.99), "LC")  # Saint Lucia
        self.assertEqual(geo_access.country_at(37.33, -122.03), "US")
        self.assertIsNone(geo_access.country_at(20.0, 65.0))  # Arabian Sea


class _Base(TestCase):
    def setUp(self):
        geo_access.forget_policy()
        self.policy = MobileAppAccessPolicy.get_solo()  # defaults: on, PK, network must match
        U = get_user_model()
        self.user = U.objects.create_user(
            username="pk1", email="pk1@example.com", password="Correct-Horse-1", email_verified=True
        )
        self.c = APIClient()

    def tearDown(self):
        geo_access.forget_policy()

    def set_policy(self, **kw):
        for k, v in kw.items():
            setattr(self.policy, k, v)
        self.policy.save()
        geo_access.forget_policy()

    def check(self, pos, country, token=None, **extra):
        headers = {**IOS, **net(country), **extra}
        if token:
            headers["HTTP_AUTHORIZATION"] = f"Token {token}"
        r = self.c.post("/api/v1/auth/geo-check/", pos, format="json", **headers)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["data"]


class GeoCheckTest(_Base):
    def test_in_pakistan_on_a_pakistani_network(self):
        d = self.check(KARACHI, "PK")
        self.assertTrue(d["allowed"])
        self.assertEqual(d["country"], "PK")
        self.assertTrue(d["ticket"])

    def test_outside_pakistan(self):
        d = self.check(DUBAI, "AE")
        self.assertFalse(d["allowed"])
        self.assertEqual(d["reason"], geo_access.COUNTRY_BLOCKED)
        self.assertIn("only in Pakistan", d["message"])

    def test_vpn_elsewhere(self):
        d = self.check(LAHORE, "NL")
        self.assertFalse(d["allowed"])
        self.assertEqual(d["reason"], geo_access.NETWORK_MISMATCH)

    def test_pakistani_vpn_from_abroad(self):
        d = self.check(LONDON, "PK")
        self.assertFalse(d["allowed"])
        self.assertEqual(d["reason"], geo_access.COUNTRY_BLOCKED)

    def test_simulated_position(self):
        d = self.check({**KARACHI, "simulated": True}, "PK")
        self.assertFalse(d["allowed"])
        self.assertEqual(d["reason"], geo_access.SIMULATED)

    def test_no_position(self):
        d = self.check({}, "PK")
        self.assertFalse(d["allowed"])
        self.assertEqual(d["reason"], geo_access.LOCATION_REQUIRED)

    def test_imprecise_position(self):
        d = self.check({**KARACHI, "accuracy": 90000}, "PK")
        self.assertFalse(d["allowed"])

    def test_unknown_network_country(self):
        self.assertFalse(self.check(KARACHI, "XX")["allowed"])
        self.set_policy(allow_unknown_ip_country=True)
        self.assertTrue(self.check(KARACHI, "XX")["allowed"])

    def test_countries_come_from_the_admin(self):
        self.assertFalse(self.check(DUBAI, "AE")["allowed"])
        self.set_policy(allowed_countries="PK, AE")
        self.assertTrue(self.check(DUBAI, "AE")["allowed"])

    def test_switched_off(self):
        self.set_policy(ios_enabled=False)
        self.assertTrue(self.check(LONDON, "GB")["allowed"])


class SignInTest(_Base):
    def ticket(self, pos, country):
        return self.check(pos, country)["ticket"]

    def login(self, ticket=None, country="PK", platform="ios"):
        headers = {**net(country)}
        if platform:
            headers["HTTP_X_CLIENT_PLATFORM"] = platform
        if ticket:
            headers["HTTP_X_GEO_TICKET"] = ticket
        return self.c.post(
            "/api/v1/auth/login/", {"username": "pk1@example.com", "password": "Correct-Horse-1"}, format="json", **headers
        )

    def test_iphone_in_pakistan_signs_in_and_the_session_starts_verified(self):
        r = self.login(self.ticket(KARACHI, "PK"))
        self.assertEqual(r.status_code, 200, r.content)
        token = r.json()["data"]["token"]
        v = MobileGeoVerification.objects.get(token_key=token)
        self.assertTrue(v.allowed)
        self.assertEqual(v.gps_country, "PK")

    def test_iphone_abroad_is_refused(self):
        r = self.login(self.ticket(DUBAI, "AE"), country="AE")
        self.assertEqual(r.status_code, 403, r.content)
        self.assertEqual(r.json()["data"]["geo"], geo_access.COUNTRY_BLOCKED)

    def test_iphone_without_a_location_is_refused(self):
        r = self.login()
        self.assertEqual(r.status_code, 403, r.content)
        self.assertEqual(r.json()["data"]["geo"], geo_access.LOCATION_REQUIRED)

    def test_a_forged_ticket_is_refused(self):
        r = self.login("not-a-ticket")
        self.assertEqual(r.status_code, 403, r.content)

    def test_an_expired_ticket_is_refused(self):
        t = self.ticket(KARACHI, "PK")
        self.set_policy(ticket_minutes=1)
        from unittest import mock

        with mock.patch("django.core.signing.time.time", return_value=timezone.now().timestamp() + 600):
            r = self.login(t)
        self.assertEqual(r.status_code, 403, r.content)

    def test_a_ticket_carried_to_another_network_is_refused(self):
        r = self.login(self.ticket(KARACHI, "PK"), country="AE")
        self.assertEqual(r.status_code, 403, r.content)
        self.assertEqual(r.json()["data"]["geo"], geo_access.NETWORK_MISMATCH)

    def test_the_review_account_is_exempt(self):
        self.set_policy(exempt_accounts="pk1@example.com")
        r = self.login(country="US")
        self.assertEqual(r.status_code, 200, r.content)

    def test_android_and_the_website_are_not_affected(self):
        self.assertEqual(self.login(platform=None, country="AE").status_code, 200)
        self.assertEqual(self.login(platform="android", country="AE").status_code, 200)

    def test_registration_abroad_is_refused(self):
        r = self.c.post(
            "/api/v1/auth/signup/",
            {"email": "new@example.com", "password": "Correct-Horse-1", "first_name": "A", "last_name": "B"},
            format="json",
            **IOS,
            **net("AE"),
            HTTP_X_GEO_TICKET=self.ticket(DUBAI, "AE"),
        )
        self.assertEqual(r.status_code, 403, r.content)
        self.assertFalse(get_user_model().objects.filter(email="new@example.com").exists())

    def test_verify_email_code_abroad_is_refused(self):
        r = self.c.post(
            "/api/v1/auth/verify-email-otp/", {"email": "pk1@example.com", "otp": "123456"}, format="json", **IOS, **net("AE")
        )
        self.assertEqual(r.status_code, 403, r.content)


class SessionTest(_Base):
    def setUp(self):
        super().setUp()
        self.token = Token.objects.create(user=self.user).key

    def me(self, country="PK", platform="ios"):
        headers = {"HTTP_AUTHORIZATION": f"Token {self.token}", **net(country)}
        if platform:
            headers["HTTP_X_CLIENT_PLATFORM"] = platform
        return self.c.get("/api/v1/me/", **headers)

    def test_a_session_from_before_the_rule_must_check_first(self):
        r = self.me()
        self.assertEqual(r.status_code, 403, r.content)
        self.assertEqual(r.json()["data"]["geo"], geo_access.CHECK_REQUIRED)
        self.assertTrue(self.check(KARACHI, "PK", token=self.token)["allowed"])
        self.assertEqual(self.me().status_code, 200)

    def test_a_session_that_moved_abroad_is_stopped(self):
        self.check(KARACHI, "PK", token=self.token)
        self.assertEqual(self.me().status_code, 200)
        MobileGeoVerification.objects.update(verified_at=timezone.now() - timedelta(hours=13))
        self.assertEqual(self.me(country="AE").status_code, 403)
        self.assertFalse(self.check(DUBAI, "AE", token=self.token)["allowed"])
        self.assertEqual(self.me(country="AE").status_code, 403)

    def test_the_web_and_android_sessions_are_not_checked(self):
        self.assertEqual(self.me(platform=None, country="AE").status_code, 200)
        self.assertEqual(self.me(platform="android", country="AE").status_code, 200)

    def test_logout_works_without_a_check(self):
        r = self.c.post("/api/v1/auth/logout/", HTTP_AUTHORIZATION=f"Token {self.token}", **IOS, **net("AE"))
        self.assertEqual(r.status_code, 200, r.content)

    def test_the_review_account_is_never_stopped(self):
        self.set_policy(exempt_accounts="pk1@example.com")
        self.assertEqual(self.me(country="US").status_code, 200)
