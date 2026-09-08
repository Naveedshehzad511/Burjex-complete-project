import calendar
from datetime import date, timedelta

from django.db.models import Count, Exists, OuterRef, Q, Sum
from django.db.models.functions import TruncDate
from django.db.utils import OperationalError
from django.utils import timezone

from accounts.models import BankDetails, Document, KYCAddress, KYCIdentity, MT5Account, User

from admin_panel.models import UserActivitySettings

from ib.models import IBRequest
from live_chat.models import SupportTicket
from transactions.models import Transaction


def _start_of_week(local_date):
    # Monday as start-of-week
    return local_date - timedelta(days=local_date.weekday())


def _add_months(d, n):
    # Safe month arithmetic without external dependencies
    month_index = (d.year * 12) + (d.month - 1) + n
    year = month_index // 12
    month = (month_index % 12) + 1
    last_day = calendar.monthrange(year, month)[1]
    day = min(d.day, last_day)
    return d.replace(year=year, month=month, day=day)


def get_admin_dashboard_metrics(from_date: date | None = None, to_date: date | None = None):
    now = timezone.localtime(timezone.now())
    today = now.date()
    week_start = _start_of_week(today)
    month_start = today.replace(day=1)
    has_range = bool(from_date and to_date and from_date <= to_date)
    range_start = from_date if has_range else None
    range_end_exclusive = (to_date + timedelta(days=1)) if has_range else None

    deposit_tx_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    withdraw_tx_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]

    user_qs = User.objects.all()
    tx_qs = Transaction.objects.all()
    ib_qs = IBRequest.objects.all()
    doc_qs = Document.objects.all()
    bank_qs = BankDetails.objects.all()
    if has_range:
        user_qs = user_qs.filter(date_joined__date__gte=range_start, date_joined__date__lt=range_end_exclusive)
        tx_qs = tx_qs.filter(created_at__date__gte=range_start, created_at__date__lt=range_end_exclusive)
        ib_qs = ib_qs.filter(requested_at__date__gte=range_start, requested_at__date__lt=range_end_exclusive)
        doc_qs = doc_qs.filter(uploaded_at__date__gte=range_start, uploaded_at__date__lt=range_end_exclusive)
        bank_qs = bank_qs.filter(created_at__date__gte=range_start, created_at__date__lt=range_end_exclusive)

    metrics = {
        "total_clients": user_qs.filter(role=User.Roles.CLIENT).count(),
        "total_ib": User.objects.filter(role=User.Roles.IB).count(),
        "pending_clients": user_qs.filter(role=User.Roles.CLIENT, kyc_status=User.KYCStatus.PENDING).count(),
        "active_traders": user_qs.filter(role=User.Roles.TRADER, mt5_accounts__status=MT5Account.Status.ACTIVE)
        .distinct()
        .count(),
        "ftd_users": user_qs.filter(ftd_user=True).count(),
        "non_ftd_users": user_qs.filter(ftd_user=False).count(),
        "pending_bank_details": bank_qs.filter(status=BankDetails.Status.PENDING).count(),
        "pending_documents": doc_qs.filter(status=Document.Status.PENDING).count(),
        "pending_ib_withdraw": tx_qs.filter(
            tx_type=Transaction.TxType.PENDING_IB_WITHDRAW, status=Transaction.Status.PENDING
        ).count(),
        "active_clients": user_qs.filter(role=User.Roles.CLIENT, is_active=True).count(),
    }

    # Global dashboard headline stats (not scoped by selected date range)
    metrics["total_active_clients"] = User.objects.filter(
        role=User.Roles.CLIENT,
        account_status=User.AccountStatus.APPROVED,
        is_active=True,
    ).count()
    metrics["total_live_mt5_accounts"] = MT5Account.objects.filter(
        account_type=MT5Account.AccountType.LIVE
    ).count()
    metrics["total_demo_mt5_accounts"] = MT5Account.objects.filter(
        account_type=MT5Account.AccountType.DEMO
    ).count()
    metrics["dashboard_pending_clients"] = User.objects.filter(role=User.Roles.CLIENT).filter(
        Q(account_status=User.AccountStatus.PENDING) | Q(kyc_status=User.KYCStatus.PENDING)
    ).count()
    # Headline cards: always all-time counts (independent of dashboard date filter)
    metrics["headline_total_clients"] = User.objects.filter(role=User.Roles.CLIENT).count()
    metrics["dashboard_total_users"] = User.objects.exclude(
        role__in=[User.Roles.ADMIN, User.Roles.BANKER]
    ).count()
    metrics["dashboard_total_ib"] = User.objects.filter(role=User.Roles.IB).count()

    # Main dashboard: active users (UserActivitySettings + optional django.conf.settings.active_days).
    _activity = UserActivitySettings.get_solo()
    _active_days_n = _activity.effective_active_days()
    _min_bal = _activity.effective_min_balance()
    _active_cutoff = now - timedelta(days=_active_days_n)
    _live_real_balance = MT5Account.objects.filter(
        user_id=OuterRef("pk"),
        account_type=MT5Account.AccountType.LIVE,
        balance__gte=_min_bal,
    )
    metrics["main_active_users"] = (
        User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER])
        .filter(last_login__isnull=False, last_login__gte=_active_cutoff)
        .filter(Exists(_live_real_balance))
        .count()
    )

    # Pending queues (always current backlog, not date-scoped)
    metrics["pending_deposit_global"] = Transaction.objects.filter(
        tx_type__in=[Transaction.TxType.PENDING_DEPOSIT, Transaction.TxType.CLIENT_DEPOSIT],
        status=Transaction.Status.PENDING,
    ).count()
    metrics["pending_withdraw_global"] = Transaction.objects.filter(
        tx_type__in=[
            Transaction.TxType.PENDING_WITHDRAW,
            Transaction.TxType.CLIENT_WITHDRAW,
            Transaction.TxType.WALLET_WITHDRAW,
            Transaction.TxType.PENDING_IB_WITHDRAW,
        ],
        status=Transaction.Status.PENDING,
    ).count()
    # Single source of truth for dashboard + pending-documents page:
    # same model and same scope (all non-admin/non-banker users), distinct users by status.
    kyc_docs = Document.objects.exclude(user__role__in=[User.Roles.ADMIN, User.Roles.BANKER])
    metrics["pending_kyc_queue"] = kyc_docs.filter(status=Document.Status.PENDING).values("user_id").distinct().count()
    metrics["approved_kyc"] = kyc_docs.filter(status=Document.Status.APPROVED).values("user_id").distinct().count()
    metrics["rejected_kyc"] = kyc_docs.filter(status=Document.Status.REJECTED).values("user_id").distinct().count()
    metrics["pending_ib_requests_queue"] = IBRequest.objects.filter(status=IBRequest.Status.PENDING).count()
    try:
        metrics["pending_tickets_queue"] = SupportTicket.objects.filter(
            status=SupportTicket.Status.PENDING
        ).count()
    except OperationalError:
        metrics["pending_tickets_queue"] = 0

    # --- Chart data (last N days) ---
    last7_start = range_start if has_range else (today - timedelta(days=6))
    last7_end_exclusive = range_end_exclusive if has_range else (today + timedelta(days=1))
    last14_start = range_start if has_range else (today - timedelta(days=13))
    last14_end_exclusive = range_end_exclusive if has_range else (today + timedelta(days=1))

    deposit_tx_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    withdraw_tx_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]

    def _series_for_amount(tx_type_list, start_dt, end_dt):
        qs = (
            Transaction.objects.filter(
                tx_type__in=tx_type_list,
                status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
                created_at__date__gte=start_dt,
                created_at__date__lt=end_dt,
            )
            .annotate(day=TruncDate("created_at"))
            .values("day")
            .annotate(total=Sum("amount"))
            .order_by("day")
        )
        by_day = {row["day"]: float(row["total"] or 0) for row in qs}
        labels = []
        values = []
        for i in range((end_dt - start_dt).days):
            d = start_dt + timedelta(days=i)
            labels.append(d.strftime("%Y-%m-%d"))
            values.append(by_day.get(d, 0.0))
        return labels, values

    def _build_daily_ranges(days_back):
        starts = []
        ends = []
        labels = []
        for i in range(days_back - 1, -1, -1):
            s = today - timedelta(days=i)
            e = s + timedelta(days=1)
            starts.append(s)
            ends.append(e)
            labels.append(s.strftime("%d %b"))
        return labels, starts, ends

    def _build_weekly_ranges(weeks_back):
        starts = []
        ends = []
        labels = []
        for i in range(weeks_back - 1, -1, -1):
            s = week_start - timedelta(days=7 * i)
            e = s + timedelta(days=7)
            starts.append(s)
            ends.append(min(e, today + timedelta(days=1)))
            labels.append(f"W{int(s.strftime('%W'))} {s.strftime('%b')}")
        return labels, starts, ends

    def _build_monthly_ranges(months_back):
        starts = []
        ends = []
        labels = []
        for i in range(months_back - 1, -1, -1):
            s = _add_months(month_start, -i)
            e = _add_months(s, 1)
            starts.append(s)
            ends.append(min(e, today + timedelta(days=1)))
            labels.append(s.strftime("%b %Y"))
        return labels, starts, ends

    def _series_from_ranges(tx_types, starts, ends, statuses=None):
        values = []
        for s, e in zip(starts, ends):
            qs = Transaction.objects.filter(
                tx_type__in=tx_types,
                created_at__date__gte=s,
                created_at__date__lt=e,
            )
            if statuses:
                qs = qs.filter(status__in=statuses)
            total = qs.aggregate(total=Sum("amount"))["total"] or 0
            values.append(float(total))
        return values

    def _count_series_from_ranges(model_qs, date_field, starts, ends):
        values = []
        date_lookup_gte = f"{date_field}__gte"
        date_lookup_lt = f"{date_field}__lt"
        for s, e in zip(starts, ends):
            values.append(model_qs.filter(**{date_lookup_gte: s, date_lookup_lt: e}).count())
        return values

    deposit_labels, deposit_values = _series_for_amount(deposit_tx_types, last7_start, last7_end_exclusive)
    _, withdraw_values = _series_for_amount(withdraw_tx_types, last7_start, last7_end_exclusive)
    _, ib_withdraw_values = _series_for_amount([Transaction.TxType.IB_WITHDRAW], last7_start, last7_end_exclusive)

    metrics["deposit_series_labels"] = deposit_labels
    metrics["deposit_series_values"] = deposit_values
    metrics["withdraw_series_values"] = withdraw_values
    metrics["ib_commission_series_values"] = ib_withdraw_values

    daily_labels, daily_starts, daily_ends = _build_daily_ranges(30)
    weekly_labels, weekly_starts, weekly_ends = _build_weekly_ranges(8)
    monthly_labels, monthly_starts, monthly_ends = _build_monthly_ranges(12)

    ib_pending_status = [Transaction.Status.PENDING]
    approved_or_completed = [Transaction.Status.COMPLETED, Transaction.Status.APPROVED]
    client_user_qs = User.objects.filter(role=User.Roles.CLIENT)

    metrics["deposit_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "values": _series_from_ranges(deposit_tx_types, daily_starts, daily_ends, approved_or_completed),
        },
        "weekly": {
            "labels": weekly_labels,
            "values": _series_from_ranges(deposit_tx_types, weekly_starts, weekly_ends, approved_or_completed),
        },
        "monthly": {
            "labels": monthly_labels,
            "values": _series_from_ranges(deposit_tx_types, monthly_starts, monthly_ends, approved_or_completed),
        },
    }
    metrics["withdraw_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "values": _series_from_ranges(withdraw_tx_types, daily_starts, daily_ends, approved_or_completed),
        },
        "weekly": {
            "labels": weekly_labels,
            "values": _series_from_ranges(withdraw_tx_types, weekly_starts, weekly_ends, approved_or_completed),
        },
        "monthly": {
            "labels": monthly_labels,
            "values": _series_from_ranges(withdraw_tx_types, monthly_starts, monthly_ends, approved_or_completed),
        },
    }
    metrics["ib_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "withdrawals": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], daily_starts, daily_ends, approved_or_completed),
            "payouts": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], daily_starts, daily_ends, approved_or_completed),
            "transfers": [float(v) for v in _count_series_from_ranges(
                Transaction.objects.filter(tx_type=Transaction.TxType.PENDING_IB_WITHDRAW, status__in=ib_pending_status),
                "created_at__date",
                daily_starts,
                daily_ends,
            )],
        },
        "weekly": {
            "labels": weekly_labels,
            "withdrawals": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], weekly_starts, weekly_ends, approved_or_completed),
            "payouts": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], weekly_starts, weekly_ends, approved_or_completed),
            "transfers": [float(v) for v in _count_series_from_ranges(
                Transaction.objects.filter(tx_type=Transaction.TxType.PENDING_IB_WITHDRAW, status__in=ib_pending_status),
                "created_at__date",
                weekly_starts,
                weekly_ends,
            )],
        },
        "monthly": {
            "labels": monthly_labels,
            "withdrawals": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], monthly_starts, monthly_ends, approved_or_completed),
            "payouts": _series_from_ranges([Transaction.TxType.IB_WITHDRAW], monthly_starts, monthly_ends, approved_or_completed),
            "transfers": [float(v) for v in _count_series_from_ranges(
                Transaction.objects.filter(tx_type=Transaction.TxType.PENDING_IB_WITHDRAW, status__in=ib_pending_status),
                "created_at__date",
                monthly_starts,
                monthly_ends,
            )],
        },
    }
    metrics["clients_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "values": _count_series_from_ranges(client_user_qs, "date_joined__date", daily_starts, daily_ends),
        },
        "weekly": {
            "labels": weekly_labels,
            "values": _count_series_from_ranges(client_user_qs, "date_joined__date", weekly_starts, weekly_ends),
        },
        "monthly": {
            "labels": monthly_labels,
            "values": _count_series_from_ranges(client_user_qs, "date_joined__date", monthly_starts, monthly_ends),
        },
    }
    metrics["volume_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "values": [
                round(d + w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["daily"]["values"],
                    metrics["withdraw_toggle_data"]["daily"]["values"],
                )
            ],
        },
        "weekly": {
            "labels": weekly_labels,
            "values": [
                round(d + w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["weekly"]["values"],
                    metrics["withdraw_toggle_data"]["weekly"]["values"],
                )
            ],
        },
        "monthly": {
            "labels": monthly_labels,
            "values": [
                round(d + w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["monthly"]["values"],
                    metrics["withdraw_toggle_data"]["monthly"]["values"],
                )
            ],
        },
    }

    # Clients growth (new client users per day)
    client_days = (
        User.objects.filter(
            role=User.Roles.CLIENT,
            date_joined__date__gte=last14_start,
            date_joined__date__lt=last14_end_exclusive,
        )
        .annotate(day=TruncDate("date_joined"))
        .values("day")
        .annotate(cnt=Count("id"))
        .order_by("day")
    )
    by_day_clients = {row["day"]: int(row["cnt"]) for row in client_days}
    growth_labels = []
    growth_values = []
    for i in range((last14_end_exclusive - last14_start).days):
        d = last14_start + timedelta(days=i)
        growth_labels.append(d.strftime("%Y-%m-%d"))
        growth_values.append(by_day_clients.get(d, 0))
    metrics["clients_growth_labels"] = growth_labels
    metrics["clients_growth_values"] = growth_values

    # Daily/Weekly/Monthly sums
    def _sum_amount(tx_types, start_date, end_date_exclusive):
        return (
            Transaction.objects.filter(
                tx_type__in=tx_types,
                status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
                created_at__date__gte=start_date,
                created_at__date__lt=end_date_exclusive,
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )

    def _count_tx(tx_types, start_date, end_date_exclusive, statuses=None):
        qs = Transaction.objects.filter(
            tx_type__in=tx_types,
            created_at__date__gte=start_date,
            created_at__date__lt=end_date_exclusive,
        )
        if statuses:
            qs = qs.filter(status__in=statuses)
        return qs.count()

    metrics["daily_deposit"] = _sum_amount(deposit_tx_types, today, today + timedelta(days=1))
    metrics["weekly_deposit"] = _sum_amount(deposit_tx_types, week_start, today + timedelta(days=1))
    metrics["monthly_deposit"] = _sum_amount(deposit_tx_types, month_start, _add_months(month_start, 1))
    metrics["deposit_period_labels"] = ["Daily", "Weekly", "Monthly"]
    metrics["deposit_period_values"] = [
        float(metrics["daily_deposit"] or 0),
        float(metrics["weekly_deposit"] or 0),
        float(metrics["monthly_deposit"] or 0),
    ]

    metrics["total_deposit"] = (
        tx_qs.filter(
            tx_type__in=deposit_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )

    metrics["daily_withdraw"] = _sum_amount(withdraw_tx_types, today, today + timedelta(days=1))
    metrics["weekly_withdraw"] = _sum_amount(withdraw_tx_types, week_start, today + timedelta(days=1))
    metrics["monthly_withdraw"] = _sum_amount(withdraw_tx_types, month_start, _add_months(month_start, 1))
    metrics["withdraw_period_labels"] = ["Daily", "Weekly", "Monthly"]
    metrics["withdraw_period_values"] = [
        float(metrics["daily_withdraw"] or 0),
        float(metrics["weekly_withdraw"] or 0),
        float(metrics["monthly_withdraw"] or 0),
    ]
    metrics["daily_ib_withdraw"] = _sum_amount([Transaction.TxType.IB_WITHDRAW], today, today + timedelta(days=1))
    metrics["weekly_ib_withdraw"] = _sum_amount([Transaction.TxType.IB_WITHDRAW], week_start, today + timedelta(days=1))
    metrics["monthly_ib_withdraw"] = _sum_amount([Transaction.TxType.IB_WITHDRAW], month_start, _add_months(month_start, 1))
    metrics["ib_withdraw_period_labels"] = ["Daily", "Weekly", "Monthly"]
    metrics["ib_withdraw_period_values"] = [
        float(metrics["daily_ib_withdraw"] or 0),
        float(metrics["weekly_ib_withdraw"] or 0),
        float(metrics["monthly_ib_withdraw"] or 0),
    ]
    metrics["ib_payout_period_values"] = list(metrics["ib_withdraw_period_values"])
    metrics["ib_transfer_request_period_values"] = [
        _count_tx(
            [Transaction.TxType.PENDING_IB_WITHDRAW],
            today,
            today + timedelta(days=1),
            statuses=[Transaction.Status.PENDING],
        ),
        _count_tx(
            [Transaction.TxType.PENDING_IB_WITHDRAW],
            week_start,
            today + timedelta(days=1),
            statuses=[Transaction.Status.PENDING],
        ),
        _count_tx(
            [Transaction.TxType.PENDING_IB_WITHDRAW],
            month_start,
            _add_months(month_start, 1),
            statuses=[Transaction.Status.PENDING],
        ),
    ]
    metrics["new_clients"] = sum(growth_values)
    metrics["clients_growth_period_labels"] = ["Daily", "Weekly", "Monthly"]
    today_clients = User.objects.filter(role=User.Roles.CLIENT, date_joined__date=today).count()
    weekly_clients = User.objects.filter(
        role=User.Roles.CLIENT,
        date_joined__date__gte=week_start,
        date_joined__date__lt=today + timedelta(days=1),
    ).count()
    monthly_clients = User.objects.filter(
        role=User.Roles.CLIENT,
        date_joined__date__gte=month_start,
        date_joined__date__lt=_add_months(month_start, 1),
    ).count()
    metrics["clients_growth_period_values"] = [today_clients, weekly_clients, monthly_clients]
    metrics["ib_registrations"] = ib_qs.count()
    metrics["today_deposits"] = _sum_amount(deposit_tx_types, today, today + timedelta(days=1))
    metrics["today_withdrawals"] = _sum_amount(withdraw_tx_types, today, today + timedelta(days=1))
    metrics["total_trading_accounts"] = MT5Account.objects.count()
    metrics["trading_volume"] = float(sum(deposit_values) + sum(withdraw_values))
    metrics["trading_volume_series_values"] = [round(d + w, 2) for d, w in zip(deposit_values, withdraw_values)]
    total_lots = float(metrics["trading_volume"] / 100000.0) if metrics["trading_volume"] else 0.0
    total_trades = Transaction.objects.filter(
        tx_type__in=deposit_tx_types + withdraw_tx_types,
        status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
    ).count()
    metrics["volume_proxy_labels"] = ["Trading Volume", "Total Lots", "Total Trades"]
    metrics["volume_proxy_values"] = [
        round(float(metrics["trading_volume"] or 0), 2),
        round(total_lots, 2),
        float(total_trades),
    ]

    metrics["total_withdraw"] = (
        tx_qs.filter(
            tx_type__in=withdraw_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    td_f = float(metrics["total_deposit"] or 0)
    tw_f = float(metrics["total_withdraw"] or 0)
    metrics["net_revenue"] = td_f - tw_f

    # Main dashboard cards: all-time real money (exclude demo ledger), not date-scoped
    _real_dep = (
        Transaction.objects.filter(
            tx_type__in=deposit_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
            is_demo_ledger=False,
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    _real_wd = (
        Transaction.objects.filter(
            tx_type__in=withdraw_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
            is_demo_ledger=False,
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )
    metrics["main_real_total_deposit"] = float(_real_dep)
    metrics["main_real_total_withdrawal"] = float(_real_wd)
    metrics["main_real_net_revenue"] = metrics["main_real_total_deposit"] - metrics["main_real_total_withdrawal"]

    _main_week_7_start = today - timedelta(days=6)

    def _sum_real_money(tx_types, start_date, end_date_exclusive):
        return float(
            Transaction.objects.filter(
                tx_type__in=tx_types,
                status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
                is_demo_ledger=False,
                created_at__date__gte=start_date,
                created_at__date__lt=end_date_exclusive,
            ).aggregate(total=Sum("amount"))["total"]
            or 0
        )

    metrics["main_real_today_deposit"] = _sum_real_money(deposit_tx_types, today, today + timedelta(days=1))
    metrics["main_real_weekly_deposit"] = _sum_real_money(
        deposit_tx_types, _main_week_7_start, today + timedelta(days=1)
    )
    metrics["main_real_today_withdrawal"] = _sum_real_money(withdraw_tx_types, today, today + timedelta(days=1))
    metrics["main_real_weekly_withdrawal"] = _sum_real_money(
        withdraw_tx_types, _main_week_7_start, today + timedelta(days=1)
    )
    # Dashboard "Total Revenue" headline (gross approved deposits — distinct from net row)
    metrics["total_revenue"] = td_f

    metrics["total_ib_withdraw"] = (
        tx_qs.filter(
            tx_type=Transaction.TxType.IB_WITHDRAW,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        ).aggregate(total=Sum("amount"))["total"]
        or 0
    )

    # IB Withdraw reports: show latest approved/completed for now
    metrics["ib_withdraw_reports"] = tx_qs.filter(
        tx_type=Transaction.TxType.IB_WITHDRAW,
        status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
    ).select_related("actor")[:50]

    # Recent list panels
    metrics["recent_transactions"] = (
        tx_qs.select_related("actor", "payment_gateway")
        .order_by("-created_at")
        .select_related("actor")[:10]
    )
    metrics["recent_clients"] = user_qs.filter(role=User.Roles.CLIENT).order_by("-date_joined")[:8]
    metrics["from_date"] = range_start.isoformat() if has_range else ""
    metrics["to_date"] = to_date.isoformat() if has_range else ""
    metrics["has_range"] = has_range

    # Canonical dashboard keys (templates / API)
    metrics["total_users"] = metrics["dashboard_total_users"]
    metrics["total_ib"] = metrics["dashboard_total_ib"]
    metrics["total_withdrawal"] = metrics["total_withdraw"]
    metrics["total_real_accounts"] = metrics["total_live_mt5_accounts"]
    metrics["total_demo_accounts"] = metrics["total_demo_mt5_accounts"]
    metrics["pending_deposit"] = metrics["pending_deposit_global"]
    metrics["pending_withdrawal"] = metrics["pending_withdraw_global"]
    metrics["pending_kyc"] = metrics["pending_kyc_queue"]
    metrics["pending_ib_requests"] = metrics["pending_ib_requests_queue"]

    # --- Professional analytics blocks ---
    metrics["deposits_vs_withdrawals_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "deposits": metrics["deposit_toggle_data"]["daily"]["values"],
            "withdrawals": metrics["withdraw_toggle_data"]["daily"]["values"],
        },
        "weekly": {
            "labels": weekly_labels,
            "deposits": metrics["deposit_toggle_data"]["weekly"]["values"],
            "withdrawals": metrics["withdraw_toggle_data"]["weekly"]["values"],
        },
        "monthly": {
            "labels": monthly_labels,
            "deposits": metrics["deposit_toggle_data"]["monthly"]["values"],
            "withdrawals": metrics["withdraw_toggle_data"]["monthly"]["values"],
        },
    }
    metrics["net_revenue_toggle_data"] = {
        "daily": {
            "labels": daily_labels,
            "values": [
                round(d - w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["daily"]["values"],
                    metrics["withdraw_toggle_data"]["daily"]["values"],
                )
            ],
        },
        "weekly": {
            "labels": weekly_labels,
            "values": [
                round(d - w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["weekly"]["values"],
                    metrics["withdraw_toggle_data"]["weekly"]["values"],
                )
            ],
        },
        "monthly": {
            "labels": monthly_labels,
            "values": [
                round(d - w, 2)
                for d, w in zip(
                    metrics["deposit_toggle_data"]["monthly"]["values"],
                    metrics["withdraw_toggle_data"]["monthly"]["values"],
                )
            ],
        },
    }

    method_rows = (
        tx_qs.filter(
            tx_type__in=deposit_tx_types + withdraw_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        )
        .values("payment_gateway__name")
        .annotate(total=Sum("amount"))
        .order_by("-total")
    )
    total_method_amount = sum(float(row["total"] or 0) for row in method_rows) or 0.0
    top_payment_methods = []
    for row in method_rows[:6]:
        amount = float(row["total"] or 0)
        pct = (amount / total_method_amount * 100.0) if total_method_amount > 0 else 0.0
        top_payment_methods.append(
            {
                "name": row["payment_gateway__name"] or "Unassigned",
                "amount": round(amount, 2),
                "percentage": round(pct, 2),
            }
        )
    metrics["top_payment_methods"] = top_payment_methods

    manager_qs = User.objects.filter(role__in=[User.Roles.IB, User.Roles.BANKER], is_active=True)
    manager_ids = list(manager_qs.values_list("id", flat=True))
    client_qs = User.objects.filter(role=User.Roles.CLIENT, referred_by_id__in=manager_ids)
    client_counts = {
        row["referred_by_id"]: int(row["cnt"] or 0)
        for row in client_qs.values("referred_by_id").annotate(cnt=Count("id"))
    }
    dep_by_manager = {
        row["actor__referred_by_id"]: float(row["total"] or 0)
        for row in tx_qs.filter(
            actor__role=User.Roles.CLIENT,
            actor__referred_by_id__in=manager_ids,
            tx_type__in=deposit_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        )
        .values("actor__referred_by_id")
        .annotate(total=Sum("amount"))
    }
    wd_by_manager = {
        row["actor__referred_by_id"]: float(row["total"] or 0)
        for row in tx_qs.filter(
            actor__role=User.Roles.CLIENT,
            actor__referred_by_id__in=manager_ids,
            tx_type__in=withdraw_tx_types,
            status__in=[Transaction.Status.COMPLETED, Transaction.Status.APPROVED],
        )
        .values("actor__referred_by_id")
        .annotate(total=Sum("amount"))
    }

    manager_performance = []
    for manager in manager_qs:
        dep = dep_by_manager.get(manager.id, 0.0)
        wd = wd_by_manager.get(manager.id, 0.0)
        pnl = dep - wd
        manager_performance.append(
            {
                "manager_id": manager.id,
                "name": manager.display_name() or manager.email or manager.username or f"Manager {manager.id}",
                "total_clients": client_counts.get(manager.id, 0),
                "total_deposits": round(dep, 2),
                "total_withdrawals": round(wd, 2),
                "net_pnl": round(pnl, 2),
            }
        )
    manager_performance.sort(key=lambda x: x["net_pnl"], reverse=True)
    max_abs_pnl = max([abs(row["net_pnl"]) for row in manager_performance], default=0.0)
    for row in manager_performance:
        row["pnl_abs"] = abs(row["net_pnl"])
        row["pnl_pct"] = round((row["pnl_abs"] / max_abs_pnl * 100.0), 2) if max_abs_pnl > 0 else 0.0
        row["is_profit"] = row["net_pnl"] >= 0
    metrics["manager_performance"] = manager_performance[:12]

    # Mini sparklines (last 7 daily buckets) for main stat cards
    spark_starts = daily_starts[-7:]
    spark_ends = daily_ends[-7:]
    metrics["stat_sparklines"] = {
        "total_users": [
            float(x)
            for x in _count_series_from_ranges(
                User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]),
                "date_joined__date",
                spark_starts,
                spark_ends,
            )
        ],
        "total_ib": [
            float(x)
            for x in _count_series_from_ranges(
                User.objects.filter(role=User.Roles.IB),
                "date_joined__date",
                spark_starts,
                spark_ends,
            )
        ],
        "total_deposit": [float(x) for x in metrics["deposit_toggle_data"]["daily"]["values"][-7:]],
        "total_revenue": [float(x) for x in metrics["deposit_toggle_data"]["daily"]["values"][-7:]],
        "total_withdrawal": [float(x) for x in metrics["withdraw_toggle_data"]["daily"]["values"][-7:]],
        "net_revenue": [float(x) for x in metrics["net_revenue_toggle_data"]["daily"]["values"][-7:]],
        "total_real_accounts": [
            float(x)
            for x in _count_series_from_ranges(
                MT5Account.objects.filter(account_type=MT5Account.AccountType.LIVE),
                "created_at__date",
                spark_starts,
                spark_ends,
            )
        ],
        "total_demo_accounts": [
            float(x)
            for x in _count_series_from_ranges(
                MT5Account.objects.filter(account_type=MT5Account.AccountType.DEMO),
                "created_at__date",
                spark_starts,
                spark_ends,
            )
        ],
    }

    return metrics

