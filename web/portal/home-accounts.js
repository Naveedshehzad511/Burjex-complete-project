/**
 * Trade+ Home enhancement.
 *
 * The shipped portal is a compiled Flutter bundle. This lightweight shell is
 * limited to /dashboard, reuses its authenticated CRM data, and hands every
 * other route back to Flutter. It keeps the Home data path off trading/quotes.
 */
(function () {
  if (window.__bxPortalHomeAccounts) return;
  window.__bxPortalHomeAccounts = true;

  var CRM = "https://crm.burjexprime.net/api/v1";
  var rootId = "bx-portal-home";
  var state = { index: 0, accounts: [], events: [] };

  function isHome() {
    var path = (location.pathname || "/").replace(/\/+$/, "") || "/";
    var hash = location.hash || "";
    return path === "/dashboard" || hash.indexOf("/dashboard") >= 0;
  }

  function token() {
    try {
      var raw = localStorage.getItem("flutter.crm_access_token_prefs");
      if (!raw) raw = localStorage.getItem("flutter.crm_access_token");
      if (!raw) return "";
      var value = JSON.parse(raw);
      return typeof value === "string" ? value : String((value && (value.token || value.access || value.value)) || "");
    } catch (error) {
      return "";
    }
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (character) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character];
    });
  }

  function money(value, currency) {
    var amount = Number(value || 0);
    if (!Number.isFinite(amount)) amount = 0;
    return amount.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " " + (currency || "USD");
  }

  function route(path) {
    history.pushState({}, "", path);
    window.dispatchEvent(new PopStateEvent("popstate"));
    hide();
  }

  function root() {
    var element = document.getElementById(rootId);
    if (element) return element;
    element = document.createElement("main");
    element.id = rootId;
    element.setAttribute("aria-label", "Burjex Prime Home");
    element.style.cssText =
      "display:none;position:fixed;inset:0;z-index:2147483000;overflow:auto;background:#f5f7fb;color:#122033;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;";
    document.body.appendChild(element);
    return element;
  }

  function accountCard(account) {
    var demo = String(account.base_account_type || "").toUpperCase() === "DEMO";
    var type = escapeHtml(account.account_type || (demo ? "Demo" : "Live"));
    var label = demo ? "Demo" : "Live";
    return (
      '<article class="bx-home-account" aria-label="' + label + " account " + escapeHtml(account.login_id || account.account_number || "") + '">' +
      '<div class="bx-account-top"><span class="bx-account-kind ' + (demo ? "is-demo" : "") + '">' + label + '</span><span>' + type + "</span></div>" +
      '<div class="bx-account-number">#' + escapeHtml(account.login_id || account.account_number || "—") + "</div>" +
      '<div class="bx-account-metrics"><div><span>Balance</span><strong>' + money(account.balance, account.currency) + "</strong></div>" +
      "<div><span>Equity</span><strong>" + money(account.equity, account.currency) + "</strong></div>" +
      "<div><span>Leverage</span><strong>1:" + escapeHtml(account.leverage || "—") + "</strong></div></div>" +
      '<div class="bx-account-actions"><button type="button" data-route="/deposit">Deposit</button><button type="button" data-route="/withdraw">Withdraw</button><button type="button" data-route="/trade">Trade</button></div>' +
      "</article>"
    );
  }

  function marketEventsHtml() {
    if (!state.events.length) {
      return '<div class="bx-empty-events">No high-impact Forex Factory events scheduled today.</div>';
    }
    return state.events
      .map(function (event) {
        return (
          '<div class="bx-event"><time>' + escapeHtml(event.time || "—") + "</time>" +
          '<span class="bx-currency">' + escapeHtml(event.currency || "FX") + "</span>" +
          '<span class="bx-impact" aria-label="High impact">High</span>' +
          '<span class="bx-event-title">' + escapeHtml(event.title || "Economic event") + "</span></div>"
        );
      })
      .join("");
  }

  function drawerHtml() {
    return (
      '<aside class="bx-drawer" aria-label="Portal navigation">' +
      '<div class="bx-drawer-head"><strong>Burjex Prime</strong><button type="button" class="bx-close-drawer" aria-label="Close menu">×</button></div>' +
      '<button type="button" data-route="/dashboard">Dashboard</button>' +
      '<details open><summary>My Fund</summary><div class="bx-submenu"><button type="button" data-route="/deposit">Deposit</button><button type="button" data-route="/withdraw">Withdraw</button><button type="button" data-route="/transfer">Internal Transfer</button><button type="button" data-route="/transactions">Transactions</button></div></details>' +
      '<button type="button" data-route="/wallet">My Wallet</button><button type="button" data-route="/compliance">KYC</button><button type="button" data-route="/cashback">Cashback</button>' +
      '<details><summary>IB Programme</summary><div class="bx-submenu"><button type="button" data-route="/ib">IB Dashboard</button><button type="button" data-route="/ib-progress">IB Progress</button><button type="button" data-route="/ib-clients">My Clients</button><button type="button" data-route="/ib-commission">My Commission</button></div></details>' +
      '<details><summary>My Data</summary><div class="bx-submenu"><button type="button" data-route="/deposit-report">Deposit Report</button><button type="button" data-route="/withdraw-report">Withdraw Report</button><button type="button" data-route="/deal-report">Deal Report</button></div></details>' +
      '<button type="button" data-route="/competition">Competition</button><button type="button" data-route="/trade-and-win">Trade And Win</button><button type="button" data-route="/legal">Legal Agreements</button>' +
      '<button type="button" class="bx-help" data-route="/support"><strong>Need Help?</strong><span>Our support team is available 24/7.</span></button></aside>'
    );
  }

  function styles() {
    return (
      "<style>" +
      "#bx-portal-home *{box-sizing:border-box}#bx-portal-home button{font:inherit}#bx-portal-home .bx-home-shell{max-width:680px;margin:0 auto;padding:18px 16px 92px}.bx-home-header{display:flex;align-items:center;justify-content:space-between;margin:0 0 18px}.bx-menu,.bx-avatar{width:42px;height:42px;border:0;border-radius:14px;background:#fff;color:#10233d;box-shadow:0 5px 18px rgba(15,38,68,.08);font-size:22px;cursor:pointer}.bx-avatar{display:grid;place-items:center;background:#092f5b;color:#fff;font-size:14px;font-weight:800}.bx-greeting small,.bx-section-heading p{display:block;color:#67758a;font-size:12px;margin:0}.bx-greeting strong{display:block;font-size:18px;margin-top:2px}.bx-section-heading{display:flex;justify-content:space-between;align-items:end;margin:24px 2px 10px}.bx-section-heading h1,.bx-section-heading h2{font-size:17px;margin:0;color:#10233d}.bx-account-viewport{overflow:hidden;border-radius:20px}.bx-account-track{display:flex;transition:transform .28s ease}.bx-home-account{flex:0 0 100%;padding:20px;border-radius:20px;background:linear-gradient(135deg,#082e59,#0e5a8b);color:#fff;box-shadow:0 14px 28px rgba(8,46,89,.18)}.bx-account-top{display:flex;justify-content:space-between;gap:12px;font-size:12px;color:#c9e2f4}.bx-account-kind{background:#12aa73;color:#fff;border-radius:99px;padding:4px 9px;font-weight:750}.bx-account-kind.is-demo{background:#8870d6}.bx-account-number{font-size:24px;font-weight:800;margin:14px 0 18px;letter-spacing:.02em}.bx-account-metrics{display:grid;grid-template-columns:1.2fr 1.2fr .7fr;gap:8px}.bx-account-metrics span{display:block;color:#b7d4e8;font-size:11px}.bx-account-metrics strong{font-size:13px;display:block;margin-top:4px;white-space:nowrap}.bx-account-actions{display:flex;gap:8px;margin-top:19px}.bx-account-actions button{flex:1;border:1px solid rgba(255,255,255,.24);background:rgba(255,255,255,.12);border-radius:10px;padding:9px;color:#fff;font-size:12px;font-weight:700;cursor:pointer}.bx-dots{display:flex;justify-content:center;gap:6px;margin:12px 0 2px}.bx-dot{width:7px;height:7px;border:0;border-radius:99px;background:#c6d0dc;padding:0}.bx-dot.is-active{width:20px;background:#0e5a8b}.bx-quick-actions{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.bx-quick-actions button{padding:13px 8px;border:1px solid #e3e8ef;background:#fff;border-radius:14px;color:#193554;font-size:12px;font-weight:700;box-shadow:0 4px 13px rgba(14,39,70,.04);cursor:pointer}.bx-market-card{background:#fff;border:1px solid #e5eaf0;border-radius:16px;overflow:hidden;box-shadow:0 5px 16px rgba(14,39,70,.04)}.bx-market-caption{padding:11px 14px;background:#f8fafc;color:#708096;font-size:11px;border-bottom:1px solid #edf0f4}.bx-event{display:grid;grid-template-columns:50px 43px 49px 1fr;align-items:center;gap:8px;padding:13px 14px;border-bottom:1px solid #eef1f5;font-size:12px}.bx-event:last-child{border-bottom:0}.bx-event time{font-variant-numeric:tabular-nums;color:#53647a}.bx-currency{font-weight:800;color:#143d68}.bx-impact{font-size:10px;font-weight:800;color:#b44032;background:#fff0ee;padding:3px 5px;border-radius:6px;text-align:center}.bx-event-title{font-weight:600;color:#26384f}.bx-empty-events{padding:20px 14px;color:#6b798b;font-size:13px}.bx-bottom-nav{position:fixed;z-index:2;bottom:0;left:0;right:0;display:flex;justify-content:center;gap:3px;padding:10px 7px calc(10px + env(safe-area-inset-bottom));background:rgba(255,255,255,.96);border-top:1px solid #e5eaf0;backdrop-filter:blur(12px)}.bx-bottom-nav button{min-width:58px;padding:5px 4px;border:0;background:transparent;border-radius:9px;color:#748196;font-size:10px;cursor:pointer}.bx-bottom-nav button:first-child{color:#0b4d82;font-weight:800}.bx-drawer-backdrop{position:fixed;inset:0;background:rgba(3,19,37,.36);z-index:4}.bx-drawer{position:fixed;z-index:5;inset:0 auto 0 0;width:min(330px,86vw);padding:18px 14px;background:#f5f7fb;overflow:auto;box-shadow:12px 0 32px rgba(7,28,54,.22)}.bx-drawer-head{display:flex;justify-content:space-between;align-items:center;padding:6px 7px 18px;color:#0c315b}.bx-close-drawer{border:0;background:transparent;color:#183c62;font-size:28px;line-height:1;cursor:pointer}.bx-drawer>button,.bx-drawer summary,.bx-submenu button{width:100%;border:0;text-align:left;color:#183c62;cursor:pointer}.bx-drawer>button,.bx-drawer summary{margin:7px 0;padding:13px 14px;border-radius:12px;background:#fff;box-shadow:0 3px 11px rgba(15,42,70,.075);font-weight:700;list-style:none}.bx-drawer summary::-webkit-details-marker{display:none}.bx-drawer summary::after{content:'⌄';float:right;color:#7b8ba0}.bx-drawer details[open] summary::after{content:'⌃'}.bx-submenu{margin:-2px 6px 8px;padding:7px;background:#fff;border-radius:0 0 12px 12px;box-shadow:0 5px 13px rgba(15,42,70,.07)}.bx-submenu button{padding:10px 11px;border-radius:8px;background:#f8fafc;margin:2px 0;font-size:12px}.bx-drawer .bx-help{display:block;margin-top:15px;background:#e9f4ff;color:#103a67}.bx-help span{display:block;margin-top:4px;color:#5e7896;font-size:11px;font-weight:500}.bx-loading{padding:48px 18px;text-align:center;color:#65758a}" +
      "</style>"
    );
  }

  function paint(data) {
    var payload = data || {};
    var accounts = Array.isArray(payload.accounts) ? payload.accounts : [];
    state.accounts = accounts;
    state.index = Math.min(state.index, Math.max(accounts.length - 1, 0));
    var user = payload.user || {};
    var name = escapeHtml(user.first_name || user.display_name || "Trader");
    var accountsHtml = accounts.length
      ? accounts.map(accountCard).join("")
      : '<article class="bx-home-account"><div class="bx-account-number">No trading account yet</div><p>Open an account to start trading with Burjex Prime.</p><div class="bx-account-actions"><button type="button" data-route="/open-account">Open account</button></div></article>';
    var dots = accounts.length > 1
      ? accounts.map(function (_, index) { return '<button type="button" class="bx-dot ' + (index === state.index ? "is-active" : "") + '" aria-label="Show account ' + (index + 1) + '" data-account-index="' + index + '"></button>'; }).join("")
      : "";

    root().innerHTML = styles() +
      '<div class="bx-home-shell"><header class="bx-home-header"><button type="button" class="bx-menu" aria-label="Open menu">☰</button><div class="bx-greeting"><small>Welcome back</small><strong>' + name + '</strong></div><button type="button" class="bx-avatar" aria-label="Open wallet" data-route="/wallet">BP</button></header>' +
      '<section><div class="bx-section-heading"><h1>Account List</h1><p>' + (accounts.length ? accounts.length + " account" + (accounts.length === 1 ? "" : "s") : "Get started") + '</p></div><div class="bx-account-viewport"><div class="bx-account-track">' + accountsHtml + "</div></div><div class=\"bx-dots\">" + dots + "</div></section>" +
      '<section class="bx-quick-actions"><button type="button" data-route="/open-account">Open account</button><button type="button" data-route="/deposit">Deposit</button><button type="button" data-route="/compliance">Complete KYC</button></section>' +
      '<section><div class="bx-section-heading"><div><h2>Market Insight</h2><p>Daily major Forex Factory events</p></div></div><div class="bx-market-card"><div class="bx-market-caption">TIME &nbsp;&nbsp; CURRENCY &nbsp;&nbsp; IMPACT &nbsp;&nbsp; EVENT</div>' + marketEventsHtml() + "</div></section></div>" +
      '<nav class="bx-bottom-nav" aria-label="Trading navigation"><button type="button">Home</button><button type="button" data-route="/quotes">Quotes</button><button type="button" data-route="/chart">Chart</button><button type="button" data-route="/trade">Trade</button><button type="button" data-route="/history">History</button></nav>';
    root().style.display = "block";
    bind();
    updateCarousel();
  }

  function updateCarousel() {
    var track = root().querySelector(".bx-account-track");
    if (track) track.style.transform = "translateX(-" + (state.index * 100) + "%)";
    Array.prototype.forEach.call(root().querySelectorAll(".bx-dot"), function (dot, index) {
      dot.classList.toggle("is-active", index === state.index);
    });
  }

  function openDrawer() {
    var element = root();
    var old = element.querySelector(".bx-drawer-backdrop");
    if (old) return;
    var backdrop = document.createElement("div");
    backdrop.className = "bx-drawer-backdrop";
    backdrop.innerHTML = drawerHtml();
    element.appendChild(backdrop);
    backdrop.addEventListener("click", function (event) {
      if (event.target === backdrop || event.target.closest(".bx-close-drawer")) backdrop.remove();
    });
    bind(backdrop);
  }

  function bind(scope) {
    var element = scope || root();
    Array.prototype.forEach.call(element.querySelectorAll("[data-route]"), function (button) {
      button.onclick = function () { route(button.getAttribute("data-route")); };
    });
    Array.prototype.forEach.call(element.querySelectorAll("[data-account-index]"), function (button) {
      button.onclick = function () { state.index = Number(button.getAttribute("data-account-index")); updateCarousel(); };
    });
    var menu = element.querySelector(".bx-menu");
    if (menu) menu.onclick = openDrawer;
    var viewport = element.querySelector(".bx-account-viewport");
    if (viewport) {
      var startX = null;
      viewport.ontouchstart = function (event) { startX = event.changedTouches[0].clientX; };
      viewport.ontouchend = function (event) {
        if (startX == null || state.accounts.length < 2) return;
        var distance = event.changedTouches[0].clientX - startX;
        if (Math.abs(distance) > 35) {
          state.index = (state.index + (distance < 0 ? 1 : -1) + state.accounts.length) % state.accounts.length;
          updateCarousel();
        }
        startX = null;
      };
    }
  }

  function hide() {
    var element = document.getElementById(rootId);
    if (element) element.style.display = "none";
  }

  async function load() {
    if (!isHome()) {
      hide();
      return;
    }
    var accessToken = token();
    if (!accessToken) {
      hide();
      return;
    }
    root().innerHTML = styles() + '<div class="bx-loading">Loading your Home…</div>';
    root().style.display = "block";
    var headers = { Authorization: "Token " + accessToken, Accept: "application/json" };
    try {
      var results = await Promise.all([
        fetch(CRM + "/dashboard/", { headers: headers }),
        fetch(CRM + "/market-events/", { headers: headers }),
      ]);
      var dashboard = await results[0].json();
      var market = await results[1].json().catch(function () { return {}; });
      if (!results[0].ok || dashboard.success === false) throw new Error("Dashboard request failed");
      state.events = market && market.success && market.data && Array.isArray(market.data.events) ? market.data.events : [];
      paint(dashboard.data || {});
    } catch (error) {
      root().innerHTML = styles() + '<div class="bx-home-shell"><div class="bx-loading">Home could not be refreshed. <button type="button" id="bxHomeRetry">Try again</button></div></div>';
      root().style.display = "block";
      var retry = document.getElementById("bxHomeRetry");
      if (retry) retry.onclick = load;
    }
  }

  window.addEventListener("popstate", load);
  window.addEventListener("hashchange", load);
  setInterval(function () {
    var visible = document.getElementById(rootId);
    if (isHome() !== !!(visible && visible.style.display !== "none")) load();
  }, 450);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", load);
  else load();
})();
