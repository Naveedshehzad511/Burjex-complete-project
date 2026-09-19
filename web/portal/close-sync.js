/**
 * Keep the Trade+ screen in lockstep with the server: once a ticket is CLOSED
 * (or claimed for SL/TP), it must not stay painted. Wraps WebSocket so Flutter
 * cannot miss/overwrite a close, and polls GET /v1/positions so a dropped WS
 * frame cannot leave a ghost row.
 *
 * Does not replace main.dart.js (Home / Quotes / Chart / Trade / History).
 */
(function () {
  if (window.__bxCloseSync) return;
  window.__bxCloseSync = true;
  window.__bxClosedIds = window.__bxClosedIds || Object.create(null);

  function mark(id) {
    if (!id) return;
    window.__bxClosedIds[id] = 1;
  }

  function isClosed(p) {
    if (!p || typeof p !== "object") return false;
    var st = String(p.status || "").toUpperCase();
    var book = String(p.book || "").toLowerCase();
    var reason = String(p.reason || "").toUpperCase();
    var kind = String(p.execClaimKind || "").toLowerCase();
    var stateVal = String(p.state || "").toLowerCase();
    return (
      p.closing === true ||
      st === "CLOSED" ||
      book === "closed" ||
      stateVal === "closed" ||
      reason === "SL_HIT" ||
      reason === "TP_HIT" ||
      kind === "sl" ||
      kind === "tp"
    );
  }

  function posId(p) {
    return p ? String(p.id || p.positionId || "") : "";
  }

  function forceClosed(p) {
    var id = posId(p);
    return Object.assign({}, p || {}, {
      id: id,
      positionId: id,
      status: "CLOSED",
      book: "closed",
      closing: true,
    });
  }

  function rewritePos(p) {
    if (!p || typeof p !== "object") return p;
    var id = posId(p);
    if (isClosed(p)) {
      mark(id);
      return forceClosed(p);
    }
    if (id && window.__bxClosedIds[id]) return forceClosed(p);
    return p;
  }

  function rewriteFrame(obj) {
    if (!obj || typeof obj !== "object") return obj;
    if (obj.t === "position") {
      return Object.assign({}, obj, { d: rewritePos(obj.d) });
    }
    if (obj.t === "evts" && obj.d) {
      var d = Object.assign({}, obj.d);
      if (Array.isArray(d.p)) d.p = d.p.map(rewritePos);
      return Object.assign({}, obj, { d: d });
    }
    return obj;
  }

  function token() {
    try {
      var v = localStorage.getItem("flutter.bt_access");
      if (!v) return "";
      var p = JSON.parse(v);
      return typeof p === "string" ? p : "";
    } catch (e) {
      return "";
    }
  }

  var Orig = window.WebSocket;
  function BxWS(url, protocols) {
    var ws = protocols !== undefined ? new Orig(url, protocols) : new Orig(url);
    var msgFns = [];
    var onMsg = null;
    var nativeOn = false;
    var accounts = Object.create(null);
    var lastOpen = Object.create(null);
    var pollTimer = null;

    function patchedData(raw) {
      try {
        var obj = JSON.parse(raw);
        noteOpenFromFrame(obj);
        return JSON.stringify(rewriteFrame(obj));
      } catch (e) {
        return raw;
      }
    }

    function fire(data) {
      var ev = new MessageEvent("message", { data: data });
      for (var i = 0; i < msgFns.length; i++) {
        try {
          msgFns[i](ev);
        } catch (e) {}
      }
      if (typeof onMsg === "function") {
        try {
          onMsg(ev);
        } catch (e) {}
      }
    }

    function ensureNative() {
      if (nativeOn) return;
      nativeOn = true;
      Orig.prototype.addEventListener.call(ws, "message", function (ev) {
        fire(patchedData(ev.data));
      });
    }

    function injectClosed(id, accountId) {
      mark(id);
      fire(
        JSON.stringify({
          t: "position",
          d: {
            id: id,
            positionId: id,
            accountId: accountId,
            status: "CLOSED",
            book: "closed",
            closing: true,
          },
        })
      );
    }

    function noteOpenFromFrame(obj) {
      if (!obj || typeof obj !== "object") return;
      var rows = [];
      if (obj.t === "position") rows = [obj.d];
      else if (obj.t === "evts" && obj.d && Array.isArray(obj.d.p)) rows = obj.d.p;
      for (var i = 0; i < rows.length; i++) {
        var p = rows[i];
        if (!p || isClosed(p)) continue;
        var id = posId(p);
        var acct = p.accountId;
        if (!id || !acct) continue;
        lastOpen[acct] = lastOpen[acct] || Object.create(null);
        lastOpen[acct][id] = 1;
      }
    }

    async function poll() {
      var tok = token();
      var ids = Object.keys(accounts);
      if (!tok || !ids.length) return;
      for (var i = 0; i < ids.length; i++) {
        var acct = ids[i];
        try {
          var r = await fetch(
            "/v1/positions?accountId=" + encodeURIComponent(acct) + "&status=OPEN",
            { headers: { Authorization: "Bearer " + tok } }
          );
          if (!r.ok) continue;
          var list = await r.json();
          if (!Array.isArray(list)) continue;
          var now = Object.create(null);
          for (var j = 0; j < list.length; j++) {
            var id = String(list[j].id || "");
            if (id && !window.__bxClosedIds[id]) now[id] = 1;
          }
          var prev = lastOpen[acct] || Object.create(null);
          Object.keys(prev).forEach(function (id) {
            if (!now[id]) injectClosed(id, acct);
          });
          lastOpen[acct] = now;
        } catch (e) {}
      }
    }

    var origAdd = ws.addEventListener.bind(ws);
    ws.addEventListener = function (type, fn, opt) {
      if (type === "message") {
        ensureNative();
        if (typeof fn === "function") msgFns.push(fn);
        return;
      }
      return origAdd(type, fn, opt);
    };

    Object.defineProperty(ws, "onmessage", {
      configurable: true,
      enumerable: true,
      get: function () {
        return onMsg;
      },
      set: function (fn) {
        ensureNative();
        onMsg = fn;
      },
    });

    var origSend = ws.send.bind(ws);
    ws.send = function (data) {
      try {
        var m = typeof data === "string" ? JSON.parse(data) : null;
        if (m && m.op === "watch_account" && m.accountId) {
          accounts[m.accountId] = 1;
          if (!pollTimer) pollTimer = setInterval(poll, 250);
          poll();
        }
      } catch (e) {}
      return origSend(data);
    };

    origAdd("close", function () {
      if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = null;
      }
    });

    return ws;
  }

  BxWS.prototype = Orig.prototype;
  BxWS.CONNECTING = Orig.CONNECTING;
  BxWS.OPEN = Orig.OPEN;
  BxWS.CLOSING = Orig.CLOSING;
  BxWS.CLOSED = Orig.CLOSED;
  window.WebSocket = BxWS;
})();
