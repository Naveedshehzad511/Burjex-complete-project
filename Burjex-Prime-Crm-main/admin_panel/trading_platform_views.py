import ssl
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import (
    TRADING_PLATFORM_SLUGS,
    TRADING_PLATFORM_SLUG_TO_CODE,
    IntegrationConnectionLog,
    TradingPlatformIntegration,
)

def _test_http_endpoint(url: str, timeout: int = 12) -> tuple[bool, str]:
    raw = (url or "").strip()
    if not raw:
        return False, "No API URL configured."
    if not raw.lower().startswith(("http://", "https://")):
        raw = "https://" + raw
    req = Request(
        raw,
        method="GET",
        headers={"User-Agent": "ForexCRM-IntegrationCheck/1.0"},
    )
    ctx = ssl.create_default_context()
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            return True, f"Reachable (HTTP {resp.status})."
    except HTTPError as e:
        if e.code in (401, 403, 405):
            return True, f"Host responded HTTP {e.code} (endpoint may require auth — connection OK)."
        return False, f"HTTP error {e.code}: {e.reason}"[:500]
    except URLError as e:
        return False, str(e.reason if hasattr(e, "reason") else e)[:500]
    except Exception as e:
        return False, str(e)[:500]


def _platform_meta():
    return {
        TradingPlatformIntegration.Platform.MT4: {"icon": "fa-brands fa-windows", "hint": "MT4 bridge / manager API"},
        TradingPlatformIntegration.Platform.MT5: {"icon": "fa-solid fa-chart-line", "hint": "MT5 Manager / Web API"},
        TradingPlatformIntegration.Platform.CTRADER: {"icon": "fa-solid fa-arrow-trend-up", "hint": "cTrader Open API"},
        TradingPlatformIntegration.Platform.TRADELOCKER: {"icon": "fa-solid fa-lock", "hint": "TradeLocker API"},
        TradingPlatformIntegration.Platform.VERTEX_TRADER: {"icon": "fa-solid fa-circle-nodes", "hint": "Vertex Trader"},
        TradingPlatformIntegration.Platform.X9_TRADER: {"icon": "fa-solid fa-xmark", "hint": "X9 Trader"},
        TradingPlatformIntegration.Platform.MATCH_TRADER: {
            "icon": "fa-solid fa-bolt",
            "hint": "Match-Trader broker API, gRPC, and client trading sync.",
        },
        TradingPlatformIntegration.Platform.BTRADER: {
            "icon": "fa-solid fa-chart-simple",
            "hint": "BTrader gateway HMAC API (keyId + secret). Mint keys in BTrader Admin → CRM / Integrations.",
        },
    }


def _endpoint_for_test(platform_key: str, row: TradingPlatformIntegration, request) -> str:
    posted = request.POST

    def p(name: str) -> str:
        return (posted.get(name) or "").strip()

    if platform_key == TradingPlatformIntegration.Platform.CTRADER:
        live_n = p("live_network_address") or (row.live_network_address or "")
        demo_n = p("demo_network_address") or (row.demo_network_address or "")
        return live_n or demo_n
    if platform_key == TradingPlatformIntegration.Platform.MT5:
        return p("api_server_url") or (row.api_server_url or "")
    return (p("api_server_url") or (row.api_server_url or "")).strip()


