"""Trading-account withdrawals taken out of the balance when requested (the engine's DEBITED status).

The engine side (debit on request, payout without a second debit, refund exactly once) is tested in the gateway
(`withdraw-debit.db.test.ts`). Here: what the CRM does with it - the request carries its comment, the withdrawable
amount no longer subtracts requests that are already out of the balance, and an old request the account can no
longer cover is rejected at approval instead of waiting to be paid out of a later deposit.
"""

from decimal import Decimal
from types import SimpleNamespace
from unittest import mock

from django.test import SimpleTestCase

from transactions import trading_withdraw as tw
from transactions.models import Transaction


def _tx(**kw):
    tx = SimpleNamespace(
        id=277,
        amount=Decimal("35"),
        status=Transaction.Status.PENDING,
        trading_account_id=7,
        trading_account=SimpleNamespace(id=7),
        actor_id=1,
        reject_reason="",
        processed_at=None,
        processed_by=None,
        **kw,
    )
    tx.save = mock.Mock()
    return tx


def _approve(tx, debit_error=None, released="RELEASED"):
    account = SimpleNamespace(id=7, user_id=1, mt5_account=SimpleNamespace(login_id="500145"), account_number="500145")
    qs = mock.Mock()
    qs.select_for_update.return_value.select_related.return_value.filter.return_value.first.return_value = account
    with mock.patch.object(tw.TradingAccount, "objects", qs), \
            mock.patch.object(tw, "_is_eligible", return_value=True), \
            mock.patch.object(tw, "release", return_value=(released, "")) as release, \
            mock.patch("btrader_integration.services.is_btrader_configured", return_value=True), \
            mock.patch("btrader_integration.services.withdraw_btrader_balance", side_effect=debit_error) as debit:
        ok, msg = tw.approve(tx, admin_user="admin")
    return ok, msg, debit, release


class ApproveTests(SimpleTestCase):
    def test_approval_pays_the_request_with_its_reservation(self):
        tx = _tx()
        ok, msg, debit, release = _approve(tx)
        self.assertTrue(ok, msg)
        self.assertEqual(tx.status, Transaction.Status.APPROVED)
        kwargs = debit.call_args.kwargs
        self.assertEqual(kwargs["external_ref"], "crm-withdraw-277")
        self.assertEqual(kwargs["reservation_ref"], "crm-withdraw-reserve-277")
        release.assert_not_called()

    def test_an_old_request_the_account_no_longer_covers_is_rejected_not_left_pending(self):
        tx = _tx()
        err = Exception('{"code":"BT_INSUFFICIENT_FUNDS","message":"insufficient funds: need 35, available 1.94"}')
        ok, msg, _debit, release = _approve(tx, debit_error=err)
        self.assertFalse(ok)
        self.assertIn("automatically REJECTED", msg)
        self.assertEqual(tx.status, Transaction.Status.REJECTED)
        self.assertIn("no longer had the funds", tx.reject_reason)
        release.assert_called_once()  # the old hold is dropped exactly once

    def test_any_other_failure_keeps_the_request_pending(self):
        tx = _tx()
        ok, msg, _debit, release = _approve(tx, debit_error=Exception("timed out"))
        self.assertFalse(ok)
        self.assertIn("stays pending", msg)
        self.assertEqual(tx.status, Transaction.Status.PENDING)
        release.assert_not_called()

    def test_an_auto_reject_that_cannot_release_keeps_the_request_pending(self):
        tx = _tx()
        ok, msg, _debit, _release = _approve(tx, debit_error=Exception("insufficient funds"), released=None)
        self.assertFalse(ok)
        self.assertIn("stays pending", msg)
        self.assertEqual(tx.status, Transaction.Status.PENDING)


