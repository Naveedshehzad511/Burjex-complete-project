from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import AccountDeletionRequest


class AccountDeletionFlowTest(TestCase):
    def setUp(self):
        U = get_user_model()
        self.user = U.objects.create_user(
            username="c1", email="c1@example.com", password="Correct-Horse-1"
        )
        self.c = APIClient()
        self.c.force_authenticate(user=self.user)
        self.url = "/api/v1/me/deletion-request/"

    def test_get_before_any_request(self):
        r = self.c.get(self.url)
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()["data"]
        self.assertIsNone(d["request"])
        self.assertIn("erased", d["policy"])
        self.assertIn("retained", d["policy"])
        self.assertEqual(d["policy"]["grace_days"], 30)

    def test_wrong_password_is_rejected(self):
        r = self.c.post(self.url, {"password": "nope", "reason": "PRIVACY"}, format="json")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertFalse(AccountDeletionRequest.objects.exists())

    def test_missing_password_is_rejected(self):
        r = self.c.post(self.url, {"reason": "PRIVACY"}, format="json")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertFalse(AccountDeletionRequest.objects.exists())

    def test_create_then_cancel(self):
        r = self.c.post(
            self.url,
            {"password": "Correct-Horse-1", "reason": "PRIVACY", "details": "bye"},
            format="json",
        )
        self.assertEqual(r.status_code, 201, r.content)
        d = r.json()["data"]["request"]
        self.assertEqual(d["status"], "PENDING")
        self.assertTrue(d["is_cancellable"])
        self.assertLessEqual(d["days_remaining"], 30)
        self.assertGreater(d["days_remaining"], 28)

        # GET now reports it
        d2 = self.c.get(self.url).json()["data"]["request"]
        self.assertEqual(d2["id"], d["id"])

        # cancel
        r3 = self.c.delete(self.url)
        self.assertEqual(r3.status_code, 200, r3.content)
        self.assertIsNone(r3.json()["data"]["request"])
        self.assertEqual(
            AccountDeletionRequest.objects.get(id=d["id"]).status, "CANCELLED"
        )

    def test_duplicate_request_is_idempotent_not_an_error(self):
        p = {"password": "Correct-Horse-1", "reason": "OTHER"}
        self.assertEqual(self.c.post(self.url, p, format="json").status_code, 201)
        r = self.c.post(self.url, p, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(AccountDeletionRequest.objects.filter(status="PENDING").count(), 1)

    def test_cancel_without_request_is_404(self):
        self.assertEqual(self.c.delete(self.url).status_code, 404)

    def test_requires_authentication(self):
        anon = APIClient()
        self.assertIn(anon.get(self.url).status_code, (401, 403))
