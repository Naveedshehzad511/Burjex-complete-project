"""The fixed signup code (373737): verifies a NEW account's email, nothing else."""

import os
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from accounts import client_otp
from api.services import auth_service

User = get_user_model()


def make_client(email="new.client@example.com", **kw):
    return User.objects.create_user(
        username=email.split("@")[0],
        email=email,
        password="Str0ng-pass-123",
        role=User.Roles.CLIENT,
        is_active=False,
        **kw,
    )


class StaticSignupOtpTests(TestCase):
    def setUp(self):
        # An environment override must not leak in from the machine running the tests.
        patcher = mock.patch.dict(os.environ, {}, clear=False)
        patcher.start()
        os.environ.pop("CLIENT_OTP_STATIC_CODE", None)
        self.addCleanup(patcher.stop)

    def test_default_code_is_373737(self):
        self.assertEqual(client_otp.static_signup_otp(), "373737")

    def test_static_code_verifies_signup_even_if_no_email_was_ever_sent(self):
        user = make_client()  # no email_token, no timestamp: delivery never happened
        ok, reason = client_otp.verify_otp(user, "373737", purpose="email")
        self.assertTrue(ok, reason)

    def test_static_code_is_not_accepted_for_password_reset(self):
        user = make_client()
        ok, _ = client_otp.verify_otp(user, "373737", purpose="password")
        self.assertFalse(ok, "the fixed code must never reset a password")
        # ... not even when a real reset code is pending for that user
        user.email_token = client_otp.PWD_PREFIX + client_otp._digest(user.pk, "password", "123123")
        user.email_token_created_at = timezone.now()
        user.save()
        self.assertFalse(client_otp.verify_otp(user, "373737", purpose="password")[0])
        self.assertTrue(client_otp.verify_otp(user, "123123", purpose="password", consume=False)[0])

    def test_any_other_code_still_fails_for_signup(self):
        user = make_client()
        for bad in ("111111", "373738", "37373", "abcdef", ""):
            self.assertFalse(client_otp.verify_otp(user, bad, purpose="email")[0], bad)

    def test_a_real_emailed_code_still_works(self):
        user = make_client()
        user.email_token = client_otp.EMAIL_PREFIX + client_otp._digest(user.pk, "email", "654321")
        user.email_token_created_at = timezone.now()
        user.save()
        self.assertTrue(client_otp.verify_otp(user, "654321", purpose="email")[0])

    def test_env_can_change_or_switch_off_the_code(self):
        user = make_client()
        with mock.patch.dict(os.environ, {"CLIENT_OTP_STATIC_CODE": "123456"}):
            self.assertTrue(client_otp.verify_otp(user, "123456", purpose="email", consume=False)[0])
            self.assertFalse(client_otp.verify_otp(user, "373737", purpose="email", consume=False)[0])
        with mock.patch.dict(os.environ, {"CLIENT_OTP_STATIC_CODE": ""}):
            self.assertEqual(client_otp.static_signup_otp(), "")
            self.assertFalse(client_otp.verify_otp(user, "373737", purpose="email", consume=False)[0])
        with mock.patch.dict(os.environ, {"CLIENT_OTP_STATIC_CODE": "12ab"}):  # malformed -> ignored
            self.assertEqual(client_otp.static_signup_otp(), "")

    def test_portal_api_path_activates_the_account_and_signs_it_in(self):
        user = make_client("api.client@example.com")
        self.assertFalse(user.is_active)
        with mock.patch.object(client_otp, "sync_btrader_login", return_value=True):
            ok, payload = auth_service.verify_email_otp("api.client@example.com", "373737")
        self.assertTrue(ok, payload)
        self.assertTrue(payload.get("token"))
        user.refresh_from_db()
        self.assertTrue(user.is_active and user.email_verified)

    def test_portal_api_path_rejects_a_wrong_code(self):
        user = make_client("wrong.client@example.com")
        ok, payload = auth_service.verify_email_otp("wrong.client@example.com", "000000")
        self.assertFalse(ok)
        user.refresh_from_db()
        self.assertFalse(user.is_active)
