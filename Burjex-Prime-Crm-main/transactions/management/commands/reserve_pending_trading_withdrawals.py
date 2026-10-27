"""One-time reconciliation: reserve the funds of trading-account withdrawal requests that were made BEFORE
reservations existed (they are PENDING in the CRM but hold nothing in the trading engine).

    python manage.py reserve_pending_trading_withdrawals            # dry run: reads, changes nothing
    python manage.py reserve_pending_trading_withdrawals --apply    # reserves what the funds allow

Requests are taken oldest first, per trading account, against the account's live withdrawable funds (the same
rule a new request meets). A request the funds can no longer cover is NOT reserved and is listed, so that an admin
can decide (reject it, or ask the client for a smaller amount). Nothing is rejected or approved here.

It is safe to run twice: the engine ignores a reservation reference it already has, so a request that is already
reserved is reported as such and changes nothing.
"""

from __future__ import annotations

from collections import defaultdict
from decimal import Decimal

from django.core.management.base import BaseCommand

from transactions import trading_withdraw as tw
from transactions.models import Transaction


class Command(BaseCommand):
    help = "Reserve the funds of PENDING trading-account withdrawal requests made before reservations existed."

    def add_arguments(self, parser):
        parser.add_argument("--apply", action="store_true", help="Really reserve. Without it nothing is changed.")

    def handle(self, *args, **opts):
        apply = bool(opts["apply"])
        pending = (
            Transaction.objects.filter(
                tx_type=Transaction.TxType.CLIENT_WITHDRAW,
                status=Transaction.Status.PENDING,
                trading_account__isnull=False,
            )
            .select_related("trading_account", "trading_account__mt5_account", "trading_account__mt5_account__group", "actor")
            .order_by("trading_account_id", "created_at", "id")
        )
        by_account: dict[int, list[Transaction]] = defaultdict(list)
        for tx in pending:
            by_account[tx.trading_account_id].append(tx)

        self.stdout.write(f"{'APPLY' if apply else 'DRY RUN'}: {pending.count()} pending trading-account request(s) on {len(by_account)} account(s).")
        counts = {"reserved": 0, "already": 0, "cannot": 0, "error": 0}
        problems: list[str] = []

        for txs in by_account.values():
            account = txs[0].trading_account
            login = tw.account_login(account)
            allowed, _snap, err = tw.live_allowed(account)
            if allowed is None:
                for tx in txs:
                    counts["error"] += 1
                    problems.append(f"#{tx.id} {tx.actor.email} acct {login} {tx.amount}: live balance unreadable ({err})")
                    self.stdout.write(f"  #{tx.id} acct {login} {tx.amount}: SKIPPED - live balance unreadable ({err})")
                continue
            remaining = allowed
            for tx in txs:
                amount = Decimal(str(tx.amount or 0))
                label = f"  #{tx.id} acct {login} {amount} ({tx.actor.email})"
                if amount > remaining:
                    counts["cannot"] += 1
                    problems.append(f"#{tx.id} {tx.actor.email} acct {login}: needs {amount}, only {max(Decimal('0'), remaining)} left")
                    self.stdout.write(f"{label}: CANNOT RESERVE - needs {amount}, only {max(Decimal('0'), remaining)} left")
                    continue
                remaining -= amount
                if not apply:
                    self.stdout.write(f"{label}: would reserve")
                    counts["reserved"] += 1
                    continue
                from btrader_integration.services import reserve_btrader_withdrawal

                try:
                    res = reserve_btrader_withdrawal(login=login, amount=float(amount), external_ref=tw.reservation_ref(tx)) or {}
                except Exception as exc:
                    if "insufficient" in str(exc).lower():
                        counts["cannot"] += 1
                        problems.append(f"#{tx.id} {tx.actor.email} acct {login}: the engine refused ({str(exc)[:160]})")
                        self.stdout.write(f"{label}: CANNOT RESERVE - the engine refused")
                    else:
                        counts["error"] += 1
                        problems.append(f"#{tx.id} {tx.actor.email} acct {login}: error ({str(exc)[:160]})")
                        self.stdout.write(f"{label}: ERROR - {str(exc)[:160]}")
                    continue
                if res.get("duplicate"):
                    counts["already"] += 1
                    self.stdout.write(f"{label}: already reserved ({res.get('status')})")
                else:
                    counts["reserved"] += 1
                    self.stdout.write(f"{label}: RESERVED")

        verb = "reserved" if apply else "would be reserved"
        self.stdout.write(
            f"\nSummary: {counts['reserved']} {verb}, {counts['already']} already reserved, "
            f"{counts['cannot']} cannot be reserved, {counts['error']} skipped/error."
        )
        if problems:
            self.stdout.write("\nNeeds an admin decision (left pending, nothing reserved):")
            for line in problems:
                self.stdout.write(f"  - {line}")
        if not apply:
            self.stdout.write("\nDry run only. Re-run with --apply to reserve.")
