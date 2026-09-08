"""Match-Trader API key test (no manual base URL in UI) and remote group catalog sync."""

from __future__ import annotations

import json
import logging
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen

import ssl

from .match_trader_grpc import match_trader_api_root_for_catalog, match_trader_grpc_handshake, parse_grpc_target

logger = logging.getLogger(__name__)

# Full response logged at INFO (truncate in log if huge)
_MT_GROUPS_LOG_MAX = 100_000

# Tried in order for trading/group catalog (Bearer token). Stop on first 2xx + parseable names.
# Match-Trader brokers vary; group-catalog paths are common on newer stacks.
MATCH_TRADER_GROUP_ENDPOINTS_ORDERED: tuple[str, ...] = (
    "groups",
    "accounts",
    "users",
    "broker/groups",
    "api/broker/groups",
    "broker/group-catalog",
    "group-catalog",
)

# Primary probe order + legacy fallbacks (deduped when combined).
MATCH_TRADER_GROUP_ENDPOINTS_LEGACY_FALLBACK: tuple[str, ...] = (
    "broker/group",
    "groups/list",
    "api/v1/broker/groups",
    "v1/broker/groups",
)

MATCH_TRADER_GROUP_ENDPOINTS_PRIMARY: tuple[str, ...] = MATCH_TRADER_GROUP_ENDPOINTS_ORDERED


def _join_api_path(base: str, rel: str) -> str:
    """Join REST base and relative path without urljoin stripping path segments."""
    b = (base or "").strip().rstrip("/")
    r = (rel or "").strip().lstrip("/")
    if not b:
        return f"/{r}" if r else ""
    return f"{b}/{r}" if r else b


def _group_fetch_base_candidates(https_base: str) -> tuple[str, ...]:
    """
    Bases to try for group endpoints. Many brokers serve lists under …/api/… while others
    expose /broker/groups at the host root — trying only /api causes 404 on the latter.
    """
    from urllib.parse import urlparse

    from .match_trader import _normalize_base

    raw = _normalize_base((https_base or "").strip())
    if not raw:
        return ()
    catalog = (match_trader_api_root_for_catalog(raw) or "").strip().rstrip("/")
    p = urlparse(raw)
    netloc = (p.netloc or "").strip()
    scheme = (p.scheme or "https").strip()
    origin = f"{scheme}://{netloc}".rstrip("/") if netloc else ""
    seen: set[str] = set()
    out: list[str] = []
    for c in (catalog, raw.rstrip("/"), origin):
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return tuple(out)


def _dedupe_paths_ordered(*path_groups: tuple[str, ...]) -> tuple[str, ...]:
    seen: set[str] = set()
    out: list[str] = []
    for group in path_groups:
        for p in group:
            n = (p or "").strip().lstrip("/")
            if not n or n in seen:
                continue
            seen.add(n)
            out.append(n)
    return tuple(out)


def _log_full_mt_response(*, phase: str, url: str, code: object, err_tag: object, raw: str) -> None:
    log_body = raw if len(raw) <= _MT_GROUPS_LOG_MAX else raw[:_MT_GROUPS_LOG_MAX] + "\n…[truncated for log]"
    logger.info(
        "Match-Trader group fetch [%s]: GET %s status=%s err_tag=%s body=%s",
        phase,
        url,
        code,
        err_tag,
        log_body,
    )


def _extract_name_list(payload: Any) -> list[str]:
    if payload is None:
        return []
    if isinstance(payload, list):
        out: list[str] = []
        for x in payload:
            if isinstance(x, str) and x.strip():
                out.append(x.strip()[:120])
            elif isinstance(x, dict):
                for k in ("name", "groupName", "group", "title", "code", "label"):
                    v = x.get(k)
                    if isinstance(v, str) and v.strip():
                        out.append(v.strip()[:120])
                        break
                else:
                    vid = x.get("id")
                    if isinstance(vid, (int, float)) and not isinstance(vid, bool):
                        out.append(str(int(vid))[:120])
                    elif isinstance(vid, str) and vid.strip():
                        out.append(vid.strip()[:120])
        return out
    if isinstance(payload, dict):
        for k in (
            "data",
            "groups",
            "items",
            "results",
            "tradingGroups",
            "accountGroups",
            "servers",
            "brokerGroups",
            "groupCatalog",
            "catalog",
            "entries",
            "groupList",
        ):
            if k in payload:
                return _extract_name_list(payload[k])
        if "name" in payload and isinstance(payload["name"], str):
            return [payload["name"].strip()[:120]]
    return []


