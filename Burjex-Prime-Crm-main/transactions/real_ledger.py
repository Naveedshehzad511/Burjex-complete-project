"""Filter transaction querysets to real-money rows (exclude demo ledger)."""

from __future__ import annotations

from django.db.models import Q

from transactions.models import Transaction


def real_ledger_q() -> Q:
    return Q(is_demo_ledger=False)


def filter_real_ledger_transactions(qs):
    """Restrict a Transaction queryset to non-demo ledger rows."""
    return qs.filter(is_demo_ledger=False)


def filter_real_internal_transfers(qs, user):
    """Real-money internal transfers for the portal (exclude demo routing if present)."""
    # Demo-specific flows use account labels containing DEMO in some setups.
    return qs.exclude(
        Q(from_account__icontains="DEMO_MT5") | Q(to_account__icontains="DEMO_MT5")
    )
