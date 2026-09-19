/**
 * Portal Cashback overlay. Shown on /cashback (Home drawer item below KYC).
 * Lists which BTrader engine trade id paid how much to this trader (not IB).
 */
(function () {
  if (window.__bxCashbackUi) return;
  window.__bxCashbackUi = true;

  var CRM = "https://crm.burjexprime.net/api/v1";

  function isCashback() {
    var path = (location.pathname || "/").replace(/\/+$/, "") || "/";
    var hash = location.hash || "";
    return path === "/cashback" || hash.indexOf("/cashback") >= 0;
  }

  function readToken() {
    try {
      var raw = localStorage.getItem("flutter.crm_access_token_prefs");
      if (!raw) raw = localStorage.getItem("flutter.crm_access_token");
      if (!raw) return "";
      var v = JSON.parse(raw);
      if (typeof v === "string") return v;
      if (v && typeof v === "object") return String(v.token || v.access || v.value || "");
    } catch (e) {}
    return "";
  }

  function ensureRoot() {
    var el = document.getElementById("bx-cashback-root");
    if (el) return el;
    el = document.createElement("div");
    el.id = "bx-cashback-root";
    el.style.cssText =
      "display:none;position:fixed;inset:0;z-index:2147483000;background:#0b1220;color:#e8eef8;font-family:system-ui,-apple-system,'Segoe UI',sans-serif;overflow:auto;";
    document.body.appendChild(el);
    return el;
  }

  function paint(html) {
    var el = ensureRoot();
    el.innerHTML = html;
    el.style.display = "block";
    var back = document.getElementById("bxCbBack");
    if (back) {
      back.addEventListener("click", function () {
        history.back();
        if (!isCashback()) hide();
      });
    }
  }

  function hide() {
    var el = document.getElementById("bx-cashback-root");
    if (el) el.style.display = "none";
  }

  function rowHtml(item) {
    var id = String(item.engine_trade_id || "");
    var amt = String(item.amount || "0");
    var alias = String(item.alias || "");
    var when = String(item.created_at || "").replace("T", " ").slice(0, 19);
    return (
      '<div style="display:flex;justify-content:space-between;gap:12px;padding:14px 0;border-bottom:1px solid rgba(255,255,255,.08)">' +
      '<div style="min-width:0">' +
      '<div style="font-size:13px;opacity:.65;letter-spacing:.04em;text-transform:uppercase">Engine trade id</div>' +
      '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;word-break:break-all;margin:4px 0 8px">' +
      id +
      "</div>" +
      '<div style="font-size:13px;opacity:.8">' +
      alias +
      (when ? " · " + when : "") +
      "</div></div>" +
      '<div style="font-size:20px;font-weight:700;white-space:nowrap">$' +
      amt +
      "</div></div>"
    );
  }

  function shell(body) {
    return (
      '<div style="max-width:560px;margin:0 auto;padding:20px 20px 40px">' +
      '<button id="bxCbBack" type="button" style="background:none;border:0;color:#9db0cc;font-size:14px;padding:0 0 12px;cursor:pointer">← Back</button>' +
      '<div style="font-size:13px;letter-spacing:.08em;text-transform:uppercase;opacity:.7">Burjex Prime</div>' +
      '<h1 style="font-size:26px;margin:8px 0 6px">Cashback</h1>' +
      '<p style="margin:0 0 18px;opacity:.75;font-size:14px">Paid to you on trade close. Not referral.</p>' +
      body +
      "</div>"
    );
  }

  async function load() {
    if (!isCashback()) {
      hide();
      return;
    }
    paint(shell('<p style="opacity:.7">Loading cashback history…</p>'));
    var token = readToken();
    if (!token) {
      paint(shell('<p>Sign in to see cashback paid on your closed trades.</p>'));
      return;
    }
    try {
      var res = await fetch(CRM + "/cashback/history/", {
        headers: { Authorization: "Token " + token, Accept: "application/json" },
      });
      var json = await res.json().catch(function () {
        return {};
      });
      if (!res.ok || json.success === false) {
        paint(shell("<p>Could not load cashback history.</p>"));
        return;
      }
      var data = json.data || {};
      var items = data.items || [];
      var total = data.total || "0.00";
      var list =
        items.length === 0
          ? '<p style="opacity:.7">No cashback yet. Close a trade on an alias with a CRM cashback rate.</p>'
          : items.map(rowHtml).join("");
      paint(
        shell(
          '<div style="background:#141c2e;border-radius:14px;padding:16px 18px;margin:0 0 18px">' +
            '<div style="font-size:12px;opacity:.65;text-transform:uppercase">Total received</div>' +
            '<div style="font-size:28px;font-weight:700">$' +
            total +
            "</div></div>" +
            list
        )
      );
    } catch (e) {
      paint(shell("<p>Could not load cashback history.</p>"));
    }
  }

  window.addEventListener("popstate", load);
  window.addEventListener("hashchange", load);
  setInterval(function () {
    var shown = document.getElementById("bx-cashback-root");
    var want = isCashback();
    var visible = shown && shown.style.display !== "none";
    if (want !== !!visible) load();
  }, 400);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", load);
  } else {
    load();
  }
})();
