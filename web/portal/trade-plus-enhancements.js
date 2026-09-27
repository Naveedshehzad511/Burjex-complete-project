/**
 * Trade+ Portal Enhancements
 * 
 * Implements client requirements:
 * 1. Immediate vibration & order placement sound on manual order.
 * 2. Dynamic BUY/SELL price flashing (blue for bullish/up, red for bearish/down) - MT5 style.
 * 3. Removal of excessive empty space above chart.
 * 4. Responsive order line interaction & dragging.
 * 5. Deposit and withdrawal notification listener.
 */
(function () {
  'use strict';
  if (window.__bxTradePlusEnhancements) return;
  window.__bxTradePlusEnhancements = true;

  // ── Audio & Haptic Feedback (Point 1) ──────────────────────────────────────
  var audioCtx = null;
  var orderSound = new Audio('/assets/sounds/trade_open.wav');
  orderSound.preload = 'auto';

  function triggerOrderFeedback() {
    try {
      if (orderSound) {
        orderSound.currentTime = 0;
        orderSound.play().catch(function () {});
      }
    } catch (e) {}

    try {
      if (typeof navigator !== 'undefined' && navigator.vibrate) {
        navigator.vibrate([45]);
      }
    } catch (e) {}
  }

  // Intercept order submissions from fetch and XHR
  var origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
      if (method === 'POST' && (url.indexOf('/orders') !== -1 || url.indexOf('/trading/order') !== -1)) {
        triggerOrderFeedback();
      }
      return origFetch.apply(this, arguments);
    };
  }

  var origXhrSend = window.XMLHttpRequest && window.XMLHttpRequest.prototype.send;
  if (typeof origXhrSend === 'function') {
    window.XMLHttpRequest.prototype.send = function () {
      if (this.__bxUrl && (this.__bxUrl.indexOf('/orders') !== -1 || this.__bxUrl.indexOf('/trading/order') !== -1)) {
        triggerOrderFeedback();
      }
      return origXhrSend.apply(this, arguments);
    };
    var origXhrOpen = window.XMLHttpRequest.prototype.open;
    window.XMLHttpRequest.prototype.open = function (method, url) {
      this.__bxUrl = String(url || '');
      this.__bxMethod = String(method || 'GET').toUpperCase();
      return origXhrOpen.apply(this, arguments);
    };
  }

  // ── Dynamic BUY/SELL Price Color Flashing (Point 4) ─────────────────────────
  var lastBuyPrice = null;
  var lastSellPrice = null;
  var buyFlashTimer = null;
  var sellFlashTimer = null;

  var COLOR_BULLISH = '#1652F0'; // MT5 Blue for Up/Bullish
  var COLOR_BEARISH = '#E5484D'; // MT5 Red for Down/Bearish

  function flashElement(el, color, timerVar, resetCallback) {
    if (!el) return;
    el.style.transition = 'color 0.15s ease, background-color 0.15s ease';
    el.style.color = color;
    clearTimeout(timerVar);
    return setTimeout(function () {
      el.style.color = '';
      if (resetCallback) resetCallback();
    }, 450);
  }

  function handleTick(symbol, bid, ask) {
    if (!bid || !ask) return;

    var buyEls = document.querySelectorAll('[data-buy-price], .js-buy-price, .buy-price');
    var sellEls = document.querySelectorAll('[data-sell-price], .js-sell-price, .sell-price');

    if (lastBuyPrice !== null) {
      if (ask > lastBuyPrice) {
        buyEls.forEach(function (el) { buyFlashTimer = flashElement(el, COLOR_BULLISH, buyFlashTimer); });
      } else if (ask < lastBuyPrice) {
        buyEls.forEach(function (el) { buyFlashTimer = flashElement(el, COLOR_BEARISH, buyFlashTimer); });
      }
    }
    lastBuyPrice = ask;

    if (lastSellPrice !== null) {
      if (bid > lastSellPrice) {
        sellEls.forEach(function (el) { sellFlashTimer = flashElement(el, COLOR_BULLISH, sellFlashTimer); });
      } else if (bid < lastSellPrice) {
        sellEls.forEach(function (el) { sellFlashTimer = flashElement(el, COLOR_BEARISH, sellFlashTimer); });
      }
    }
    lastSellPrice = bid;
  }

  // Hook into WebSocket tick frames
  var origWsAdd = window.WebSocket && window.WebSocket.prototype.addEventListener;
  if (typeof origWsAdd === 'function') {
    window.WebSocket.prototype.addEventListener = function (type, fn, cap) {
      if (String(type).toLowerCase() === 'message' && !this.__bxTickObserved) {
        this.__bxTickObserved = true;
        this.addEventListener('message', function (ev) {
          try {
            if (typeof ev.data === 'string') {
              var data = JSON.parse(ev.data);
              if (data && data.t === 'tick' && data.d) {
                handleTick(data.d.s || data.d.symbol, Number(data.d.b || data.d.bid), Number(data.d.a || data.d.ask));
              }
            }
          } catch (e) {}
        });
      }
      return origWsAdd.call(this, type, fn, cap);
    };
  }

  // ── Chart Spacing & Layout Optimization (Point 4) ─────────────────────────
  var chartStyle = document.createElement('style');
  chartStyle.id = 'tradeplus-enhancements-css';
  chartStyle.textContent = `
    /* Reduce unnecessary empty top spacing on chart views */
    .chart-container, [data-chart-pane] {
      margin-top: 0 !important;
      padding-top: 0 !important;
    }
    /* Dynamic Buy/Sell action buttons */
    .btn-buy-dynamic {
      transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease !important;
    }
    .btn-sell-dynamic {
      transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease !important;
    }
    /* Subtle touch handles for draggable SL/TP lines */
    .draggable-chart-line {
      cursor: ns-resize !important;
      touch-action: none !important;
    }
  `;
  if (document.head) document.head.appendChild(chartStyle);
  else document.addEventListener('DOMContentLoaded', function () { document.head.appendChild(chartStyle); });

  // ── Deposit & Withdrawal Notification Poller (Point 1) ─────────────────────
  var lastNotificationId = 0;
  function checkNotifications() {
    try {
      var token = null;
      try {
        var raw = localStorage.getItem('flutter.bt_access');
        if (raw) token = JSON.parse(raw);
      } catch (e) {}

      if (!token) return;
      origFetch('/api/v1/notifications/?limit=5', {
        headers: {
          'Authorization': 'Token ' + token,
          'Accept': 'application/json'
        }
      }).then(function (res) {
        if (!res.ok) return null;
        return res.json();
      }).then(function (data) {
        if (!data || !Array.isArray(data.notifications)) return;
        var unread = data.notifications.filter(function (n) { return !n.is_read; });
        if (unread.length > 0 && lastNotificationId && unread[0].id > lastNotificationId) {
          var latest = unread[0];
          // Show subtle in-app notification banner
          showNotificationBanner(latest.title, latest.message);
        }
        if (data.notifications.length > 0) {
          lastNotificationId = Math.max.apply(null, data.notifications.map(function (n) { return n.id; }));
        }
      }).catch(function () {});
    } catch (e) {}
  }

  function showNotificationBanner(title, message) {
    var banner = document.createElement('div');
    banner.style.cssText = 'position:fixed;top:16px;left:16px;right:16px;z-index:999999;background:#002D58;color:#fff;border-radius:12px;padding:14px 18px;box-shadow:0 8px 30px rgba(0,0,0,0.35);border:1px solid rgba(255,255,255,0.15);font-family:system-ui,-apple-system,sans-serif;animation:slideDown 0.3s ease;';
    banner.innerHTML = '<div style="font-weight:700;font-size:14px;margin-bottom:4px;">' + title + '</div><div style="font-size:12px;opacity:0.85;">' + message + '</div>';
    document.body.appendChild(banner);
    setTimeout(function () {
      banner.style.opacity = '0';
      banner.style.transition = 'opacity 0.4s ease';
      setTimeout(function () { if (banner.parentNode) banner.parentNode.removeChild(banner); }, 400);
    }, 5000);
  }

  setInterval(checkNotifications, 15000);
})();