class AvailableTests(SimpleTestCase):
    def test_only_what_old_requests_still_hold_in_the_balance_is_subtracted(self):
        self.assertEqual(tw.held_in_balance({"reservedWithdraw": 30}), Decimal("30"))
        self.assertEqual(tw.held_in_balance({"reservedWithdraw": "12.5"}), Decimal("12.5"))
        self.assertEqual(tw.held_in_balance({}), Decimal("0"))
        self.assertEqual(tw.held_in_balance(None), Decimal("0"))
        self.assertEqual(tw.held_in_balance({"reservedWithdraw": -4}), Decimal("0"))
        self.assertEqual(tw.held_in_balance({"reservedWithdraw": "x"}), Decimal("0"))

    def test_available_now_does_not_subtract_requests_already_out_of_the_balance(self):
        with mock.patch.object(tw, "live_allowed", return_value=(Decimal("100"), {"reservedWithdraw": 30}, "")):
            allowed, _snap, err = tw.available_now(SimpleNamespace(id=7))
        self.assertEqual(err, "")
        self.assertEqual(allowed, Decimal("70"))


class RequestTests(SimpleTestCase):
    def test_the_request_carries_its_comment(self):
        account = SimpleNamespace(mt5_account=SimpleNamespace(login_id="500145"), account_number="500145")
        with mock.patch("btrader_integration.services.reserve_btrader_withdrawal", return_value={"status": "DEBITED"}) as r:
            ok, _ = tw.reserve(account, Decimal("10"), "crm-withdraw-reserve-1", comment="CRM withdrawal #1")
        self.assertTrue(ok)
        r.assert_called_once_with(login="500145", amount=10.0, external_ref="crm-withdraw-reserve-1", comment="CRM withdrawal #1")

    def test_a_refused_request_tells_the_client_why(self):
        account = SimpleNamespace(mt5_account=SimpleNamespace(login_id="500145"), account_number="500145")
        with mock.patch("btrader_integration.services.reserve_btrader_withdrawal", side_effect=Exception("insufficient funds to reserve")):
            ok, msg = tw.reserve(account, Decimal("10"), "crm-withdraw-reserve-1")
        self.assertFalse(ok)
        self.assertEqual(msg, tw.INSUFFICIENT_MESSAGE)


class EngineCallTests(SimpleTestCase):
    def test_a_debited_request_and_a_refund_refresh_the_crm_copy_of_the_account(self):
        from btrader_integration import services

        client = mock.Mock()
        client.reserve_withdrawal.return_value = {"ok": True, "status": "DEBITED", "reserved": 0, "duplicate": False}
        client.release_withdrawal.return_value = {"ok": True, "released": True, "status": "RELEASED", "reserved": 0, "refunded": 10}
        with mock.patch.object(services, "_client_from_settings", return_value=client), \
                mock.patch.object(services, "_store_reserved"), \
                mock.patch.object(services, "sync_account") as sync:
            services.reserve_btrader_withdrawal(login="500145", amount=10, external_ref="r1", comment="CRM withdrawal #1")
            services.release_btrader_withdrawal(login="500145", external_ref="r1")
        client.reserve_withdrawal.assert_called_once_with("500145", 10, "r1", "CRM withdrawal #1")
        self.assertEqual(sync.call_count, 2)

    def test_an_old_hold_and_a_repeat_do_not_resync(self):
        from btrader_integration import services

        client = mock.Mock()
        client.reserve_withdrawal.side_effect = [
            {"ok": True, "status": "RESERVED", "reserved": 10, "duplicate": False},
            {"ok": True, "status": "DEBITED", "reserved": 0, "duplicate": True},
        ]
        with mock.patch.object(services, "_client_from_settings", return_value=client), \
                mock.patch.object(services, "_store_reserved"), \
                mock.patch.object(services, "sync_account") as sync:
            services.reserve_btrader_withdrawal(login="500145", amount=10, external_ref="r1")
            services.reserve_btrader_withdrawal(login="500145", amount=10, external_ref="r2")
        sync.assert_not_called()
