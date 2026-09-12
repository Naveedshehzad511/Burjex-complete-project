"""Symbol groups, trading symbols (import), IB trade simulator, structured IB commission matrix."""

from __future__ import annotations

from decimal import Decimal

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Q
from django.http import HttpResponse, JsonResponse
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils.text import slugify
from django.views.decorators.http import require_GET, require_http_methods

from accounts.models import MT5Group, User
from accounts.permissions import role_required

from ib.commission_engine import apply_level_caps, resolve_ib_commission_for_trade
from ib.models import IBCommissionMatrixRule, IBLevel, IBProfile, IBRequest

from admin_panel.models import TradingPlatformIntegration
from mt5_integration.client import MT5Client



from .models import (
    BrokerCrmCommissionSettings,
    CrmGroupSymbol,
    SimulatedIBTrade,
    SymbolGroup,
    TradingAccountType,
    TradingSymbol,
)
from ib.services import _effective_percentage


def _suffix_token(suffix: str) -> str:
    """
    Convert stored suffix into a token used for grouping.
    Examples:
      "" -> "STANDARD"
      ".ecn" -> "ECN"
    """
    s = (suffix or "").strip()
    if s.startswith("."):
        s = s[1:]
    if not s:
        return "STANDARD"
    return s.upper()


def _pretty_group_name(token: str) -> str:
    if token.upper() == "STANDARD":
        return "Standard"
    return token.upper()


def _target_symbol_group_for_suffix(suffix: str) -> SymbolGroup | None:
    """
    Find (or auto-create) a SymbolGroup based on TradingSymbol suffix.
    We align group names with account-type naming conventions (ECN / RAW / Standard).
    """
    token = _suffix_token(suffix)
    pretty = _pretty_group_name(token)

    g = SymbolGroup.objects.filter(name__iexact=pretty).first()
    if g:
        return g

    g = SymbolGroup.objects.filter(slug=slugify(pretty)[:120]).first()
    if g:
        return g

    # Auto-create only if there's a matching TradingAccountType (or token is STANDARD).
    acc = TradingAccountType.objects.filter(account_code__iexact=token).first()
    if not acc:
        acc = TradingAccountType.objects.filter(account_name__iexact=pretty).first()
    if token != "STANDARD" and not acc:
        return None

    slug = slugify(pretty)[:120] or "group"
    base = slug
    n = 0
    while SymbolGroup.objects.filter(slug=slug).exists():
        n += 1
        slug = f"{base}-{n}"
    g = SymbolGroup.objects.create(name=pretty, slug=slug)
    return g


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_GET
def crm_group_symbols_json(request):
    """Symbols synced for a CRM group (MT5Group id) — for IB matrix / admin pickers. Returns all if no ID."""
    raw = (request.GET.get("mt5_group_id") or "").strip()
    if raw and raw.isdigit():
        syms = list(
            CrmGroupSymbol.objects.filter(mt5_group_id=int(raw))
            .order_by("symbol_name")
            .values_list("symbol_name", flat=True)
        )
    else:
        syms = list(
            CrmGroupSymbol.objects.values_list("symbol_name", flat=True)
            .distinct()
            .order_by("symbol_name")
        )
    return JsonResponse({"symbols": syms, "error": ""})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_GET
