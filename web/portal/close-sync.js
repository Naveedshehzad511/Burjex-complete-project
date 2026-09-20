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
  var latestPosition = Object.create(null);
  var marketSocket = null;

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
  }

  function observe(obj) {
    var id = idOf(obj);
    if (!id) return;
    if (isClosed(obj)) {
      note(obj);
      return;
    }
    latestPosition[id] = obj;
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
    if (!marketSocket || typeof MessageEvent !== "function") return;
    try {
      marketSocket.dispatchEvent(new MessageEvent("message", {
        data: JSON.stringify({ t: "position_closed", d: closed })
      }));
    } catch (e) {}
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
    if (t === "evts" && d && typeof d === "object") {
      var p = d.p;
      if (Array.isArray(p)) {
        for (var i = 0; i < p.length; i++) observe(p[i]);
      }
    }
  }

  var origAdd = WebSocket.prototype.addEventListener;
  if (typeof origAdd === "function") {
    WebSocket.prototype.addEventListener = function (type, fn, cap) {
      if (String(type).toLowerCase() === "message" && !this.__bxGhostSide) {
        this.__bxGhostSide = true;
        marketSocket = this;
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

  function patchTradeList() {
    try {
      if (!self.A || !A.aZh || !A.aZh.prototype || !A.aZh.prototype.$1) return false;
      if (A.aZh.prototype.__bxGhostPatched) return true;
      var orig = A.aZh.prototype.$1;
      A.aZh.prototype.$1 = function (ctx) {
        try {
          var list = A.cK(this.b);
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

  var tries = 0;
  (function wait() {
    if (patchTradeList() || ++tries > 1200) return;
    setTimeout(wait, 50);
  })();
})();
