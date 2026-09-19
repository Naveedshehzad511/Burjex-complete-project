/**
 * Do not wrap WebSocket or poll /positions. Dart2js must own the native
 * socket; the old wrap/poll made GET /v1/positions and WS `d` come back null
 * so Trade painted "Null check operator used on a null value".
 *
 * Server CLOSED still drops the row via WS sticky-CLOSED + matching skip of
 * claimed tickets. Flutter already records __bxClosedIds on a real CLOSED frame.
 *
 * Does not replace main.dart.js (Home / Quotes / Chart / Trade / History).
 */
(function () {
  if (window.__bxCloseSync) return;
  window.__bxCloseSync = true;
})();
