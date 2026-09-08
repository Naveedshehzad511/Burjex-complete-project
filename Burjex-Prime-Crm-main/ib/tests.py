from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from django.utils import timezone

from accounts.models import User
from admin_panel.models import TradingAccountType
from transactions.models import Transaction, InternalTransfer
from ib.models import IBPlan, IBPlanSymbolRebate
from ib.services import get_rebate_rate
from user_portal.views import _ib_wallet_balance_for_user

User = get_user_model()


class IBModuleTests(TestCase):
    def setUp(self):
        # Create standard test objects
        self.plan = IBPlan.objects.create(name="Plan Alpha", is_active=True)
        self.account_type = TradingAccountType.objects.create(
            account_name="Standard", 
            account_code="STD", 
            is_active=True
        )
        
        # Setup test IB user
        self.ib_user = User.objects.create_user(
            username="ib_tester",
            email="ib@example.com",
            role=User.Roles.IB,
            password="testpassword123"
        )
        
        # Setup test referred client
        self.client_user = User.objects.create_user(
            username="client_tester",
            email="client@example.com",
            role=User.Roles.CLIENT,
            password="testpassword123"
        )

    def test_get_rebate_rate_exact_and_suffix(self):
        # 1. Base rule: XAUUSD -> $5.00
        IBPlanSymbolRebate.objects.create(
            plan=self.plan,
            symbol="XAUUSD",
            rebate_per_lot=Decimal("5.0000"),
            is_active=True
        )
        
        # 2. Specific rule: EURUSD with Standard account type -> $4.00
        IBPlanSymbolRebate.objects.create(
            plan=self.plan,
            symbol="EURUSD",
            account_type=self.account_type,
            rebate_per_lot=Decimal("4.0000"),
            is_active=True
        )
        
        # 3. Fallback rule: EURUSD without account type -> $2.00
        IBPlanSymbolRebate.objects.create(
            plan=self.plan,
            symbol="EURUSD",
            account_type=None,
            rebate_per_lot=Decimal("2.0000"),
            is_active=True
        )

        # Test exact match
        rate = get_rebate_rate(self.plan, "XAUUSD")
        self.assertEqual(rate, Decimal("5.0000"))

        # Test suffix match (stripping .S, .R, etc.)
        rate_suffix = get_rebate_rate(self.plan, "XAUUSD.S")
        self.assertEqual(rate_suffix, Decimal("5.0000"))

        # Test account type override
        rate_override = get_rebate_rate(self.plan, "EURUSD", self.account_type)
        self.assertEqual(rate_override, Decimal("4.0000"))

        # Test fallback when no account type matches
        rate_fallback = get_rebate_rate(self.plan, "EURUSD")
        self.assertEqual(rate_fallback, Decimal("2.0000"))

        # Test unmatched symbol
        rate_unmatched = get_rebate_rate(self.plan, "GBPUSD")
        self.assertEqual(rate_unmatched, Decimal("0.0000"))

    def test_ib_wallet_balance_calculation(self):
        # Credit commission (Inflow of $150.00)
        Transaction.objects.create(
            tx_type=Transaction.TxType.IB_WITHDRAW,
            status=Transaction.Status.COMPLETED,
            actor=self.ib_user,
            from_user=self.client_user,
            to_user=self.ib_user,
            amount=Decimal("150.00"),
            currency="USD",
            reference="COMMISSION_CREDIT_1",
            processed_at=timezone.now()
        )

        # Pending withdrawal request (Outflow hold of $30.00)
        Transaction.objects.create(
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
            status=Transaction.Status.PENDING,
            actor=self.ib_user,
            amount=Decimal("30.00"),
            currency="USD",
            reference="Withdrawal: BANK",
            account_details="Bank Details"
        )

        # Internal transfer out from IB Wallet to MT5 (Outflow of $20.00)
        InternalTransfer.objects.create(
            user=self.ib_user,
            transfer_type=InternalTransfer.TransferType.IB_TO_TRADING,
            from_account="IB_WALLET",
            to_account="MT5_123456",
            amount=Decimal("20.00"),
            status=InternalTransfer.Status.APPROVED,
            processed_at=timezone.now()
        )

        # Rejected withdrawal request (No effect on balance)
        Transaction.objects.create(
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW,
            status=Transaction.Status.REJECTED,
            actor=self.ib_user,
            amount=Decimal("50.00"),
            currency="USD",
            reference="Withdrawal: CRYPTO",
            reject_reason="Invalid address"
        )

        # Calculate expected balance: 150.00 - 30.00 (pending hold) - 20.00 (internal transfer) = 100.00
        balance = _ib_wallet_balance_for_user(self.ib_user)
        self.assertEqual(balance, Decimal("100.00"))
