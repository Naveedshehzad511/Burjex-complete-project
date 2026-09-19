/**
 * Portal Cashback overlay. Shown on /cashback (Home drawer item below KYC).
 * Light theme to match the rest of the portal. Client sees pair, date, time, amount.
 */
(function () {
  if (window.__bxCashbackUi) return;
  window.__bxCashbackUi = true;
  window.__bxCashbackEnabled = true;

  var CRM = "https://crm.burjexprime.net/api/v1";
  var period = "30d";
  var dateFrom = "";
  var dateTo = "";
  var showTransfer = false;
  var transferBusy = false;
  var lastData = null;
  var transferMeta = null;

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

  function money(v) {
    var n = Number(v);
    if (!isFinite(n)) n = 0;
    return "$" + n.toFixed(2);
  }

  function splitWhen(iso) {
    var raw = String(iso || "");
    var d = new Date(raw);
    if (isNaN(d.getTime())) {
      var t = raw.replace("T", " ").slice(0, 19);
      return { date: t.slice(0, 10), time: t.slice(11, 16) };
    }
    var date = d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "2-digit" });
    var time = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    return { date: date, time: time };
  }

  function ensureStyle() {
    if (document.getElementById("bx-cashback-style")) return;
    var st = document.createElement("style");
    st.id = "bx-cashback-style";
    st.textContent =
      "#bx-cashback-root{display:none;position:fixed;inset:0;z-index:2147483000;background:#f7f8fa;color:#0f172a;font-family:system-ui,-apple-system,'Segoe UI',sans-serif;overflow:auto;}" +
      "#bx-cashback-root *{box-sizing:border-box;}" +
      "#bx-cashback-root .bx-cb-bar{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:4px;min-height:56px;padding:0 8px;background:#fff;border-bottom:1px solid #e8edf3;}" +
      "#bx-cashback-root .bx-cb-back{width:48px;height:48px;flex:0 0 48px;display:flex;align-items:center;justify-content:center;background:none;border:0;padding:0;margin:0;color:#0f172a;cursor:pointer;border-radius:24px;}" +
      "#bx-cashback-root .bx-cb-back:active{background:rgba(15,23,42,.08);}" +
      "#bx-cashback-root .bx-cb-title{font-size:20px;font-weight:600;letter-spacing:.01em;}" +
      "#bx-cashback-root .bx-cb-wrap{max-width:560px;margin:0 auto;padding:16px 16px 40px;}" +
      "#bx-cashback-root .bx-cb-total{background:#fff;border:1px solid #e8edf3;border-radius:14px;padding:16px 18px;margin:0 0 14px;}" +
      "#bx-cashback-root .bx-cb-total-label{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#64748b;font-weight:600;}" +
      "#bx-cashback-root .bx-cb-total-amt{font-size:32px;font-weight:700;margin-top:6px;color:#0f172a;}" +
      "#bx-cashback-root .bx-cb-btn{display:inline-flex;align-items:center;justify-content:center;width:100%;min-height:44px;border:0;border-radius:10px;background:#002d58;color:#fff;font-size:15px;font-weight:650;cursor:pointer;padding:10px 16px;}" +
      "#bx-cashback-root .bx-cb-btn[disabled]{opacity:.55;cursor:default;}" +
      "#bx-cashback-root .bx-cb-btn-ghost{background:#fff;color:#002d58;border:1px solid #d5deea;}" +
      "#bx-cashback-root .bx-cb-pills{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0 12px;}" +
      "#bx-cashback-root .bx-cb-pill{border:1px solid #d5deea;background:#fff;color:#334155;border-radius:999px;padding:8px 12px;font-size:13px;font-weight:600;cursor:pointer;}" +
      "#bx-cashback-root .bx-cb-pill.on{background:#002d58;border-color:#002d58;color:#fff;}" +
      "#bx-cashback-root .bx-cb-custom{display:flex;flex-wrap:wrap;gap:8px;align-items:end;margin:0 0 14px;}" +
      "#bx-cashback-root .bx-cb-custom label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#64748b;font-weight:600;}" +
      "#bx-cashback-root .bx-cb-custom input,#bx-cashback-root select,#bx-cashback-root .bx-cb-field{border:1px solid #d5deea;border-radius:10px;padding:10px 12px;font-size:14px;background:#fff;color:#0f172a;min-height:42px;}" +
      "#bx-cashback-root .bx-cb-row{display:flex;justify-content:space-between;gap:12px;padding:14px 0;border-bottom:1px solid #e8edf3;background:transparent;}" +
      "#bx-cashback-root .bx-cb-pair{font-size:16px;font-weight:700;color:#0f172a;}" +
      "#bx-cashback-root .bx-cb-when{font-size:13px;color:#64748b;margin-top:4px;}" +
      "#bx-cashback-root .bx-cb-amt{font-size:18px;font-weight:700;white-space:nowrap;color:#0f172a;}" +
      "#bx-cashback-root .bx-cb-panel{background:#fff;border:1px solid #e8edf3;border-radius:14px;padding:16px;margin:0 0 14px;}" +
      "#bx-cashback-root .bx-cb-msg{font-size:14px;color:#475569;margin:8px 0;}" +
      "#bx-cashback-root .bx-cb-err{color:#b42318;}";
    document.head.appendChild(st);
  }

  function ensureRoot() {
    ensureStyle();
    var el = document.getElementById("bx-cashback-root");
    if (el) return el;
    el = document.createElement("div");
    el.id = "bx-cashback-root";
    document.body.appendChild(el);
    return el;
  }

  function hide() {
    var el = document.getElementById("bx-cashback-root");
    if (el) el.style.display = "none";
    showTransfer = false;
  }

  function goBack() {
    if (showTransfer) {
      showTransfer = false;
      render();
      return;
    }
    hide();
    if (window.history.length > 1) history.back();
    else location.href = "/dashboard";
  }

  function backSvg() {
    return (
      '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' +
      '<path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/>' +
      "</svg>"
    );
  }

  function shell(body) {
    return (
      '<div class="bx-cb-bar">' +
      '<button id="bxCbBack" class="bx-cb-back" type="button" aria-label="Go back">' +
      backSvg() +
      "</button>" +
      '<div class="bx-cb-title">Cashback</div></div>' +
      '<div class="bx-cb-wrap">' +
      body +
      "</div>"
    );
  }

  function rowHtml(item) {
    var alias = String(item.alias || "");
    var when = splitWhen(item.created_at);
    return (
      '<div class="bx-cb-row">' +
      '<div style="min-width:0">' +
      '<div class="bx-cb-pair">' +
      alias +
      "</div>" +
      '<div class="bx-cb-when">' +
      (when.date || "") +
      (when.time ? " · " + when.time : "") +
      "</div></div>" +
      '<div class="bx-cb-amt">' +
      money(item.amount) +
      "</div></div>"
    );
  }

  function pill(id, label) {
    return (
      '<button type="button" class="bx-cb-pill' +
      (period === id ? " on" : "") +
      '" data-period="' +
      id +
      '">' +
      label +
      "</button>"
    );
  }

  function accountLabel(a) {
    return String(a.account_number || a.id || "") + " · " + money(a.balance);
  }

  function render() {
    var el = ensureRoot();
    if (!isCashback() || window.__bxCashbackEnabled === false) {
      hide();
      return;
    }
    var data = lastData || {};
    var items = data.items || [];
    var total = data.total || "0.00";
    var wallet = data.wallet_balance || (transferMeta && transferMeta.wallet_balance) || "0.00";
    var accounts = (transferMeta && transferMeta.trading_accounts) || [];
    var body;

    if (showTransfer) {
      var opts = accounts
        .map(function (a) {
          return (
            '<option value="TRADING:' +
            a.id +
            '">' +
            accountLabel(a) +
            "</option>"
          );
        })
        .join("");
      body =
        '<div class="bx-cb-panel">' +
        '<div class="bx-cb-total-label">Transfer cashback</div>' +
        '<div class="bx-cb-msg">Available in wallet: <strong>' +
        money(wallet) +
        "</strong></div>" +
        (accounts.length
          ? '<label class="bx-cb-msg" style="display:block">Trading account' +
            '<select id="bxCbAcct" class="bx-cb-field" style="width:100%;margin-top:6px">' +
            opts +
            "</select></label>" +
            '<label class="bx-cb-msg" style="display:block;margin-top:10px">Amount' +
            '<input id="bxCbAmt" class="bx-cb-field" type="number" step="0.01" min="0.01" value="' +
            String(wallet) +
            '" style="width:100%;margin-top:6px"></label>' +
            '<p id="bxCbXferMsg" class="bx-cb-msg"></p>' +
            '<button id="bxCbXferGo" class="bx-cb-btn" type="button" style="margin-top:8px">Transfer</button>'
          : '<p class="bx-cb-msg">No live trading account found. Open an account first.</p>') +
        "</div>";
    } else {
      var list =
        items.length === 0
          ? '<p class="bx-cb-msg">No cashback in this period.</p>'
          : items.map(rowHtml).join("");
      var custom =
        period === "custom"
          ? '<div class="bx-cb-custom">' +
            '<label>From<input id="bxCbFrom" type="date" value="' +
            dateFrom +
            '"></label>' +
            '<label>To<input id="bxCbTo" type="date" value="' +
            dateTo +
            '"></label>' +
            '<button id="bxCbCustomGo" class="bx-cb-btn" type="button" style="width:auto;padding:10px 16px">Apply</button></div>'
          : "";
      body =
        '<div class="bx-cb-total">' +
        '<div class="bx-cb-total-label">Total cashback</div>' +
        '<div class="bx-cb-total-amt">' +
        money(total) +
        "</div></div>" +
        '<button id="bxCbTransfer" class="bx-cb-btn" type="button">Transfer</button>' +
        '<div class="bx-cb-pills">' +
        pill("today", "Today") +
        pill("7d", "Last 7 days") +
        pill("30d", "Last 30 Days") +
        pill("custom", "Custom") +
        "</div>" +
        custom +
        list;
    }

    el.innerHTML = shell(body);
    el.style.display = "block";
    wire();
  }

  function paint(html) {
    var el = ensureRoot();
    el.innerHTML = html;
    el.style.display = "block";
    wire();
  }

  function wire() {
    var back = document.getElementById("bxCbBack");
    if (back) {
      back.addEventListener("click", function (ev) {
        ev.preventDefault();
        goBack();
      });
    }
    var pills = document.querySelectorAll("#bx-cashback-root [data-period]");
    for (var i = 0; i < pills.length; i++) {
      pills[i].addEventListener("click", function () {
        period = this.getAttribute("data-period") || "30d";
        if (period !== "custom") loadHistory();
        else render();
      });
    }
    var apply = document.getElementById("bxCbCustomGo");
    if (apply) {
      apply.addEventListener("click", function () {
        var f = document.getElementById("bxCbFrom");
        var t = document.getElementById("bxCbTo");
        dateFrom = f ? f.value : "";
        dateTo = t ? t.value : "";
        loadHistory();
      });
    }
    var xfer = document.getElementById("bxCbTransfer");
    if (xfer) {
      xfer.addEventListener("click", function () {
        openTransfer();
      });
    }
    var go = document.getElementById("bxCbXferGo");
    if (go) {
      go.addEventListener("click", submitTransfer);
    }
  }

  function authHeaders() {
    var token = readToken();
    var h = { Accept: "application/json" };
    if (token) h.Authorization = "Token " + token;
    return h;
  }

  async function refreshEnabled() {
    try {
      var res = await fetch(CRM + "/cashback/settings/", { headers: { Accept: "application/json" } });
      var json = await res.json().catch(function () {
        return {};
      });
      var enabled = true;
      if (json && json.data && json.data.enabled === false) enabled = false;
      window.__bxCashbackEnabled = enabled;
      return enabled;
    } catch (e) {
      window.__bxCashbackEnabled = true;
      return true;
    }
  }

  async function openTransfer() {
    showTransfer = true;
    render();
    var token = readToken();
    if (!token) {
      paint(shell('<p class="bx-cb-msg">Sign in to transfer cashback.</p>'));
      return;
    }
    try {
      var res = await fetch(CRM + "/transfers/internal/", { headers: authHeaders() });
      var json = await res.json().catch(function () {
        return {};
      });
      transferMeta = (json && json.data) || {};
      render();
    } catch (e) {
      transferMeta = { trading_accounts: [], wallet_balance: (lastData && lastData.wallet_balance) || "0" };
      render();
    }
  }

  async function submitTransfer() {
    if (transferBusy) return;
    var sel = document.getElementById("bxCbAcct");
    var amtEl = document.getElementById("bxCbAmt");
    var msg = document.getElementById("bxCbXferMsg");
    var to = sel ? sel.value : "";
    var amount = amtEl ? amtEl.value : "";
    if (!to) {
      if (msg) msg.textContent = "Select a trading account.";
      return;
    }
    var n = Number(amount);
    if (!isFinite(n) || n <= 0) {
      if (msg) msg.textContent = "Enter an amount greater than zero.";
      return;
    }
    var uid = (transferMeta && transferMeta.request_uid) || "";
    transferBusy = true;
    var go = document.getElementById("bxCbXferGo");
    if (go) go.disabled = true;
    if (msg) {
      msg.className = "bx-cb-msg";
      msg.textContent = "Transferring…";
    }
    try {
      var res = await fetch(CRM + "/transfers/internal/", {
        method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, authHeaders()),
        body: JSON.stringify({
          transfer_type: "WALLET_TO_TRADING",
          from_account: "WALLET",
          to_account: to,
          amount: String(n),
          request_uid: uid,
        }),
      });
      var json = await res.json().catch(function () {
        return {};
      });
      if (!res.ok || json.success === false) {
        if (msg) {
          msg.className = "bx-cb-msg bx-cb-err";
          msg.textContent = json.message || "Transfer failed.";
        }
        return;
      }
      showTransfer = false;
      transferMeta = null;
      await loadHistory();
    } catch (e) {
      if (msg) {
        msg.className = "bx-cb-msg bx-cb-err";
        msg.textContent = "Transfer failed.";
      }
    } finally {
      transferBusy = false;
      var go2 = document.getElementById("bxCbXferGo");
      if (go2) go2.disabled = false;
    }
  }

  async function loadHistory() {
    if (!isCashback()) {
      hide();
      return;
    }
    if (window.__bxCashbackEnabled === false) {
      hide();
      if (window.history.length > 1) history.back();
      else location.href = "/dashboard";
      return;
    }
    paint(shell('<p class="bx-cb-msg">Loading cashback…</p>'));
    var token = readToken();
    if (!token) {
      paint(shell('<p class="bx-cb-msg">Sign in to see cashback.</p>'));
      return;
    }
    var q = "?period=" + encodeURIComponent(period) + "&limit=200";
    if (period === "custom") {
      if (dateFrom) q += "&date_from=" + encodeURIComponent(dateFrom);
      if (dateTo) q += "&date_to=" + encodeURIComponent(dateTo);
    }
    try {
      var res = await fetch(CRM + "/cashback/history/" + q, { headers: authHeaders() });
      var json = await res.json().catch(function () {
        return {};
      });
      if (json && json.data && json.data.enabled === false) {
        window.__bxCashbackEnabled = false;
        hide();
        if (window.history.length > 1) history.back();
        else location.href = "/dashboard";
        return;
      }
      if (!res.ok || json.success === false) {
        paint(shell('<p class="bx-cb-msg">Could not load cashback history.</p>'));
        return;
      }
      lastData = json.data || {};
      render();
    } catch (e) {
      paint(shell('<p class="bx-cb-msg">Could not load cashback history.</p>'));
    }
  }

  async function load() {
    var enabled = await refreshEnabled();
    if (!isCashback()) {
      hide();
      return;
    }
    if (!enabled) {
      hide();
      if (window.history.length > 1) history.back();
      else location.href = "/dashboard";
      return;
    }
    await loadHistory();
  }

  refreshEnabled();
  window.addEventListener("popstate", load);
  window.addEventListener("hashchange", load);
  setInterval(function () {
    var shown = document.getElementById("bx-cashback-root");
    var want = isCashback() && window.__bxCashbackEnabled !== false;
    var visible = shown && shown.style.display !== "none";
    if (want !== !!visible) load();
  }, 400);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", load);
  } else {
    load();
  }
})();
