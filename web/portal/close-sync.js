/**
 * Server CLOSED must drop the Trade row; OPEN rows must keep painting.
 *
 * Does not steal WebSocket.addEventListener (Dart2js needs the native
 * message stream). Does not poll GET /v1/positions (that was forcing every
 * noted id CLOSED whenever the list was empty/non-array, and 4 Hz polls
 * 429'd the portal's own /positions read so the provider came back null).
 *
 * Only records ids that are already CLOSED/closing so a later REST paint
 * cannot resurrect them. Does not rewrite OPEN snapshots.
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

  function posId(p) {
    return p ? String(p.id || p.positionId || "") : "";
  }

  // A/B book is "A" / "B". Only the fill-kind "closed" (and status/closing)
  // means the ticket is gone. Do not treat execClaimKind sl/tp on an OPEN
  // snapshot as closed — that hid live trades.
  function isServerClosed(p) {
    if (!p || typeof p !== "object") return false;
    var st = String(p.status || "").toUpperCase();
    var book = String(p.book || "").toLowerCase();
    var reason = String(p.reason || "").toUpperCase();
    var stateVal = String(p.state || "").toLowerCase();
    return (
      p.closing === true ||
      st === "CLOSED" ||
      book === "closed" ||
      stateVal === "closed" ||
      reason === "SL_HIT" ||
      reason === "TP_HIT"
    );
  }

  function markPos(p) {
    if (isServerClosed(p)) mark(posId(p));
  }

  function markFrame(obj) {
    if (!obj || typeof obj !== "object") return;
    if (obj.t === "position") markPos(obj.d);
    else if (obj.t === "evts" && obj.d && Array.isArray(obj.d.p)) {
      for (var i = 0; i < obj.d.p.length; i++) markPos(obj.d.p[i]);
    }
  }

  var Orig = window.WebSocket;
  function BxWS(url, protocols) {
    var ws;
    if (protocols == null || (Array.isArray(protocols) && protocols.length === 0)) {
      ws = new Orig(url);
    } else {
      ws = new Orig(url, protocols);
    }
    Orig.prototype.addEventListener.call(ws, "message", function (ev) {
      try {
        if (typeof ev.data !== "string") return;
        if (ev.data.indexOf('"t":"position"') === -1 && ev.data.indexOf('"t":"evts"') === -1) {
          return;
        }
        markFrame(JSON.parse(ev.data));
      } catch (e) {}
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
