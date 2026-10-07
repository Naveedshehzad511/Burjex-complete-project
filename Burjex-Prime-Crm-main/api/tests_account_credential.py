from unittest import mock

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import MT5Account


class AccountCredentialOtpTest(TestCase):
    """The app keeps no cookies, so the code must survive between the two calls without a session."""

    def setUp(self):
        cache.clear()
        U = get_user_model()
        self.user = U.objects.create_user(username="c1", email="c1@example.com", password="Correct-Horse-1")
        self.other = U.objects.create_user(username="c2", email="c2@example.com", password="Correct-Horse-1")
        self.acct = MT5Account.objects.create(user=self.user, login_id="500002", server="BTrader", leverage=500)
        self.acct.set_mt5_password("TradePass1")
        self.acct.set_investor_password("InvestPass1")
        self.acct.save()
        self.url = "/api/v1/accounts/500002/credential/{mode}/"
        self.sent = []

        def fake_email(to, subject, body, user=None, *a, **k):
            self.sent.append(body)
            return True, "ok"

        self.mail = mock.patch("admin_panel.email_service.send_dynamic_email", side_effect=fake_email)
        self.mail.start()
        self.addCleanup(self.mail.stop)
        self.change = mock.patch("mt5_integration.services.mt5_change_password")
        self.change_mock = self.change.start()
        self.addCleanup(self.change.stop)

    def api_client(self, user=None):
        c = APIClient()  # a fresh client per call: no cookies, no session, like the app
        c.force_authenticate(user=user or self.user)
        return c

    def post(self, mode, data, user=None):
        return self.api_client(user).post(self.url.format(mode=mode), data, format="json")

    def otp(self):
        return self.sent[-1].split("Your OTP is: ")[1][:6]

    def req(self, mode, pw="NewPass123"):
        return self.post(mode, {"action": "request_otp", "new_password": pw, "confirm_password": pw})

    def test_trading_password_change_across_two_cookieless_calls(self):
        self.assertEqual(self.req("trading").status_code, 200)
        r = self.post("trading", {"action": "verify_otp", "otp_code": self.otp(), "new_password": "NewPass123", "confirm_password": "NewPass123"})
        self.assertEqual(r.status_code, 200, r.content)
        self.change_mock.assert_called_once()
        self.assertEqual(self.change_mock.call_args.kwargs["pass_type"], "MAIN")
        self.acct.refresh_from_db()
        self.assertEqual(self.acct.get_mt5_password(), "NewPass123")
        self.assertEqual(self.acct.get_investor_password(), "InvestPass1")

    def test_investor_password_change(self):
        self.req("investor")
        r = self.post("investor", {"action": "verify_otp", "otp_code": self.otp(), "new_password": "NewPass123", "confirm_password": "NewPass123"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.change_mock.call_args.kwargs["pass_type"], "INVESTOR")
        self.acct.refresh_from_db()
        self.assertEqual(self.acct.get_investor_password(), "NewPass123")
        self.assertEqual(self.acct.get_mt5_password(), "TradePass1")

    def test_wrong_code_changes_nothing_and_locks_after_five_tries(self):
        self.req("trading")
        good = self.otp()
        bad = "000000" if good != "000000" else "111111"
        for _ in range(5):
            r = self.post("trading", {"action": "verify_otp", "otp_code": bad, "new_password": "NewPass123", "confirm_password": "NewPass123"})
            self.assertEqual(r.status_code, 400)
        r = self.post("trading", {"action": "verify_otp", "otp_code": good, "new_password": "NewPass123", "confirm_password": "NewPass123"})
        self.assertEqual(r.status_code, 400)  # locked: request a new code
        self.change_mock.assert_not_called()
        self.acct.refresh_from_db()
        self.assertEqual(self.acct.get_mt5_password(), "TradePass1")

    def test_code_is_single_use(self):
        self.req("trading")
        code = self.otp()
        body = {"action": "verify_otp", "otp_code": code, "new_password": "NewPass123", "confirm_password": "NewPass123"}
        self.assertEqual(self.post("trading", body).status_code, 200)
        self.assertEqual(self.post("trading", body).status_code, 400)

    def test_code_for_one_mode_does_not_work_for_the_other(self):
        self.req("trading")
        r = self.post("investor", {"action": "verify_otp", "otp_code": self.otp(), "new_password": "NewPass123", "confirm_password": "NewPass123"})
        self.assertEqual(r.status_code, 400)
        self.change_mock.assert_not_called()

    def test_other_users_cannot_touch_the_account(self):
        r = self.post("trading", {"action": "request_otp", "new_password": "NewPass123", "confirm_password": "NewPass123"}, user=self.other)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.sent, [])

    def test_validation(self):
        self.assertEqual(self.req("trading", "abc").status_code, 400)  # too short
        r = self.post("trading", {"action": "request_otp", "new_password": "NewPass123", "confirm_password": "Different1"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.req("trading", "InvestPass1").status_code, 400)  # equals the investor password
        self.assertEqual(self.req("investor", "TradePass1").status_code, 400)  # equals the trading password
        self.assertEqual(self.sent, [])

    def test_resend_is_throttled(self):
        self.assertEqual(self.req("trading").status_code, 200)
        self.assertEqual(self.req("trading").status_code, 400)

    def test_failed_email_is_reported_not_swallowed(self):
        self.mail.stop()
        with mock.patch("admin_panel.email_service.send_dynamic_email", return_value=(False, "smtp down")):
            r = self.req("trading")
        self.mail.start()
        self.assertEqual(r.status_code, 400)
        self.assertIn("Could not send", r.json()["message"])
