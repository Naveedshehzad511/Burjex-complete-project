"""CRM Cashback admin: alias rates from symbol groups, total paid, top 5 clients."""

from __future__ import annotations

from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Sum
from django.shortcuts import redirect, render
from django.urls import reverse
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.models import CashbackPayout, CashbackRate
from btrader_integration.services import list_btrader_engine_symbols

_CENT = Decimal("0.01")


def _parse_amount(raw) -> Decimal:
    try:
        val = Decimal(str(raw or "0").strip() or "0")
    except (InvalidOperation, ValueError, TypeError):
        return Decimal("0")
    if val < 0:
        val = Decimal("0")
    return val.quantize(_CENT, rounding=ROUND_HALF_UP)


def _alias_list() -> tuple[list[str], str]:
    aliases, symbol_err = list_btrader_engine_symbols()
    names: list[str] = []
    seen: set[str] = set()
    for name in aliases:
        key = (name or "").strip()
        if not key:
            continue
        lk = key.lower()
        if lk in seen:
            continue
        seen.add(lk)
        names.append(key)
    for row in CashbackRate.objects.order_by("alias"):
        lk = row.alias.lower()
        if lk not in seen:
            seen.add(lk)
            names.append(row.alias)
    return names, symbol_err


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def cashback_admin(request):
    names, symbol_err = _alias_list()

    if request.method == "POST":
        posted = request.POST.getlist("alias")
        amounts = request.POST.getlist("amount")
        for alias, raw in zip(posted, amounts):
            alias_s = (alias or "").strip()[:64]
            if not alias_s:
                continue
            amount = _parse_amount(raw)
            CashbackRate.objects.update_or_create(
                alias=alias_s,
                defaults={"amount_usd": amount, "updated_by": request.user},
            )
            CashbackRate.objects.filter(alias__iexact=alias_s).exclude(alias=alias_s).delete()
        messages.success(request, "Cashback rates saved.")
        return redirect(reverse("admin-cashback"))

    rates_by_alias = {r.alias.lower(): r for r in CashbackRate.objects.all()}
    rows = [
        {
            "alias": alias,
            "amount": rates_by_alias[alias.lower()].amount_usd if alias.lower() in rates_by_alias else Decimal("0.00"),
        }
        for alias in names
    ]

    total_paid = CashbackPayout.objects.aggregate(s=Sum("amount"))["s"] or Decimal("0")
    top_clients = list(
        CashbackPayout.objects.values("user_id", "user__email", "user__username")
        .annotate(total=Sum("amount"))
        .order_by("-total")[:5]
    )

    return render(
        request,
        "admin_panel/cashback.html",
        {
            "rows": rows,
            "symbol_err": symbol_err,
            "total_paid": total_paid,
            "top_clients": top_clients,
            "payout_count": CashbackPayout.objects.count(),
        },
    )
