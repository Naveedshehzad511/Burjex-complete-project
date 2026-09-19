"""CRM Cashback admin: enable/disable, add/edit/delete alias rates, totals."""

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
from admin_panel.models import CashbackPayout, CashbackRate, CashbackSettings
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


def _clean_alias(raw) -> str:
    return (raw or "").strip()[:64]


def _suggested_aliases(saved_lower: set[str]) -> tuple[list[str], str]:
    aliases, symbol_err = list_btrader_engine_symbols()
    names: list[str] = []
    seen: set[str] = set()
    for name in aliases:
        key = (name or "").strip()
        if not key:
            continue
        lk = key.lower()
        if lk in seen or lk in saved_lower:
            continue
        seen.add(lk)
        names.append(key)
    return names, symbol_err


def _upsert_rate(alias_s: str, amount: Decimal, user) -> CashbackRate:
    row = CashbackRate.objects.filter(alias__iexact=alias_s).first()
    if row:
        row.alias = alias_s
        row.amount_usd = amount
        row.updated_by = user
        row.save(update_fields=["alias", "amount_usd", "updated_by", "updated_at"])
        CashbackRate.objects.filter(alias__iexact=alias_s).exclude(pk=row.pk).delete()
        return row
    return CashbackRate.objects.create(alias=alias_s, amount_usd=amount, updated_by=user)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def cashback_admin(request):
    cfg = CashbackSettings.get_solo()

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "toggle":
            enabled_raw = (request.POST.get("enabled") or "").strip().lower()
            cfg.enabled = enabled_raw in {"1", "on", "true", "yes", "enable", "enabled"}
            cfg.updated_by = request.user
            cfg.save(update_fields=["enabled", "updated_by", "updated_at"])
            messages.success(request, "Cashback enabled." if cfg.enabled else "Cashback disabled.")
            return redirect(reverse("admin-cashback"))

        if action == "add":
            alias_s = _clean_alias(request.POST.get("alias"))
            amount = _parse_amount(request.POST.get("amount"))
            if not alias_s:
                messages.error(request, "Enter a symbol to add.")
                return redirect(reverse("admin-cashback"))
            _upsert_rate(alias_s, amount, request.user)
            messages.success(request, f"Cashback saved for {alias_s}.")
            return redirect(reverse("admin-cashback"))

        if action == "update":
            try:
                pk = int(request.POST.get("rate_id") or 0)
            except (TypeError, ValueError):
                pk = 0
            row = CashbackRate.objects.filter(pk=pk).first()
            alias_s = _clean_alias(request.POST.get("alias")) or (row.alias if row else "")
            amount = _parse_amount(request.POST.get("amount"))
            if not row or not alias_s:
                messages.error(request, "Could not update that symbol.")
                return redirect(reverse("admin-cashback"))
            clash = CashbackRate.objects.filter(alias__iexact=alias_s).exclude(pk=row.pk).first()
            if clash:
                messages.error(request, f"{alias_s} already has a cashback rate.")
                return redirect(reverse("admin-cashback"))
            row.alias = alias_s
            row.amount_usd = amount
            row.updated_by = request.user
            row.save(update_fields=["alias", "amount_usd", "updated_by", "updated_at"])
            messages.success(request, f"Cashback updated for {alias_s}.")
            return redirect(reverse("admin-cashback"))

        if action == "delete":
            try:
                pk = int(request.POST.get("rate_id") or 0)
            except (TypeError, ValueError):
                pk = 0
            row = CashbackRate.objects.filter(pk=pk).first()
            if row:
                alias_s = row.alias
                row.delete()
                messages.success(request, f"Removed cashback for {alias_s}.")
            else:
                messages.error(request, "That symbol was already removed.")
            return redirect(reverse("admin-cashback"))

        messages.error(request, "Unknown cashback action.")
        return redirect(reverse("admin-cashback"))

    saved = list(CashbackRate.objects.order_by("alias"))
    saved_lower = {r.alias.lower() for r in saved}
    suggested, symbol_err = _suggested_aliases(saved_lower)

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
            "cashback_enabled": cfg.enabled,
            "saved_rates": saved,
            "suggested": suggested,
            "symbol_err": symbol_err,
            "total_paid": total_paid,
            "top_clients": top_clients,
            "payout_count": CashbackPayout.objects.count(),
        },
    )