def btrader_engine_symbols_json(_request):
    """BTrader engine symbols the broker created (XAUUSD.s), not LP feed names."""
    from btrader_integration.services import list_btrader_engine_symbols

    symbols, err = list_btrader_engine_symbols()
    return JsonResponse({"symbols": symbols, "error": err or ""})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def symbol_groups_admin(request):
    if request.method == "POST":
        messages.error(
            request,
            "Manual symbol groups are disabled. Use CRM groups under Group Management; symbols sync from the platform.",
        )
        return redirect("admin-symbol-groups")
    rows = SymbolGroup.objects.all().order_by("name")
    return render(request, "admin_panel/symbol_groups.html", {"rows": rows, "read_only": True})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_symbols_admin(request):
    if request.method == "POST":
        messages.error(
            request,
            "Manual symbol creation is disabled. Open Group Management, map each CRM group to a platform group, then use Sync symbols.",
        )
        return redirect("admin-trading-symbols")

    sym_q = (request.GET.get("sym_q") or "").strip()
    qs = CrmGroupSymbol.objects.select_related("mt5_group").order_by("mt5_group__crm_group_name", "symbol_name")
    if sym_q:
        qs = qs.filter(symbol_name__icontains=sym_q.upper())
    synced_rows = list(qs[:2000])
    legacy_count = TradingSymbol.objects.count()
    return render(
        request,
        "admin_panel/trading_symbols.html",
        {
            "synced_rows": synced_rows,
            "sym_q": sym_q,
            "legacy_count": legacy_count,
            "group_management_url": reverse("admin-groups"),
            "read_only": True,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_GET
def trading_symbols_export_sample(_request):
    response = HttpResponse(
        "Symbol,Name,Type,Suffix,Digits,ContractSize\nEURUSD,Euro Dollar,FOREX,,5,100000\nXAUUSD.PRO,Gold,Metal,.PRO,2,100\n",
        content_type="text/csv",
    )
    response["Content-Disposition"] = 'attachment; filename="symbols_sample.csv"'
    return response


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def ib_commission_matrix_admin(request):
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "add":
            lid = (request.POST.get("ib_level_id") or "").strip()
            if not lid.isdigit():
                messages.error(request, "IB level is required.")
            else:
                def _nid(k: str):
                    v = (request.POST.get(k) or "").strip()
                    return int(v) if v.isdigit() else None

                rule_kind = (request.POST.get("rule_kind") or "crm").strip().lower()
                if rule_kind == "btrader":
                    sym_name = (request.POST.get("matrix_symbol_name") or "").strip()[:64]
                    if not sym_name:
                        messages.error(request, "Please select a BTrader symbol.")
                    else:
                        try:
                            rebate = Decimal(str(request.POST.get("value") or 0))
                        except Exception:
                            rebate = Decimal("0")
                        IBCommissionMatrixRule.objects.create(
                            ib_level_id=int(lid),
                            platform=IBCommissionMatrixRule.Platform.BTRADER,
                            mt5_crm_group_id=None,
                            matrix_symbol_name=sym_name,
                            commission_mode=IBCommissionMatrixRule.CommissionMode.FIXED_PER_LOT,
                            value=rebate,
                            priority=int(request.POST.get("priority") or 0),
                        )
                        messages.success(request, f"BTrader rebate saved: ${rebate} per 1.00 lot on {sym_name}.")
                elif rule_kind == "crm":
                    sym_name = (request.POST.get("matrix_symbol_name") or "").strip()[:64]
                    if not sym_name:
                        messages.error(request, "Please select a specific Symbol for the rule.")
                    else:
                        IBCommissionMatrixRule.objects.create(
                            ib_level_id=int(lid),
                            platform=IBCommissionMatrixRule.Platform.MT5,
                            account_type_id=_nid("account_type_id"),
                            mt5_crm_group_id=None,
                            matrix_symbol_name=sym_name,
                            commission_mode=request.POST.get("commission_mode")
                            or IBCommissionMatrixRule.CommissionMode.PERCENT,
                            value=Decimal(str(request.POST.get("value") or 0)),
                            priority=int(request.POST.get("priority") or 0),
                        )
                        messages.success(request, "MT5 rule added.")
                else:
                    IBCommissionMatrixRule.objects.create(
                        ib_level_id=int(lid),
                        platform=IBCommissionMatrixRule.Platform.MT5,
                        account_type_id=_nid("account_type_id"),
                        symbol_group_id=_nid("symbol_group_id"),
                        trading_symbol_id=_nid("trading_symbol_id"),
                        commission_mode=request.POST.get("commission_mode")
                        or IBCommissionMatrixRule.CommissionMode.PERCENT,
                        value=Decimal(str(request.POST.get("value") or 0)),
                        priority=int(request.POST.get("priority") or 0),
                    )
                    messages.success(request, "Legacy rule added.")
        elif action == "delete":
            IBCommissionMatrixRule.objects.filter(id=request.POST.get("id")).delete()
            messages.success(request, "Rule removed.")
        q = (request.POST.get("return_qs") or "").strip()
        return redirect(f"{reverse('admin-ib-commission-matrix')}?{q}" if q else reverse("admin-ib-commission-matrix"))

    level_id = (request.GET.get("level") or "").strip()
    sym_q = (request.GET.get("sym_q") or "").strip()
    rules = IBCommissionMatrixRule.objects.select_related(
        "ib_level", "account_type", "symbol_group", "trading_symbol", "mt5_crm_group"
    ).order_by("-priority", "id")
    if level_id.isdigit():
        rules = rules.filter(ib_level_id=int(level_id))
    sym_list = TradingSymbol.objects.select_related("group").order_by("code", "suffix")
    if sym_q:
        sym_list = sym_list.filter(Q(code__icontains=sym_q) | Q(suffix__icontains=sym_q))
    sym_list = sym_list[:400]

    selected_level = IBLevel.objects.filter(id=int(level_id)).first() if level_id.isdigit() else None
    return render(
        request,
        "admin_panel/ib_commission_matrix.html",
        {
            "rules": rules,
            "levels": IBLevel.objects.order_by("sequence"),
            "account_types": TradingAccountType.objects.order_by("account_name"),
            "groups": SymbolGroup.objects.order_by("name"),
            "symbols": sym_list,
            "modes": IBCommissionMatrixRule.CommissionMode.choices,
            "selected_level": selected_level,
            "level_filter": level_id,
            "sym_q": sym_q,
            "crm_groups": MT5Group.objects.filter(is_active=True).order_by("crm_group_name", "name"),
            "crm_symbols_json_url": reverse("admin-crm-group-symbols-json"),
            "btrader_symbols_json_url": reverse("admin-btrader-engine-symbols-json"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trade_simulator_admin(request):
    crm_comm = BrokerCrmCommissionSettings.get_solo()
    clients = User.objects.filter(role=User.Roles.CLIENT).order_by("email")[:2000]
    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")
    symbol_codes = list(
        CrmGroupSymbol.objects.values_list("symbol_name", flat=True).distinct().order_by("symbol_name")[:800]
    )
    if not symbol_codes:
        symbol_codes = [
            s.mt5_symbol
            for s in TradingSymbol.objects.filter(is_active=True).order_by("code", "suffix")[:500]
        ]
    account_types = TradingAccountType.objects.filter(is_active=True).order_by("account_name")
    recent = SimulatedIBTrade.objects.select_related("client", "ib_user", "account_type").order_by("-created_at")[:30]

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        client_id = request.POST.get("client_id")
        client = User.objects.filter(id=client_id).first()
        if not client:
            messages.error(request, "Select a client user.")
            return redirect("admin-ib-trade-simulator")
        ib_user = User.objects.filter(id=request.POST.get("ib_user_id") or 0).first()
        if not ib_user and client.referred_by_id and client.referred_by.role == User.Roles.IB:
            ib_user = client.referred_by
        sym_code = (request.POST.get("symbol") or "").strip()
        lots = Decimal(str(request.POST.get("lots") or 0))
        profit_per_lot = Decimal(str(request.POST.get("profit_per_lot") or 0))
        commission_per_lot = Decimal(str(request.POST.get("commission_per_lot") or 0))
        at_id = request.POST.get("account_type_id") or ""
        account_type = TradingAccountType.objects.filter(id=at_id).first() if at_id else None

        gross = lots * profit_per_lot
        client_charge = lots * commission_per_lot if crm_comm.enable_crm_lot_commission else gross
        link = IBRequest.objects.filter(client_user=client, status=IBRequest.Status.APPROVED).select_related("ib_user").first()
        pay_ib = ib_user or (link.ib_user if link else None)
        at_id_int = int(at_id) if str(at_id).isdigit() else None
        if pay_ib:
            res = resolve_ib_commission_for_trade(
                ib_user=pay_ib,
                base_amount=client_charge,
                symbol_raw=sym_code,
                group_name="",
                lots=lots,
                deposit_total=Decimal("0"),
                account_type_id=at_id_int,
                hold_seconds=None,
            )
            prof = IBProfile.objects.filter(user=pay_ib).select_related("ib_level").first()
            ib_commission = apply_level_caps(pay_ib.id, prof.ib_level if prof else None, res.ib_total)
            pct = Decimal("0")
        else:
            pct = _effective_percentage(symbol=sym_code, lots=lots, deposit_total=Decimal("0"))
            ib_commission = (client_charge * pct / Decimal("100")).quantize(Decimal("0.0001"))
        company_profit = (client_charge - ib_commission).quantize(Decimal("0.0001"))

        if action == "calculate":
            return render(
                request,
                "admin_panel/trade_simulator.html",
                {
                    "clients": clients,
                    "ib_users": ib_users,
                    "symbol_codes": symbol_codes,
                    "account_types": account_types,
                    "recent": recent,
                    "crm_comm": crm_comm,
                    "calc": {
                        "gross": gross,
                        "client_charge": client_charge,
                        "ib_commission": ib_commission,
                        "company_profit": company_profit,
                        "pct": pct,
                    },
                    "form": {
                        "client_id": client_id,
                        "ib_user_id": ib_user.id if ib_user else "",
                        "symbol": sym_code,
                        "lots": str(lots),
                        "profit_per_lot": str(profit_per_lot),
                        "commission_per_lot": str(commission_per_lot),
                        "account_type_id": at_id,
                    },
                },
            )

        if action == "save":
            SimulatedIBTrade.objects.create(
                created_by=request.user,
                client=client,
                ib_user=ib_user,
                symbol=sym_code[:48],
                lots=lots,
                profit_per_lot=profit_per_lot,
                commission_per_lot_client=commission_per_lot,
                ib_commission_estimate=ib_commission,
                company_profit_estimate=company_profit,
                account_type=account_type,
            )
            messages.success(request, "Simulated trade saved.")
            return redirect("admin-ib-trade-simulator")

    return render(
        request,
        "admin_panel/trade_simulator.html",
        {
            "clients": clients,
            "ib_users": ib_users,
            "symbol_codes": symbol_codes,
            "account_types": account_types,
            "recent": recent,
            "crm_comm": crm_comm,
            "calc": None,
            "form": {},
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def broker_crm_commission_toggle(request):
    obj = BrokerCrmCommissionSettings.get_solo()
    if request.method == "POST":
        obj.enable_crm_lot_commission = request.POST.get("enable_crm_lot_commission") == "on"
        obj.notes = (request.POST.get("notes") or "")[:2000]
        obj.save(update_fields=["enable_crm_lot_commission", "notes", "updated_at"])
        messages.success(request, "Broker CRM commission (testing) settings saved.")
        return redirect("admin-broker-crm-commission")
    return render(request, "admin_panel/broker_crm_commission.html", {"obj": obj})
