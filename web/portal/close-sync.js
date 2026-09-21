/**
 * Ghost-close hook. Does NOT wrap WebSocket, does NOT rewrite frames, does NOT
 * poll GET /positions (that path nulled Trade `d` / open rows).
 *
 * Trade paints the REST open list. WS CLOSED already sets __bxClosedIds and
 * forgets live P/L, but the REST row stayed until refresh / 120s. This:
 *   1. Listens beside Dart (same native MessageEvent) and records real CLOSED.
 *   2. Drops those ids when the Positions list is built.
 *
 * Never marks A/B book or OPEN snapshots closed. Does not replace main.dart.js.
 */
(function () {
  if (window.__bxCloseSync) return;
  window.__bxCloseSync = true;
  window.__bxOpenPositions = window.__bxOpenPositions || Object.create(null);
  window.__bxOpenPositionsReady = window.__bxOpenPositionsReady || false;
  var latestPosition = Object.create(null);
  var marketSocket = null;
  var marketSockets = [];
  var NativeWebSocket = window.WebSocket;
  var openRenderQueued = false;

  function registerSocket(socket) {
    if (!socket || marketSockets.indexOf(socket) >= 0) return;
    marketSockets.push(socket);
    marketSocket = socket;
  }

  function closedIds() {
    if (typeof window.__bxClosedIds !== "object" || !window.__bxClosedIds) {
      window.__bxClosedIds = Object.create(null);
    }
    return window.__bxClosedIds;
  }

  function isClosed(obj) {
    if (!obj || typeof obj !== "object") return false;
    var st = String(obj.status || "").toUpperCase();
    // SL/TP protection first claims the ticket as CLOSE_PENDING. It remains an
    // open position through the configured execution delay, so its Trade row
    // and chart entry/SL/TP overlays must remain visible until terminal close.
    if (st === "CLOSE_PENDING") return false;
    var book = String(obj.book || "").toLowerCase();
    var stateVal = String(obj.state || "").toLowerCase();
    var event = String(obj.event || "").toLowerCase();
    return (
      obj.closing === true ||
      st === "CLOSED" ||
      book === "closed" ||
      stateVal === "closed" ||
      event === "position_closed"
    );
  }

  function idOf(obj) {
    if (!obj || typeof obj !== "object") return "";
    return String(obj.id || obj.positionId || "");
  }

  function note(obj) {
    if (!isClosed(obj)) return;
    var id = idOf(obj);
    if (!id) return;
    closedIds()[id] = 1;
    delete latestPosition[id];
    delete window.__bxOpenPositions[id];
  }

  function observe(obj) {
    var id = idOf(obj);
    if (!id) return;
    if (isClosed(obj)) {
      note(obj);
      return;
    }
    var firstSeen = !latestPosition[id];
    latestPosition[id] = obj;
    window.__bxOpenPositions[id] = obj;
    if (firstSeen || String(obj.event || "").toLowerCase() === "position_opened") {
      scheduleOpenRender();
    }
  }

  // The compiled Trade+ portal mutates its active-position projection from a
  // WS frame. Its parent widgets may not rebuild because no REST state changed
  // (notably when REST has a stale/expired session). Rebuild just those two
  // stateful surfaces on an OPEN frame after Flutter has consumed it.
  function scheduleOpenRender() {
    if (openRenderQueued) return;
    openRenderQueued = true;
    setTimeout(function () {
      openRenderQueued = false;
      ["__bxTradeState", "__bxChartState"].forEach(function (key) {
        var state = window[key];
        try {
          if (state && typeof state.u === "function") state.u(function () {});
        } catch (e) {}
      });
    }, 0);
  }

  // A successful HTTP close has already committed server-side. Replay the
  // terminal frame into the native Flutter listener so Chart, Trade, and the
  // live floating-PnL cache converge immediately rather than waiting for a
  // later WS delivery/reconnect.
  function dispatchTerminalClose(id) {
    if (!id) return;
    var prior = latestPosition[id] || {};
    var closed = Object.assign({}, prior, {
      id: prior.id || id,
      positionId: prior.positionId || prior.id || id,
      status: "CLOSED",
      book: "closed",
      closing: true,
      event: "position_closed"
    });
    note(closed);
    if (!marketSockets.length || typeof MessageEvent !== "function") return;
    var event = new MessageEvent("message", {
        data: JSON.stringify({ t: "position_closed", d: closed })
      });
    for (var i = 0; i < marketSockets.length; i++) {
      var socket = marketSockets[i];
      try {
        // Some Flutter browser channels install onmessage; others use
        // addEventListener. Deliver to both paths so the terminal frame reaches
        // the same compiled handler the real server frame uses.
        if (typeof socket.onmessage === "function") socket.onmessage(event);
        socket.dispatchEvent(event);
      } catch (e) {}
    }
  }

  function noteFrame(raw) {
    if (typeof raw !== "string") return;
    var msg;
    try {
      msg = JSON.parse(raw);
    } catch (e) {
      return;
    }
    if (!msg || typeof msg !== "object") return;
    var t = msg.t;
    var d = msg.d;
    if (t === "position" || t === "position_closed") {
      observe(d);
      return;
    }
    if (t === "positions" && d && typeof d === "object") {
      var snapshot = Array.isArray(d.positions) ? d.positions : [];
      window.__bxOpenPositionsReady = true;
      window.__bxOpenPositions = Object.create(null);
      for (var j = 0; j < snapshot.length; j++) observe(snapshot[j]);
      return;
    }
    if (t === "evts" && d && typeof d === "object") {
      var p = d.p;
      if (Array.isArray(p)) {
        for (var i = 0; i < p.length; i++) observe(p[i]);
      }
    }
  }

  var origAdd = NativeWebSocket && NativeWebSocket.prototype.addEventListener;
  if (typeof origAdd === "function") {
    NativeWebSocket.prototype.addEventListener = function (type, fn, cap) {
      if (String(type).toLowerCase() === "message" && !this.__bxGhostSide) {
        this.__bxGhostSide = true;
        registerSocket(this);
        origAdd.call(this, "message", function (ev) {
          try {
            noteFrame(ev && ev.data);
          } catch (e) {}
        });
      }
      return origAdd.call(this, type, fn, cap);
    };
  }

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    window.fetch = function (input, init) {
      var method = String((init && init.method) || (input && input.method) || "GET").toUpperCase();
      var url = typeof input === "string" ? input : (input && input.url) || "";
      var match = method === "POST" && String(url).match(/\/positions\/([^/?#]+)\/close(?:[/?#]|$)/);
      var result = nativeFetch.apply(this, arguments);
      if (match && result && typeof result.then === "function") {
        result.then(function (response) {
          if (response && response.ok) dispatchTerminalClose(match[1]);
        }).catch(function () {});
      }
      return result;
    };
  }

  var NativeXhr = window.XMLHttpRequest;
  if (typeof NativeXhr === "function") {
    var xhrOpen = NativeXhr.prototype.open;
    var xhrSend = NativeXhr.prototype.send;
    NativeXhr.prototype.open = function (method, url) {
      this.__bxCloseMethod = String(method || "GET").toUpperCase();
      this.__bxCloseUrl = String(url || "");
      return xhrOpen.apply(this, arguments);
    };
    NativeXhr.prototype.send = function () {
      var xhr = this;
      var match = xhr.__bxCloseMethod === "POST" &&
        xhr.__bxCloseUrl.match(/\/positions\/([^/?#]+)\/close(?:[/?#]|$)/);
      if (match && !xhr.__bxCloseObserved) {
        xhr.__bxCloseObserved = true;
        xhr.addEventListener("loadend", function () {
          if (xhr.status >= 200 && xhr.status < 300) dispatchTerminalClose(match[1]);
        });
      }
      return xhrSend.apply(this, arguments);
    };
  }

  function posId(row) {
    if (!row) return "";
    if (typeof row.a === "string" && row.a) return row.a;
    return String(row.id || row.positionId || "");
  }

  function filterClosedList(list) {
    var ids = window.__bxClosedIds;
    if (!ids || !list || typeof list.length !== "number") return;
    for (var i = list.length - 1; i >= 0; i--) {
      var id = posId(list[i]);
      if (id && ids[id]) {
        try {
          list.splice(i, 1);
        } catch (e) {}
      }
    }
  }

  function mergeOpenList(list) {
    if (!list || typeof list.length !== "number" || !self.A || !A.b9F) return;
    var open = window.__bxOpenPositions;
    if (!open) return;
    Object.keys(open).forEach(function (id) {
      if (closedIds()[id]) return;
      var exists = false;
      for (var i = 0; i < list.length; i++) {
        if (String(posId(list[i])) === id) {
          exists = true;
          break;
        }
      }
      if (exists) return;
      try {
        list.push(new A.b9F().$1(open[id]));
      } catch (e) {}
    });
  }

  function patchTradeList() {
    try {
      if (!self.A || !A.aZh || !A.aZh.prototype || !A.aZh.prototype.$1) return false;
      if (A.aZh.prototype.__bxGhostPatched) return true;
      var orig = A.aZh.prototype.$1;
      A.aZh.prototype.$1 = function (ctx) {
        try {
          var list = A.cK(this.b);
          mergeOpenList(list);
          filterClosedList(list);
        } catch (e) {}
        return orig.call(this, ctx);
      };
      A.aZh.prototype.__bxGhostPatched = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  function patchOpenRenderStates() {
    try {
      if (!self.A) return false;
      var trade = A.a8Y && A.a8Y.prototype;
      var chart = A.aNv && A.aNv.prototype;
      if (!trade || typeof trade.F !== "function" || !chart || typeof chart.F !== "function") return false;
      if (!trade.__bxOpenRenderPatched) {
        var tradeF = trade.F;
        trade.F = function (ctx) {
          window.__bxTradeState = this;
          return tradeF.call(this, ctx);
        };
        trade.__bxOpenRenderPatched = true;
      }
      if (!chart.__bxOpenRenderPatched) {
        var chartF = chart.F;
        chart.F = function (ctx) {
          window.__bxChartState = this;
          return chartF.call(this, ctx);
        };
        chart.__bxOpenRenderPatched = true;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  var tries = 0;
  (function wait() {
    if (patchTradeList() && patchOpenRenderStates() || ++tries > 1200) return;
    setTimeout(wait, 50);
  })();
})();
