from unittest.mock import patch

from django.test import TestCase

from accounts.models import User

from .models import EmailNotificationSettings, NotificationLog, NotificationTemplate
from .utils import render_notification, send_notification


class EmailNotificationEngineTests(TestCase):
    def setUp(self):
        self.signal_patcher = patch("email_notifications.signals._fire_email_task")
        self.signal_patcher.start()
        self.addCleanup(self.signal_patcher.stop)

        self.user = User.objects.create_user(
            username="client@example.com",
            email="client@example.com",
            password="test-pass-123",
            first_name="Test",
            last_name="Client",
        )
        self.template = NotificationTemplate.objects.create(
            name="OTP Verification",
            event_key="otp_verification",
            category=NotificationTemplate.Category.AUTH,
            subject="OTP for {{user_name}}",
            html_content="<p>Hello {{user_name}}, code {{otp}}</p>",
            is_active=True,
        )

    def test_render_notification_replaces_placeholders(self):
        result = render_notification(
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
            user=self.user,
        )

        self.assertIsNotNone(result)
        subject, html = result
        self.assertIn("Test Client", subject)
        self.assertIn("123456", html)

    @patch("django.core.mail.message.EmailMessage.send", return_value=1)
    @patch("email_notifications.utils._get_smtp_connection", return_value=(object(), "CRM <no-reply@example.com>"))
    def test_send_notification_creates_sent_log(self, _connection, _send):
        ok = send_notification(
            self.user.pk,
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
        )

        self.assertTrue(ok)
        log = NotificationLog.objects.get(event_key="otp_verification")
        self.assertEqual(log.status, NotificationLog.Status.SENT)
        self.assertEqual(log.recipient, self.user.email)

    @patch("django.core.mail.message.EmailMessage.send", return_value=1)
    @patch("email_notifications.utils._get_smtp_connection", return_value=(object(), "CRM <no-reply@example.com>"))
    def test_duplicate_send_is_skipped(self, _connection, _send):
        first = send_notification(
            self.user.pk,
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
        )
        second = send_notification(
            self.user.pk,
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
        )

        self.assertTrue(first)
        self.assertTrue(second)
        self.assertEqual(NotificationLog.objects.filter(event_key="otp_verification").count(), 1)

    @patch("django.core.mail.message.EmailMessage.send", return_value=1)
    @patch("email_notifications.utils._get_smtp_connection", return_value=(object(), "CRM <no-reply@example.com>"))
    def test_rate_limit_blocks_recipient(self, _connection, _send):
        for i in range(20):
            NotificationLog.objects.create(
                recipient=self.user.email,
                user=self.user,
                event_key=f"existing_{i}",
                subject=f"Existing {i}",
                status=NotificationLog.Status.SENT,
            )

        ok = send_notification(
            self.user.pk,
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
        )

        self.assertFalse(ok)
        self.assertFalse(NotificationLog.objects.filter(event_key="otp_verification").exists())

    def test_master_switch_blocks_sending(self):
        settings = EmailNotificationSettings.get_solo()
        settings.is_active = False
        settings.save(update_fields=["is_active", "updated_at"])

        ok = send_notification(
            self.user.pk,
            "otp_verification",
            {"to_email": self.user.email, "otp": "123456"},
        )

        self.assertFalse(ok)
        self.assertFalse(NotificationLog.objects.filter(event_key="otp_verification").exists())