def _http_get_bearer_raw(
    url: str,
    api_key: str,
    timeout: int,
    ctx: ssl.SSLContext,
) -> tuple[int | None, str, Any | None, str | None]:
    """
    GET with Bearer token. Returns (http_status, raw_body_text, parsed_json_or_None, error_tag).
    error_tag: 'timeout', 'network', or None.
    """
    if not (url or "").lower().startswith("https://"):
        return None, "HTTPS is required for Match-Trader REST requests.", None, "network"

    req = Request(
        url,
        method="GET",
        headers={
            "User-Agent": "ForexCRM-MatchTrader-GroupsTest/1.0",
            "Authorization": f"Bearer {(api_key or '').strip()}",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            code = int(getattr(resp, "status", None) or resp.getcode())
            raw = resp.read().decode("utf-8", errors="replace")
            parsed: Any | None = None
            if raw.strip():
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError:
                    parsed = None
            return code, raw, parsed, None
    except HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace")
        except Exception:
            raw = ""
        code = int(e.code)
        parsed = None
        if raw.strip():
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = None
        return code, raw, parsed, None
    except URLError as e:
        reason = str(getattr(e, "reason", e) or e)
        if "timed out" in reason.lower() or isinstance(getattr(e, "reason", None), TimeoutError):
            return None, "", None, "timeout"
        return None, reason[:2000], None, "network"
    except (TimeoutError, OSError, ssl.SSLError) as e:
        return None, str(e).strip()[:2000], None, "timeout"


# REST probes used only to verify Bearer token (after gRPC succeeds). Order matters.
MATCH_TRADER_REST_AUTH_PATHS: tuple[str, ...] = (
    "groups",
    "accounts",
    "users",
    "broker/groups",
    "api/broker/groups",
    "v1/groups",
    "v1/accounts",
    "v1/users",
    "api/groups",
    "api/v1/accounts",
    "api/users",
    "api/v1/users",
)


def verify_match_trader_rest_api_key(
    api_key: str,
    https_base: str,
    *,
    timeout: int = 15,
) -> dict[str, Any]:
    """
    Require a real REST success (2xx) on /groups, /accounts, or /users (or v1 variants).
    401/403 → invalid credentials. Does not treat gRPC alone as sufficient auth.
    """
    key = (api_key or "").strip()
    if not key:
        return {
            "ok": False,
            "user_error": "Secret API key is required",
            "detail": "API key cannot be empty.",
            "http_status": None,
            "verified_url": "",
        }
    https = (https_base or "").strip()
    if not https:
        return {
            "ok": False,
            "user_error": "Base URL is required",
            "detail": "HTTPS base URL cannot be empty.",
            "http_status": None,
            "verified_url": "",
        }

    api_root = match_trader_api_root_for_catalog(https) or https.rstrip("/")
    ctx = ssl.create_default_context()
    last_code: int | None = None
    last_url = ""

    for rel in MATCH_TRADER_REST_AUTH_PATHS:
        url = urljoin(api_root.rstrip("/") + "/", rel.lstrip("/"))
        code, raw, _parsed, err_tag = _http_get_bearer_raw(url, key, timeout, ctx)
        last_code, last_url = code, url
        logger.info("Match-Trader REST auth probe: GET %s status=%s err_tag=%s", url, code, err_tag)

        if err_tag == "timeout":
            logger.warning(
                "Match-Trader REST auth probe failed: timeout GET %s",
                url,
            )
            return {
                "ok": False,
                "user_error": "Network Timeout",
                "detail": f"REST token verification timed out (GET {url}).",
                "http_status": None,
                "verified_url": url,
            }
        if err_tag == "network":
            logger.warning(
                "Match-Trader REST auth probe failed: network GET %s raw=%s",
                url,
                (raw or "")[:500],
            )
            return {
                "ok": False,
                "user_error": "Network issue — could not reach Match-Trader REST",
                "detail": f"REST API unreachable: {(raw or err_tag)[:400]}",
                "http_status": None,
                "verified_url": url,
            }
        if code is None:
            continue
        if code == 401:
            logger.warning(
                "Match-Trader REST auth probe: 401 GET %s",
                url,
            )
            return {
                "ok": False,
                "user_error": "Invalid API Key or Token",
                "detail": f"Broker REST API rejected the token (HTTP 401). GET {url}",
                "http_status": code,
                "verified_url": url,
            }
        if code == 403:
            logger.warning(
                "Match-Trader REST auth probe: 403 GET %s",
                url,
            )
            return {
                "ok": False,
                "user_error": "API permission missing",
                "detail": f"Broker REST API denied access (HTTP 403). GET {url}",
                "http_status": code,
                "verified_url": url,
            }
        if 200 <= code < 300:
            return {
                "ok": True,
                "user_error": "",
                "detail": f"Verified via GET {rel} (HTTP {code}).",
                "http_status": code,
                "verified_url": url,
            }

    logger.warning(
        "Match-Trader REST auth probe: no 2xx from known paths last HTTP=%s url=%s",
        last_code,
        last_url,
    )
    last_user = _user_message_for_http_status(last_code)
    return {
        "ok": False,
        "user_error": "Invalid Base URL" if last_code == 404 else last_user,
        "detail": (
            f"Could not verify token: no successful response on /groups, /accounts, or /users "
            f"(last HTTP {last_code} at {last_url}). Check REST Base URL and API key."
        ),
        "http_status": last_code,
        "verified_url": last_url,
    }


def _mt_diagnostic_step(
    step: int,
    name: str,
    label: str,
    ok: bool | None,
    message: str,
    detail: str = "",
) -> dict[str, Any]:
    return {
        "step": step,
        "name": name,
        "label": label,
        "ok": ok,
        "message": (message or "").strip()[:500],
        "detail": (detail or "").strip()[:2000],
    }


_SKIPPED_STEP_LABELS: dict[int, tuple[str, str]] = {
    2: ("api_key", "API Key"),
    3: ("grpc", "gRPC connection"),
    4: ("rest_token", "REST token"),
    5: ("rest_endpoint", "REST endpoint"),
    6: ("broker_groups", "Fetch broker groups"),
    7: ("permissions", "API permissions"),
}


def _skipped_steps(from_step: int, total: int = 7) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for s in range(from_step, total + 1):
        nm, label = _SKIPPED_STEP_LABELS.get(s, (f"step_{s}", f"Step {s}"))
        out.append(
            _mt_diagnostic_step(
                s,
                nm,
                label,
                None,
                "Skipped — fix the previous step first.",
                "",
            )
        )
    return out


def match_trader_test_secret_key(
    api_key: str,
    stored_base_url: str = "",
    grpc_address: str = "",
    timeout: int = 20,
    *,
    rest_base_url: str = "",
) -> dict[str, Any]:
    """
    Ordered diagnostics: Base URL → API key → gRPC → REST token → REST bases → groups → permissions.
    Returns ``diagnostic_steps`` for UI; overall ``ok`` only if every required step passes and groups load.
    """
    from .match_trader_connection import validate_base_url

    steps: list[dict[str, Any]] = []
    key = (api_key or "").strip()
    base = (stored_base_url or "").strip()
    grpc = (grpc_address or "").strip()
    rest_base = (rest_base_url or "").strip() or base
    rest_to = max(10, min(int(timeout), 25))

    def fail_bundle(
        *,
        user_error: str,
        detail: str,
        resolved_base: str = "",
        latency_ms: int | None = None,
        grpc_ok: bool | None = None,
        rest_http_status: int | None = None,
        rest_verified_url: str = "",
        groups_extracted_count: int = 0,
        groups_diagnosis_code: str = "",
        extra: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        out: dict[str, Any] = {
            "ok": False,
            "user_error": user_error,
            "detail": detail,
            "resolved_base": resolved_base[:500],
            "latency_ms": latency_ms,
            "grpc_ok": grpc_ok,
            "rest_http_status": rest_http_status,
            "rest_verified_url": rest_verified_url[:800],
            "groups_extracted_count": groups_extracted_count,
            "groups_diagnosis_code": groups_diagnosis_code,
            "diagnostic_steps": steps,
            "failure_step": next((s["step"] for s in steps if s.get("ok") is False), None),
        }
        if extra:
            out.update(extra)
        logger.info(
            "Match-Trader connection test finished: ok=False user_error=%s steps=%s",
            user_error,
            [(s.get("step"), s.get("label"), s.get("ok"), s.get("message")) for s in steps],
        )
        return out

    # Step 1 — Base URL
    ok_b, err_b = validate_base_url(base)
    msg_b = "Success" if ok_b else "Invalid Base URL"
    steps.append(_mt_diagnostic_step(1, "base_url", "Base URL", ok_b, msg_b, err_b))
    if not ok_b:
        steps.extend(_skipped_steps(2))
        return fail_bundle(
            user_error=msg_b,
            detail=err_b or "Enter a valid HTTPS broker base URL.",
        )

    # Step 2 — API key present
    ok_k = bool(key)
    steps.append(
        _mt_diagnostic_step(
            2,
            "api_key",
            "API Key",
            ok_k,
            "Success" if ok_k else "Invalid API Key",
            "" if ok_k else "Secret API key is required.",
        )
    )
    if not ok_k:
        steps.extend(_skipped_steps(3))
        return fail_bundle(
            user_error="Invalid API Key",
            detail="Enter a valid API key before testing.",
        )

    if not grpc:
        steps.append(
            _mt_diagnostic_step(
                3,
                "grpc",
                "gRPC connection",
                False,
                "Invalid gRPC endpoint",
                "gRPC address is required.",
            )
        )
        steps.extend(_skipped_steps(4))
        return fail_bundle(
            user_error="Invalid gRPC endpoint",
            detail="Enter the broker gRPC host.",
        )

    parsed = parse_grpc_target(grpc)
    if not parsed:
        steps.append(
            _mt_diagnostic_step(
                3,
                "grpc",
                "gRPC connection",
                False,
                "Invalid gRPC endpoint",
                "Expected host or host:port (e.g. grpc-broker-api.example.com).",
            )
        )
        steps.extend(_skipped_steps(4))
        return fail_bundle(
            user_error="Invalid gRPC endpoint",
            detail="Enter the broker gRPC host (e.g. grpc-broker-api.match-trader.com) or host:port.",
        )

    host, port = parsed
    gh_ok, gh_msg, latency_ms = match_trader_grpc_handshake(host, port, key, timeout=float(timeout))
    logger.info(
        "Match-Trader gRPC handshake: ok=%s target=%s:%s detail=%s latency_ms=%s",
        gh_ok,
        host,
        port,
        gh_msg,
        latency_ms,
    )
    steps.append(
        _mt_diagnostic_step(
            3,
            "grpc",
            "gRPC connection",
            gh_ok,
            "Success" if gh_ok else "gRPC connection failed",
            gh_msg,
        )
    )
    if not gh_ok:
        steps.extend(_skipped_steps(4))
        return fail_bundle(
            user_error="gRPC connection failed",
            detail=gh_msg,
            latency_ms=latency_ms,
            grpc_ok=False,
        )

    api_root = (match_trader_api_root_for_catalog(base) or "")[:500]

    # Step 4 — REST Bearer / token accepted on known paths
    v = verify_match_trader_rest_api_key(key, rest_base, timeout=rest_to)
    logger.info(
        "Match-Trader REST token step: ok=%s http=%s url=%s",
        v.get("ok"),
        v.get("http_status"),
        v.get("verified_url"),
    )
    steps.append(
        _mt_diagnostic_step(
            4,
            "rest_token",
            "REST token",
            bool(v.get("ok")),
            "Success" if v.get("ok") else (v.get("user_error") or "REST token verification failed"),
            (v.get("detail") or "")[:1500],
        )
    )
    if not v.get("ok"):
        steps.extend(_skipped_steps(5))
        return fail_bundle(
            user_error=str(v.get("user_error") or "REST token verification failed"),
            detail=str(v.get("detail") or ""),
            resolved_base=api_root,
            latency_ms=latency_ms,
            grpc_ok=True,
            rest_http_status=v.get("http_status"),
            rest_verified_url=str(v.get("verified_url") or ""),
        )

    # Step 5 — REST catalog bases resolved
    bases = _group_fetch_base_candidates(rest_base)
    ok_ep = len(bases) > 0
    steps.append(
        _mt_diagnostic_step(
            5,
            "rest_endpoint",
            "REST endpoint",
            ok_ep,
            "Success" if ok_ep else "Invalid Base URL",
            ", ".join(bases) if bases else "Could not derive REST bases from the configured URL.",
        )
    )
    if not ok_ep:
        steps.extend(_skipped_steps(6))
        return fail_bundle(
            user_error="Invalid Base URL",
            detail="HTTPS base URL is invalid or could not be normalized for REST.",
            resolved_base=api_root,
            latency_ms=latency_ms,
            grpc_ok=True,
            rest_http_status=v.get("http_status"),
            rest_verified_url=str(v.get("verified_url") or ""),
        )

    # Step 6 — Fetch broker groups (parseable names)
    diag = diagnose_match_trader_groups_get(api_key=key, https_base=rest_base, timeout=rest_to)
    d_ok = bool(diag.get("ok"))
    g_user = (
        str(diag.get("user_error") or "").strip()
        if not d_ok
        else ""
    )
    step6_msg = "Success" if d_ok else (g_user or "Could not load broker groups")
    steps.append(
        _mt_diagnostic_step(
            6,
            "broker_groups",
            "Fetch broker groups",
            d_ok,
            step6_msg,
            (diag.get("diagnosis") or "")[:1500],
        )
    )

    # Step 7 — Permissions / RBAC (only passes when groups were readable)
    attempts = list(diag.get("attempts") or [])
    codes = [a.get("http_status") for a in attempts if a.get("http_status") is not None]
    if d_ok:
        perm_ok = True
        perm_msg = "Success"
    elif codes and all(c == 403 for c in codes):
        perm_ok = False
        perm_msg = "API permission missing"
    elif (diag.get("diagnosis_code") or "") == "empty_array_permission":
        perm_ok = False
        perm_msg = "API permission missing or no groups configured"
    elif codes and all(c == 401 for c in codes):
        perm_ok = False
        perm_msg = "Invalid API Key or Token"
    else:
        perm_ok = False
        perm_msg = "Cannot verify permissions until broker groups are readable"

    steps.append(
        _mt_diagnostic_step(
            7,
            "permissions",
            "API permissions",
            perm_ok,
            perm_msg,
            str(diag.get("diagnosis_code") or ""),
        )
    )

    if not d_ok:
        logger.error(
            "Match-Trader groups step failed: user_msg=%s diagnosis_code=%s",
            g_user or step6_msg,
            diag.get("diagnosis_code"),
        )
        return fail_bundle(
            user_error=g_user or step6_msg,
            detail=(diag.get("diagnosis") or "Match-Trader REST API did not return usable group data.").strip(),
            resolved_base=api_root,
            latency_ms=latency_ms,
            grpc_ok=True,
            rest_http_status=diag.get("http_status"),
            rest_verified_url=(diag.get("request_url") or str(v.get("verified_url") or ""))[:800],
            groups_extracted_count=int(diag.get("groups_extracted_count") or 0),
            groups_diagnosis_code=str(diag.get("diagnosis_code") or ""),
        )

    out_ok: dict[str, Any] = {
        "ok": True,
        "user_error": "",
        "user_message": "Connection successful — gRPC OK, REST token OK, and broker groups loaded",
        "detail": f"{gh_msg}. {diag.get('diagnosis', '')}",
        "resolved_base": api_root,
        "latency_ms": latency_ms,
        "rest_http_status": diag.get("http_status"),
        "rest_verified_url": (diag.get("request_url") or "")[:800],
        "groups_extracted_count": int(diag.get("groups_extracted_count") or 0),
        "groups_winning_path": (diag.get("winning_path") or "")[:200],
        "diagnostic_steps": steps,
        "failure_step": None,
        "grpc_ok": True,
    }
    logger.info(
        "Match-Trader connection test finished: ok=True latency_ms=%s groups=%s steps=%s",
        latency_ms,
        out_ok.get("groups_extracted_count"),
        [(s.get("step"), s.get("label"), s.get("ok")) for s in steps],
    )
    return out_ok


def _attempt_diagnosis(code: int | None, parsed: Any, raw: str) -> tuple[str, str]:
    """Short diagnosis for one HTTP response (machine code + log line)."""
    if code == 401:
        return "401 Unauthorized — invalid API key or token.", "unauthorized"
    if code == 403:
        return "403 Forbidden — permission denied.", "forbidden"
    if code == 404:
        return "404 Not Found — endpoint not found for this REST base.", "not_found"
    if code is not None and code in (500, 502, 503, 504):
        return f"HTTP {code} — Match-Trader server error.", "server_error"
    if code is None or (code < 200 or code >= 300):
        return (f"HTTP {code} — non-success." if code else "No HTTP status."), (
            f"http_{code}" if code else "unknown"
        )
    if parsed is None and raw.strip():
        return "2xx but body is not valid JSON.", "invalid_json"
    if isinstance(parsed, list) and len(parsed) == 0:
        return "2xx with empty JSON [] — possible permission issue or no groups.", "empty_array_permission"
    names = _extract_name_list(parsed)
    if not names:
        return "2xx but no group names parsed — check JSON shape in logs.", "empty_unparsed"
    return f"Success — {len(names)} group name(s).", "success"


def _user_message_for_http_status(code: int | None, *, err_tag: str | None = None) -> str:
    """End-user string for a single HTTP outcome."""
    if err_tag == "timeout":
        return "Network Timeout"
    if err_tag == "network":
        return "Network issue — could not reach the server"
    if code == 401:
        return "Invalid API Key or Token"
    if code == 403:
        return "API permission missing"
    if code == 404:
        return "Endpoint not found"
    if code is not None and code in (500, 502, 503, 504):
        return "Match-Trader server error"
    if code is not None and not (200 <= code < 300):
        return f"HTTP {code} error"
    return "Request failed"


def _aggregate_group_fetch_user_message(attempts: list[dict[str, Any]]) -> tuple[str, str]:
    """
    Derive a single user-facing message and coarse code from all diagnose attempts.
    Prefer auth → permission → not found → server → timeout/network → generic.
    """
    if not attempts:
        return "No REST attempts were made.", "unknown"

    err_tags = [a.get("err_tag") for a in attempts if a.get("err_tag")]
    if any(t == "timeout" for t in err_tags):
        return "Network Timeout", "timeout"
    if any(t == "network" for t in err_tags):
        return "Network issue — could not reach Match-Trader REST", "network"

    codes = [a.get("http_status") for a in attempts if a.get("http_status") is not None]
    if codes and all(c == 401 for c in codes):
        return "Invalid API Key or Token", "unauthorized"
    if codes and all(c == 403 for c in codes):
        return "API permission missing", "forbidden"
    if codes and all(c == 404 for c in codes):
        return "Endpoint not found — check REST Base URL", "not_found"
    if codes and any(c in (500, 502, 503, 504) for c in codes):
        return "Match-Trader server error", "server_error"
    if codes and any(c == 401 for c in codes):
        return "Invalid API Key or Token", "unauthorized"
    if codes and any(c == 403 for c in codes):
        return "API permission missing", "forbidden"

    last = attempts[-1]
    code = last.get("http_status")
    et = last.get("err_tag")
    return _user_message_for_http_status(code, err_tag=et), str(last.get("diagnosis_hint") or "all_failed")


def diagnose_match_trader_groups_get(
    *,
    api_key: str,
    https_base: str,
    timeout: int = 20,
    path: str | None = None,
) -> dict[str, Any]:
    """
    Try group endpoints in order (same Bearer token), logging each full response at INFO.

    Default order: groups → accounts → users → broker/groups → api/broker/groups → broker/group-catalog → group-catalog,
    then legacy fallbacks. Pass ``path`` to test a single relative path only.
    """
    key = (api_key or "").strip()
    https = (https_base or "").strip().rstrip("/")
    out: dict[str, Any] = {
        "ok": False,
        "https_base_input": https,
        "rest_base_normalized": "",
        "paths_tried": [],
        "attempts": [],
        "request_url": "",
        "http_status": None,
        "response_raw": "",
        "response_raw_truncated": False,
        "parsed_json": None,
        "groups_extracted": [],
        "groups_extracted_count": 0,
        "diagnosis": "",
        "diagnosis_code": "validation_error",
        "winning_path": "",
    }
    if not key:
        out["diagnosis"] = "API key is missing."
        return out
    if not https:
        out["diagnosis"] = "HTTPS base URL is missing."
        return out

    base_candidates = _group_fetch_base_candidates(https)
    if not base_candidates:
        out["diagnosis"] = "HTTPS base URL is invalid."
        return out
    out["rest_base_normalized"] = base_candidates[0]
    out["bases_tried"] = list(base_candidates)

    single = (path or "").strip().lstrip("/")
    if single:
        sequence = (single,)
    else:
        # User order: five canonical paths first, then legacy fallbacks; stop on first 2xx + names.
        sequence = _dedupe_paths_ordered(
            MATCH_TRADER_GROUP_ENDPOINTS_ORDERED,
            MATCH_TRADER_GROUP_ENDPOINTS_LEGACY_FALLBACK,
        )
    out["paths_tried"] = list(sequence)

    ctx = ssl.create_default_context()
    attempts: list[dict[str, Any]] = []
    last_raw = ""
    last_parsed: Any = None
    last_code: int | None = None

    for rest_base in base_candidates:
        for rel in sequence:
            url = _join_api_path(rest_base, rel)
            code, raw, parsed, err_tag = _http_get_bearer_raw(url, key, timeout, ctx)
            _log_full_mt_response(phase="diagnose", url=url, code=code, err_tag=err_tag, raw=raw)

            names = _extract_name_list(parsed) if parsed is not None else []
            att: dict[str, Any] = {
                "base": rest_base,
                "path": rel,
                "request_url": url,
                "http_status": code,
                "err_tag": err_tag,
                "full_response_length": len(raw),
                "groups_extracted_count": len(names),
                "groups_preview": names[:15],
                "response_raw_preview": raw[:4000],
                "response_truncated": len(raw) > 4000,
            }
            if err_tag:
                att["diagnosis_hint"] = err_tag
            elif code is not None:
                dmsg, dcode = _attempt_diagnosis(code, parsed, raw)
                att["diagnosis_hint"] = dcode
                att["diagnosis_message"] = dmsg
            attempts.append(att)

            last_raw, last_parsed, last_code = raw, parsed, code

            if err_tag == "timeout":
                out["attempts"] = attempts
                out["user_error"] = "Network Timeout"
                out["diagnosis"] = "Network Timeout — request timed out."
                out["diagnosis_code"] = "timeout"
                out["request_url"] = url
                out["http_status"] = code
                out["response_raw"] = raw[:8000]
                out["response_raw_truncated"] = len(raw) > 8000
                logger.error("Match-Trader group fetch: timeout GET %s", url)
                return out

            if err_tag == "network":
                out["attempts"] = attempts
                out["user_error"] = "Network issue — could not reach Match-Trader REST"
                out["diagnosis"] = f"Network error: {raw[:500] or 'connection failed'}"
                out["diagnosis_code"] = "network"
                logger.error("Match-Trader group fetch: network error GET %s detail=%s", url, raw[:300])
                return out

            if code and 200 <= code < 300 and names:
                out["ok"] = True
                out["winning_base"] = rest_base
                out["winning_path"] = rel
                out["request_url"] = url
                out["http_status"] = code
                out["full_response_length"] = len(raw)
                out["response_raw"] = raw[:8000]
                out["response_raw_truncated"] = len(raw) > 8000
                out["parsed_json"] = parsed
                out["groups_extracted"] = names[:50]
                out["groups_extracted_count"] = len(names)
                out["diagnosis"] = (
                    f"Success via `{rest_base}` + `{rel}` — {len(names)} group name(s) extracted."
                )
                out["diagnosis_code"] = "success"
                out["attempts"] = attempts
                return out

    out["attempts"] = attempts
    out["request_url"] = attempts[-1]["request_url"] if attempts else ""
    out["http_status"] = last_code
    out["full_response_length"] = len(last_raw)
    out["response_raw"] = last_raw[:8000]
    out["response_raw_truncated"] = len(last_raw) > 8000
    out["parsed_json"] = last_parsed
    last_names = _extract_name_list(last_parsed) if last_parsed is not None else []
    out["groups_extracted"] = last_names[:50]
    out["groups_extracted_count"] = len(last_names)
    dmsg, dcode = _attempt_diagnosis(last_code, last_parsed, last_raw)
    user_msg, agg_code = _aggregate_group_fetch_user_message(attempts)
    out["user_error"] = user_msg
    out["diagnosis"] = (
        f"{user_msg} (last response: {dmsg}) "
        f"Tried multiple bases and paths — see attempts[] and INFO logs for each request/response."
    )
    out["diagnosis_code"] = agg_code if agg_code != "unknown" else (dcode if dcode != "success" else "all_failed")
    logger.error(
        "Match-Trader group fetch failed: user_msg=%s diagnosis_code=%s last_http=%s last_hint=%s",
        user_msg,
        out["diagnosis_code"],
        last_code,
        dcode,
    )
    return out


def fetch_match_trader_catalog(api_key: str, https_base: str, timeout: int = 15) -> dict[str, list[str]]:
    """
    Best-effort GET of trading / account / server lists. Tries each REST base candidate
    (…/api, configured URL, host origin) × paths; stops at first successful list per category.
    """
    key = (api_key or "").strip()
    out: dict[str, list[str]] = {"trading": [], "account": [], "servers": []}
    if not key or not (https_base or "").strip():
        return out
    candidates = _group_fetch_base_candidates(https_base)
    if not candidates:
        return out
    ctx = ssl.create_default_context()

    trading_paths = _dedupe_paths_ordered(
        MATCH_TRADER_GROUP_ENDPOINTS_ORDERED,
        MATCH_TRADER_GROUP_ENDPOINTS_LEGACY_FALLBACK,
        (
            "v1/groups",
            "v1/broker/groups",
            "v1/trading-groups",
            "broker/v1/groups",
            "trading-groups",
            "api/groups",
            "api/v1/groups",
        ),
    )
    account_paths = ("v1/account-groups", "account-groups", "accounts/groups", "v1/accounts/groups")
    server_paths = ("v1/servers", "servers", "broker/servers", "v1/broker/servers")

    def try_paths(category: str, paths: tuple[str, ...]) -> list[str]:
        seen: set[str] = set()
        collected: list[str] = []
        for base_candidate in candidates:
            for p in paths:
                url = _join_api_path(base_candidate, p)
                code, raw, parsed, err_tag = _http_get_bearer_raw(url, key, timeout, ctx)
                _log_full_mt_response(phase=f"catalog:{category}", url=url, code=code, err_tag=err_tag, raw=raw)
                if err_tag in ("timeout", "network"):
                    continue
                if code and 200 <= code < 300 and parsed is not None:
                    names = _extract_name_list(parsed)
                    for n in names:
                        if n not in seen:
                            seen.add(n)
                            collected.append(n)
                    if collected:
                        return collected[:200]
        return collected

    out["trading"] = try_paths("trading", trading_paths)
    out["account"] = try_paths("account", account_paths)
    out["servers"] = try_paths("servers", server_paths)
    return out


def sync_match_trader_broker_groups_from_catalog(
    catalog: dict[str, list[str]],
) -> tuple[int, int, int]:
    """Upsert MatchTraderBrokerGroup rows by category. Returns counts (trading, account, server)."""
    from admin_panel.models import MatchTraderBrokerGroup

    def upsert(category: str, names: list[str]) -> int:
        n = 0
        for raw in names:
            nm = (raw or "").strip()[:120]
            if not nm:
                continue
            MatchTraderBrokerGroup.objects.update_or_create(
                sync_category=category,
                name=nm,
                defaults={
                    "description": f"Synced automatically from Match-Trader API ({category}).",
                    "is_active": True,
                },
            )
            n += 1
        return n

    a = upsert(MatchTraderBrokerGroup.Category.TRADING, catalog.get("trading") or [])
    b = upsert(MatchTraderBrokerGroup.Category.ACCOUNT, catalog.get("account") or [])
    c = upsert(MatchTraderBrokerGroup.Category.SERVER, catalog.get("servers") or [])
    return a, b, c


def run_match_trader_catalog_sync(*, timeout: int = 15) -> tuple[dict[str, int], str | None]:
    """
    Pull group lists from Match-Trader REST API and upsert MatchTraderBrokerGroup rows.
    Uses MatchTraderSettings (same source as gRPC test). Returns (counts, error_message).
    """
    from admin_panel.models import MatchTraderSettings

    mt = MatchTraderSettings.get_solo()
    if not mt.has_api_key():
        return {}, "Secret API key is not configured."
    https_base = (mt.rest_base_url or mt.base_url or "").strip()
    if not https_base:
        return {}, "Base URL or REST Base URL is not configured."
    key = (mt.get_api_key() or "").strip()
    catalog = fetch_match_trader_catalog(key, https_base, timeout=timeout)
    t_cnt, a_cnt, s_cnt = sync_match_trader_broker_groups_from_catalog(catalog)
    return (
        {"trading": t_cnt, "account": a_cnt, "servers": s_cnt, "total": t_cnt + a_cnt + s_cnt},
        None,
    )
