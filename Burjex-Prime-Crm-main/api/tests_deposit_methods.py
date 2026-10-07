from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from transactions.models import PaymentGateway


class DepositMethodsPayloadTest(TestCase):
    """The portal app builds the Deposit screen from this payload, so it must carry everything the
    CRM website shows for a method (bank details, rate, badge) and never a provider's secrets."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="dep1", email="dep1@example.com", password="Correct-Horse-1"
        )
        self.api = APIClient()
        self.api.force_authenticate(user=self.user)

    def _gateways(self):
        r = self.api.get("/api/v1/deposits/methods/")
        self.assertEqual(r.status_code, 200, r.content)
        return {g["code"]: g for g in r.json()["data"]["gateways"]}

    def test_manual_bank_method_carries_details_rate_and_badge(self):
        PaymentGateway.objects.create(
            name="UBL",
            code="ubl",
            scope=PaymentGateway.Scope.DEPOSIT,
            gateway_type=PaymentGateway.GatewayType.LOCAL,
            payment_method=PaymentGateway.PaymentMethod.BANK,
            currency="PKR",
            min_amount=10,
            processing_time="1-5 Hours",
            bank_name="UBL Bank limited",
            account_name="Naveed Commission shop",
            account_number="353668216",
            iban="PK38UNIL0109000353668216",
            swift_code="UNILPKKA",
            exchange_rate=281,
            display_badge="Popular",
            fee_type=PaymentGateway.FeeType.PERCENT,
            fee_value=1.5,
        )
        g = self._gateways()["ubl"]
        self.assertEqual(g["profile"], "MANUAL")
        self.assertEqual(g["bank_name"], "UBL Bank limited")
        self.assertEqual(g["account_name"], "Naveed Commission shop")
        self.assertEqual(g["account_number"], "353668216")
        self.assertEqual(g["iban"], "PK38UNIL0109000353668216")
        self.assertEqual(g["swift_code"], "UNILPKKA")
        self.assertEqual(g["currency"], "PKR")
        self.assertEqual(float(g["exchange_rate"]), 281.0)
        self.assertEqual(g["display_badge"], "Popular")
        self.assertEqual(g["fee_type"], "PERCENT")
        self.assertEqual(g["icon"], "")
        self.assertTrue(g["can_use"])

    def test_maintenance_method_is_listed_but_not_usable(self):
        PaymentGateway.objects.create(
            name="Old Bank",
            code="old",
            scope=PaymentGateway.Scope.BOTH,
            visibility_status=PaymentGateway.VisibilityStatus.MAINTENANCE,
        )
        self.assertFalse(self._gateways()["old"]["can_use"])

    def test_gateway_secrets_are_never_sent(self):
        PaymentGateway.objects.create(
            name="Provider",
            code="prov",
            scope=PaymentGateway.Scope.DEPOSIT,
            api_key="KEY-123",
            secret_key="SECRET-456",
            merchant_id="MERCH-789",
        )
        body = self.api.get("/api/v1/deposits/methods/").content.decode()
        for secret in ("KEY-123", "SECRET-456", "MERCH-789"):
            self.assertNotIn(secret, body)
