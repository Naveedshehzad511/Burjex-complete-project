from decimal import Decimal
from unittest.mock import patch

from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from accounts.models import MT5Account
from admin_panel.cashback import credit_cashback_on_close
from admin_panel.models import CashbackPayout, CashbackRate
from transactions.models import Transaction

User = get_user_model()


class CashbackCreditTests(TestCase):
    def setUp(self):
        self.client_user = User.objects.create_user(
            username="cb_client",
            email="cb.client@example.com",
            password="testpassword123",
            role=User.Roles.CLIENT,
        )
        self.mt5 = MT5Account.objects.create(
            user=self.client_user,
            account_type=MT5Account.AccountType.LIVE,
            login_id="500001",
            server="btrader",
        )
        CashbackRate.objects.create(alias="xauusd.s", amount_usd=Decimal("2.00"))
        CashbackRate.objects.create(alias="eurusd.n", amount_usd=Decimal("0.50"))

    def test_credits_trader_wallet_at_crm_rate(self):
        result = credit_cashback_on_close(
            login="500001",
            engine_trade_id="trade-abc",
            alias="XAUUSD.s",
            deal_id="deal-1",
        )
        self.assertTrue(result["credited"])
        self.assertEqual(result["amount"], "2.00")
        self.client_user.refresh_from_db()
        self.assertEqual(self.client_user.wallet_balance, Decimal("2.00"))
        payout = CashbackPayout.objects.get(engine_trade_id="trade-abc")
        self.assertEqual(payout.user_id, self.client_user.id)
        self.assertEqual(payout.amount, Decimal("2.00"))
        self.assertEqual(payout.alias, "XAUUSD.s")
        tx = Transaction.objects.get(reference="CB_trade-abc")
        self.assertEqual(tx.tx_type, Transaction.TxType.CASHBACK)
        self.assertEqual(tx.to_user_id, self.client_user.id)

    def test_idempotent_on_engine_trade_id(self):
        credit_cashback_on_close(login="500001", engine_trade_id="trade-abc", alias="xauusd.s")
        again = credit_cashback_on_close(login="500001", engine_trade_id="trade-abc", alias="xauusd.s")
        self.assertFalse(again["credited"])
        self.assertEqual(again["reason"], "duplicate")
        self.assertEqual(CashbackPayout.objects.count(), 1)
        self.client_user.refresh_from_db()
        self.assertEqual(self.client_user.wallet_balance, Decimal("2.00"))

    def test_skips_demo_and_partial_and_zero_rate(self):
        demo_user = User.objects.create_user(
            username="cb_demo",
            email="cb.demo@example.com",
            password="testpassword123",
            role=User.Roles.CLIENT,
        )
        MT5Account.objects.create(
            user=demo_user,
            account_type=MT5Account.AccountType.DEMO,
            login_id="600001",
            server="btrader",
        )
        demo = credit_cashback_on_close(login="600001", engine_trade_id="t-demo", alias="xauusd.s")
        self.assertEqual(demo["reason"], "demo")
        partial = credit_cashback_on_close(
            login="500001", engine_trade_id="t-part", alias="xauusd.s", partial=True
        )
        self.assertEqual(partial["reason"], "partial")
        missing = credit_cashback_on_close(login="500001", engine_trade_id="t-none", alias="GBPUSD.n")
        self.assertEqual(missing["reason"], "no_rate")
        self.assertEqual(CashbackPayout.objects.count(), 0)

    def test_maps_feed_symbol_to_unique_alias_rate(self):
        result = credit_cashback_on_close(
            login="500001",
            engine_trade_id="trade-feed",
            alias="XAUUSD",
            deal_id="deal-feed",
        )
        self.assertTrue(result["credited"])
        self.assertEqual(result["amount"], "2.00")
        self.assertEqual(result["alias"], "xauusd.s")
        payout = CashbackPayout.objects.get(engine_trade_id="trade-feed")
        self.assertEqual(payout.alias, "xauusd.s")
        self.assertEqual(payout.amount, Decimal("2.00"))

    def test_ambiguous_aliases_need_suffix(self):
        CashbackRate.objects.create(alias="xauusd.c", amount_usd=Decimal("1.00"))
        missing = credit_cashback_on_close(
            login="500001", engine_trade_id="t-ambig", alias="XAUUSD"
        )
        self.assertEqual(missing["reason"], "no_rate")
        ok = credit_cashback_on_close(
            login="500001", engine_trade_id="t-c", alias="xauusd.c"
        )
        self.assertEqual(ok["amount"], "1.00")


class CashbackHistoryApiTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username="cb_api",
            email="cb.api@example.com",
            password="testpassword123",
            role=User.Roles.CLIENT,
        )
        self.token = Token.objects.create(user=self.user)
        CashbackPayout.objects.create(
            engine_trade_id="eng-1",
            user=self.user,
            login_id="500001",
            alias="xauusd.s",
            amount=Decimal("2.00"),
        )
        self.api = APIClient()

    def test_history_lists_engine_trade_id_and_amount(self):
        self.api.credentials(HTTP_AUTHORIZATION=f"Token {self.token.key}")
        resp = self.api.get("/api/v1/cashback/history/")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()["data"]
        self.assertEqual(data["total"], "2.00")
        self.assertEqual(data["items"][0]["engine_trade_id"], "eng-1")
        self.assertEqual(data["items"][0]["amount"], "2.00")
        self.assertEqual(data["items"][0]["alias"], "xauusd.s")


class CashbackAdminTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_user(
            username="cb_admin",
            email="admin@burjexprime.com",
            password="testpassword123",
            role=User.Roles.ADMIN,
            is_staff=True,
        )
        self.client.force_login(self.admin)

    @patch("admin_panel.cashback_views.list_btrader_engine_symbols")
    def test_admin_lists_aliases_and_saves_rate(self, mocked):
        mocked.return_value = (["xauusd.s", "xauusd.c", "eurusd.n"], "")
        resp = self.client.get("/admin/cashback/")
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, "xauusd.s")
        self.assertContains(resp, "Total cashback paid")
        self.assertContains(resp, "Top 5 clients")
        resp = self.client.post(
            "/admin/cashback/",
            {"alias": ["xauusd.s", "xauusd.c", "eurusd.n"], "amount": ["2", "1", "0.50"]},
        )
        self.assertEqual(resp.status_code, 302)
        self.assertEqual(CashbackRate.objects.get(alias="xauusd.s").amount_usd, Decimal("2.00"))
        self.assertEqual(CashbackRate.objects.get(alias="eurusd.n").amount_usd, Decimal("0.50"))
