"""Portal signup verify: the BTrader email login must exist before the app signs in to it."""

from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from accounts import client_otp
from api.services import auth_service

User = get_user_model()

PASSWORD = "Str0ng-pass-123"
CODE = "654321"


def make_client(email="signup.client@example.com"):
    user = User.objects.create_user(
        username=email.split("@")[0],
        email=email,
        password=PASSWORD,
        role=User.Roles.CLIENT,
        is_active=False,
    )
    user.email_token = client_otp.EMAIL_PREFIX + client_otp._digest(user.pk, "email", CODE)
    user.email_token_created_at = timezone.now()
    user.save()
    return user


class VerifyEmailOtpBTraderLoginTests(TestCase):
    def setUp(self):
        patcher = mock.patch.object(auth_service, "_btrader_enabled", return_value=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _sync(self, *results):
        return mock.patch.object(client_otp, "sync_btrader_login", side_effect=list(results))

    def test_signup_verify_sets_the_trading_password_and_signs_in(self):
        user = make_client()
        with self._sync(True) as sync:
            ok, payload = auth_service.verify_email_otp(user.email, CODE, PASSWORD)
        self.assertTrue(ok, payload)
        self.assertTrue(payload.get("token"))
        sync.assert_called_once_with(user, password=PASSWORD, is_active=True)

    def test_failed_trading_login_sync_is_reported_and_verify_again_retries_it(self):
        user = make_client()
        with self._sync(False):
            ok, payload = auth_service.verify_email_otp(user.email, CODE, PASSWORD)
        self.assertFalse(ok)
        self.assertEqual(payload["message"], auth_service.TRADING_LOGIN_SYNC_FAILED)
        user.refresh_from_db()
        self.assertTrue(user.email_verified and user.is_active)

        # The code was consumed; the retry goes through the already-verified path.
        with self._sync(True) as sync:
            ok, payload = auth_service.verify_email_otp(user.email, CODE, PASSWORD)
        self.assertTrue(ok, payload)
        self.assertTrue(payload.get("token"))
        sync.assert_called_once_with(user, password=PASSWORD, is_active=True)

    def test_sync_failure_does_not_block_when_btrader_is_not_configured(self):
        user = make_client()
        with mock.patch.object(auth_service, "_btrader_enabled", return_value=False), self._sync(False):
            ok, payload = auth_service.verify_email_otp(user.email, CODE, PASSWORD)
        self.assertTrue(ok, payload)

    def test_verify_without_password_still_verifies_the_email(self):
        user = make_client()
        with self._sync(False):
            ok, payload = auth_service.verify_email_otp(user.email, CODE)
        self.assertTrue(ok, payload)
        user.refresh_from_db()
        self.assertTrue(user.email_verified)

    def test_wrong_code_does_not_sync(self):
        user = make_client()
        with self._sync() as sync:
            ok, _ = auth_service.verify_email_otp(user.email, "000000", PASSWORD)
        self.assertFalse(ok)
        sync.assert_not_called()


class AlreadyVerifiedNeedsPasswordTests(TestCase):
    """An already-verified email skips the OTP, so it must not hand out a token on email alone."""

    def setUp(self):
        self.user = make_client("verified.client@example.com")
        self.user.email_verified = True
        self.user.is_active = True
        self.user.save()

    def test_email_alone_gets_no_token_and_no_sync(self):
        with mock.patch.object(client_otp, "sync_btrader_login") as sync:
            ok, payload = auth_service.verify_email_otp(self.user.email, "")
        self.assertTrue(ok)
        self.assertNotIn("token", payload)
        sync.assert_not_called()

    def test_wrong_password_gets_no_token(self):
        with mock.patch.object(client_otp, "sync_btrader_login") as sync:
            ok, payload = auth_service.verify_email_otp(self.user.email, "", "wrong-password")
        self.assertTrue(ok)
        self.assertNotIn("token", payload)
        sync.assert_not_called()