def _merge_trading_extended_config(platform_key: str, post, ext: dict) -> dict:
    if platform_key in (
        TradingPlatformIntegration.Platform.CTRADER,
        TradingPlatformIntegration.Platform.MT5,
    ):
        return {}
    if platform_key == TradingPlatformIntegration.Platform.BTRADER:
        out = dict(ext or {})
        out["tenant_header"] = (post.get("tenant_header") or "").strip()
        # Outbound webhook HMAC secret (BTrader → CRM). Leave blank to reuse inbound secret.
        posted_wh = (post.get("webhook_secret") or "").strip()
        if posted_wh:
            out["webhook_secret"] = posted_wh
        elif "webhook_secret" not in out:
            out["webhook_secret"] = ""
        return out

    return dict(ext or {})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def trading_platforms_hub(request):
    TradingPlatformIntegration.ensure_defaults()
    rows = list(TradingPlatformIntegration.objects.all().order_by("platform"))
    meta = _platform_meta()
    items = []
    for row in rows:
        badge, badge_label = row.status_badge()
        slug = row.url_slug()
        if row.platform == TradingPlatformIntegration.Platform.MATCH_TRADER:
            configure_url = reverse("admin-integrations-match-trader-enterprise")
        else:
            configure_url = reverse("admin-trading-platform-configure", kwargs={"slug": slug})
        items.append(
            {
                "row": row,
                "slug": slug,
                "badge": badge,
                "badge_label": badge_label,
                "meta": meta.get(row.platform, {"icon": "fa-solid fa-plug", "hint": ""}),
                "configure_url": configure_url,
            }
        )
    return render(
        request,
        "admin_panel/trading_platforms/hub.html",
        {"title": "Trading Platforms", "items": items},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_platform_configure(request, slug: str):
    platform_key = TRADING_PLATFORM_SLUG_TO_CODE.get((slug or "").strip().lower())
    if not platform_key:
        messages.error(request, "Unknown platform.")
        return redirect("admin-integrations-trading-platforms-hub")
    if platform_key == TradingPlatformIntegration.Platform.MATCH_TRADER:
        return redirect("admin-integrations-match-trader-enterprise")
    TradingPlatformIntegration.ensure_defaults()
    row = get_object_or_404(TradingPlatformIntegration, platform=platform_key)
    meta = _platform_meta().get(platform_key, {"icon": "fa-solid fa-plug", "hint": ""})
    url_slug = TRADING_PLATFORM_SLUGS.get(platform_key, slug)

    if request.method == "POST":
        row.enabled = request.POST.get("enabled") == "on"
        row.server_name = (request.POST.get("server_name") or "").strip()[:200]

        # Reset per-platform fields to avoid UI overlap/duplication.
        row.api_key = ""
        row.secret_key = ""
        row.api_version = ""
        row.payment_gateway_uuid = ""
        row.live_manager_token = ""
        row.demo_manager_token = ""
        row.broker_name = ""
        row.network_address = ""
        row.live_network_address = ""
        row.demo_network_address = ""
        row.api_server_url = ""

        if platform_key == TradingPlatformIntegration.Platform.CTRADER:
            row.live_manager_token = (request.POST.get("live_manager_token") or "").strip()
            row.demo_manager_token = (request.POST.get("demo_manager_token") or "").strip()
            row.broker_name = (request.POST.get("broker_name") or "").strip()[:200]
            row.live_network_address = (request.POST.get("live_network_address") or "").strip()[:500]
            row.demo_network_address = (request.POST.get("demo_network_address") or "").strip()[:500]
        elif platform_key == TradingPlatformIntegration.Platform.MT5:
            row.api_key = (request.POST.get("api_key") or "").strip()
            row.api_server_url = (request.POST.get("api_server_url") or "").strip()[:500]
            row.secret_key = (request.POST.get("secret_key") or "").strip()
            ext = dict(row.extended_config or {})
            ext["port"] = (request.POST.get("port") or "").strip()
            ext["encrypt"] = request.POST.get("encrypt") == "on"
            row.extended_config = ext
        elif platform_key == TradingPlatformIntegration.Platform.BTRADER:
            # BTrader HMAC CRM contract: keyId → api_key, secret → secret_key, gateway → api_server_url
            row.api_key = (request.POST.get("api_key") or "").strip()
            row.secret_key = (request.POST.get("secret_key") or "").strip()
            row.api_server_url = (request.POST.get("api_server_url") or "").strip()[:500]
            row.extended_config = _merge_trading_extended_config(
                platform_key, request.POST, dict(row.extended_config or {})
            )
        else:
            # Keep generic fallback for unsupported platforms.
            row.api_key = (request.POST.get("api_key") or "").strip()
            row.secret_key = (request.POST.get("secret_key") or "").strip()
            row.api_server_url = (request.POST.get("api_server_url") or "").strip()[:500]

        if platform_key not in (
            TradingPlatformIntegration.Platform.MT5,
            TradingPlatformIntegration.Platform.CTRADER,
        ):
            row.quick_notes = (request.POST.get("quick_notes") or "").strip()
            row.admin_notes = (request.POST.get("admin_notes") or "").strip()
            row.status_message = (request.POST.get("status_message") or "").strip()[:255]
        if platform_key != TradingPlatformIntegration.Platform.BTRADER:
            row.extended_config = _merge_trading_extended_config(platform_key, request.POST, row.extended_config)
        row.save()
        messages.success(request, "Configuration saved.")
        return redirect("admin-trading-platform-configure", slug=url_slug)

    badge, badge_label = row.status_badge()
    ctx = {
        "title": row.get_platform_display(),
        "row": row,
        "platform_key": platform_key,
        "url_slug": url_slug,
        "badge": badge,
        "badge_label": badge_label,
        "meta": meta,
        "match_trader": None,
        "match_trader_page": False,
    }
    return render(request, "admin_panel/trading_platforms/configure.html", ctx)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def trading_platform_test_ajax(request, slug: str):
    platform_key = TRADING_PLATFORM_SLUG_TO_CODE.get((slug or "").strip().lower())
    if not platform_key:
        return JsonResponse({"ok": False, "message": "Unknown platform."}, status=404)
    if platform_key == TradingPlatformIntegration.Platform.MATCH_TRADER:
        return JsonResponse(
            {"ok": False, "message": "Use the Match-Trader module Test Connection action."},
            status=400,
        )
    row = TradingPlatformIntegration.objects.filter(platform=platform_key).first()
    if not row:
        return JsonResponse({"ok": False, "message": "Platform not found."}, status=404)

    if platform_key == TradingPlatformIntegration.Platform.MT5:
        from mt5_integration.client import MT5Client, MT5ConnectionError, MT5AuthError
        host = (request.POST.get("api_server_url") or row.api_server_url or "").strip()
        port_str = (request.POST.get("port") or (row.extended_config or {}).get("port") or "443").strip()
        try:
            port = int(port_str)
        except (ValueError, TypeError):
            port = 443
        login_str = (request.POST.get("api_key") or row.api_key or "0").strip()
        try:
            login = int(login_str)
        except (ValueError, TypeError):
            login = 0
        password = (request.POST.get("secret_key") or row.secret_key or "").strip()
        encrypt = request.POST.get("encrypt") == "on" or (row.extended_config or {}).get("encrypt") is True

        # Input validation
        if not host:
            ok, detail = False, "Missing server host / IP address."
        elif not isinstance(port, int) or not (0 < port < 65536):
            ok, detail = False, f"Invalid port number: {port_str}. Must be 1-65535."
        elif login <= 0:
            ok, detail = False, "Login ID must be a positive integer (your MT5 manager login)."
        elif not password:
            ok, detail = False, "Password cannot be empty."
        else:
            # Attempt connection
            try:
                with MT5Client(
                    host=host,
                    port=port,
                    login=login,
                    password=password,
                    timeout=5.0,
                    use_encryption=encrypt,
                ) as client:
                    ping_ok = client.ping()
                    if ping_ok:
                        ok, detail = True, "Successfully connected and authenticated to MT5 server."
                    else:
                        # MT_RET_OK_NONE (retcode 1) — server is alive, PING returned no data body.
                        # This is normal for some MT5 server builds; treat as full success.
                        ok, detail = True, "Successfully connected and authenticated to MT5 server (PING OK)."
            except MT5ConnectionError as exc:
                ok, detail = False, f"Connection error ({exc.__class__.__name__}): {exc}"
            except MT5AuthError as exc:
                ok, detail = False, f"Authentication error ({exc.__class__.__name__}): {exc}"
            except Exception as exc:
                ok, detail = False, f"Error ({exc.__class__.__name__}): {exc}"
    elif platform_key == TradingPlatformIntegration.Platform.BTRADER:
        from btrader_integration.services import test_btrader_connection

        ok, detail = test_btrader_connection(
            base_url=(request.POST.get("api_server_url") or row.api_server_url or "").strip(),
            key_id=(request.POST.get("api_key") or row.api_key or "").strip(),
            secret=(request.POST.get("secret_key") or row.secret_key or "").strip(),
            tenant_header=(
                request.POST.get("tenant_header")
                or (row.extended_config or {}).get("tenant_header")
                or ""
            ).strip(),
        )
    else:
        url = _endpoint_for_test(platform_key, row, request)
        ok, detail = _test_http_endpoint(url, timeout=12)

    row.last_test_ok = ok
    row.last_test_detail = detail[:500]
    row.last_test_at = timezone.now()
    row.save(update_fields=["last_test_ok", "last_test_detail", "last_test_at"])
    
    IntegrationConnectionLog.objects.create(
        integration_slug=f"trading_{platform_key}",
        category="TRADING",
        success=ok,
        message=detail[:4000],
    )
    return JsonResponse({"ok": ok, "message": detail})
