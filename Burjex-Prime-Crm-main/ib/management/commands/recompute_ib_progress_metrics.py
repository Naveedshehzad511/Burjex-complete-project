"""
Rebuild IBProgressMetrics.all_time_* from historical data.

Referrals and team deposits are recomputed from IBRequest / Transaction.
Trade volume (lots) is inferred from completed IB_WITHDRAW rows that include
`lots=` in notes (same shape as distribute_trade_commission), deduped per
commission reference so Sub+Master splits do not double-count.
Rolling daily/weekly/monthly buckets are zeroed and anchored to the current date.
"""

from __future__ import annotations

import re
from datetime import timedelta
from decimal import Decimal

from django.core.management.base import BaseCommand
from django.db.models import Sum
from django.utils import timezone

from accounts.models import User
from transactions.models import Transaction

from ib.models import IBProfile, IBProgressMetrics, IBRequest

LOT_RE = re.compile(r"lots=([\d.]+)", re.I)
VOL_RE = re.compile(r"volume=([\d.]+)", re.I)


def _team_client_ids(ib_user_id: int) -> list[int]:
    return list(
        IBRequest.objects.filter(ib_user_id=ib_user_id, status=IBRequest.Status.APPROVED)
        .values_list("client_user_id", flat=True)
        .distinct()
    )


def _attribution_master_for_client(client_user_id: int) -> User | None:
    link = (
        IBRequest.objects.filter(client_user_id=client_user_id, status=IBRequest.Status.APPROVED)
        .select_related("ib_user")
        .order_by("-processed_at", "-requested_at")
        .first()
    )
    if not link or not link.ib_user_id:
        return None
    return link.ib_user


class Command(BaseCommand):
    help = "Recompute IBProgressMetrics for master IBs (all-time fields + reset rolling windows)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--queue-upgrades",
            action="store_true",
            help="After metrics refresh, run maybe_queue_level_upgrade for each master IB.",
        )

    def handle(self, *args, **options):
        queue_upgrades = options["queue_upgrades"]
        now = timezone.localdate()
        week_start = now - timedelta(days=now.weekday())
        month_start = now.replace(day=1)

        master_ids = list(
            IBProfile.objects.values_list("user_id", flat=True)
        )
        if not master_ids:
            self.stdout.write(self.style.WARNING("No master IB profiles found."))
            return

        # Aggregate lots/volume per master from IB commission transactions (dedupe by reference).
        lots_by_master: dict[int, Decimal] = {mid: Decimal("0") for mid in master_ids}
        vol_by_master: dict[int, Decimal] = {mid: Decimal("0") for mid in master_ids}
        seen_keys: set[tuple[int, str]] = set()

        payout_qs = Transaction.objects.filter(
            tx_type=Transaction.TxType.IB_WITHDRAW,
            status__in=[Transaction.Status.APPROVED, Transaction.Status.COMPLETED],
            from_user_id__isnull=False,
        ).exclude(notes="")

        for tx in payout_qs.iterator(chunk_size=500):
            master = _attribution_master_for_client(tx.from_user_id)
            if not master or master.id not in lots_by_master:
                continue
            ref = (tx.reference or "").strip() or str(tx.id)
            key = (master.id, ref)
            if key in seen_keys:
                continue
            m_lot = LOT_RE.search(tx.notes or "")
            if not m_lot:
                continue
            seen_keys.add(key)
            try:
                lot_val = Decimal(m_lot.group(1))
            except Exception:
                lot_val = Decimal("0")
            lots_by_master[master.id] += lot_val
            m_vol = VOL_RE.search(tx.notes or "")
            if m_vol:
                try:
                    vol_by_master[master.id] += Decimal(m_vol.group(1))
                except Exception:
                    pass

        dep_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
        done_status = [Transaction.Status.APPROVED, Transaction.Status.COMPLETED]

        updated = 0
        for mid in master_ids:
            team_ids = _team_client_ids(mid)
            n_refs = len(team_ids)
            dep_total = Decimal("0")
            if team_ids:
                dep_total = (
                    Transaction.objects.filter(
                        actor_id__in=team_ids,
                        tx_type__in=dep_types,
                        status__in=done_status,
                    ).aggregate(t=Sum("amount"))["t"]
                    or Decimal("0")
                )

            IBProgressMetrics.objects.update_or_create(
                ib_user_id=mid,
                defaults={
                    "all_time_lots": lots_by_master.get(mid, Decimal("0")),
                    "all_time_volume": vol_by_master.get(mid, Decimal("0")),
                    "all_time_team_deposit": dep_total,
                    "referral_count": n_refs,
                    "daily_lots": Decimal("0"),
                    "daily_volume": Decimal("0"),
                    "daily_team_deposit": Decimal("0"),
                    "daily_referrals": 0,
                    "daily_period": now,
                    "weekly_lots": Decimal("0"),
                    "weekly_volume": Decimal("0"),
                    "weekly_team_deposit": Decimal("0"),
                    "weekly_referrals": 0,
                    "week_start": week_start,
                    "monthly_lots": Decimal("0"),
                    "monthly_volume": Decimal("0"),
                    "monthly_team_deposit": Decimal("0"),
                    "monthly_referrals": 0,
                    "month_start": month_start,
                },
            )
            updated += 1

        self.stdout.write(self.style.SUCCESS(f"Updated IBProgressMetrics for {updated} master IB(s)."))

        if queue_upgrades:
            from ib.level_progress import maybe_queue_level_upgrade

            for mid in master_ids:
                u = User.objects.filter(id=mid).first()
                if u:
                    maybe_queue_level_upgrade(u)
            self.stdout.write(self.style.SUCCESS("Queued level upgrades where eligible."))
