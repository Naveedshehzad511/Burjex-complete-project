import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart';
import '../models/tick.dart';

/// Frames pushed by the ws-gateway.
sealed class WsFrame {}

class TickFrame extends WsFrame {
  final Tick tick;
  TickFrame(this.tick);
}

/// A server-authoritative chart bar, already in this tenant's visible price.
///
/// The client no longer builds chart OHLC: the canonical engine owns it, so the
/// bar shown while forming is the same bar that finalizes. `kind` is advisory —
/// consumers upsert on identity, so a missed `created` self-heals.
class CandleFrame extends WsFrame {
  final String kind;
  final Candle candle;
  final String symbol;
  final String tf;
  CandleFrame({
    required this.kind,
    required this.candle,
    required this.symbol,
    required this.tf,
  });
}

class AccountFrame extends WsFrame {
  final Map<String, dynamic> data;
  AccountFrame(this.data);
}

class PositionFrame extends WsFrame {
  final Map<String, dynamic> data;
  PositionFrame(this.data);
}

class OrderFrame extends WsFrame {
  final Map<String, dynamic> data;
  OrderFrame(this.data);
}

/// Resilient WebSocket client. Auto-reconnects with backoff, re-sends the
/// subscription set on reconnect, and exposes a broadcast stream of frames.
class MarketSocket {
  MarketSocket({
    required this.wsUrl,
    required this.getToken,
    this.onAuthExpired,
    this.onReconnected,
  });

  final String wsUrl;
  final String? Function() getToken;
  final Future<void> Function()? onAuthExpired;
  /// After a successful (re)connect + subscription replay. Used to REST-sync
  /// orders/positions so a dropped socket cannot leave the UI on stale state.
  final void Function()? onReconnected;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  final _controller = StreamController<WsFrame>.broadcast();
  final _symbols = <String>{};

  /// Gateway-assigned symbol ids, valid for this connection only. Cleared on
  /// reconnect because the gateway assigns fresh ones for the new session.
  final _symbolById = <int, String>{};
  final _accounts = <String>{};
  Duration _backoff = const Duration(milliseconds: 500);
  bool _closedByUser = false;
  Timer? _heartbeat;

  Stream<WsFrame> get frames => _controller.stream;

  void connect() {
    _closedByUser = false;
    // Symbol ids are assigned per connection, so ids from the previous session
    // mean nothing here. Carrying them over would silently decode ticks to the
    // WRONG symbol — gold's price shown under a currency pair — which is far
    // worse than a missing quote, because nothing about it looks broken.
    _symbolById.clear();
    final token = getToken();
    final uri = Uri.parse('$wsUrl?token=${token ?? ''}');
    try {
      _ch = WebSocketChannel.connect(uri);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _backoff = const Duration(milliseconds: 500);
    if (_symbols.isNotEmpty) {
      _send({
        'op': 'subscribe',
        'symbols': _symbols.toList(),
        'batch': true, 'evts': true,
        'compact': true,
      });
    }
    for (final a in _accounts) {
      _send({'op': 'watch_account', 'accountId': a});
    }
    _startHeartbeat();
    onReconnected?.call();

    _sub = _ch!.stream.listen(
      _onMessage,
      onDone: _handleClose,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> f;
    try {
      f = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (f['t']) {
      case 'tick':
        _controller.add(TickFrame(Tick.fromJson(f['d'])));
      case 'sym':
        // Gateway-assigned symbol ids for this connection. Always delivered
        // before any tick that uses them.
        (f['d'] as Map<String, dynamic>).forEach((sym, id) {
          _symbolById[(id as num).toInt()] = sym;
        });
      case 'k':
        // Compact ticks: [symbolId, bid, ask, ts]. Half of a JSON tick is its
        // field names and symbol string repeated on every one; this drops both
        // and roughly halves a trader's data usage over a session.
        for (final row in (f['d'] as List)) {
          final r = row as List;
          final sym = _symbolById[(r[0] as num).toInt()];
          if (sym == null) continue; // id we were never told about
          _controller.add(TickFrame(Tick(
            symbol: sym,
            bid: (r[1] as num).toDouble(),
            ask: (r[2] as num).toDouble(),
            ts: (r[3] as num).toInt(),
          )));
        }
      case 'ticks':
        // A batch. The gateway coalesces ticks into one frame so a busy feed
        // costs one parse instead of one per tick — the decode cost, not the
        // tick count, is what a phone cannot keep up with. Every tick in the
        // batch is emitted, in arrival order, so nothing derived per tick
        // (day high/low, the forming bar) loses a value.
        for (final t in (f['d'] as List)) {
          _controller.add(TickFrame(Tick.fromJson(t as Map<String, dynamic>)));
        }
      case 'candle':
        final d = f['d'] as Map<String, dynamic>;
        _controller.add(CandleFrame(
          kind: (d['kind'] ?? 'updated').toString(),
          symbol: (d['symbol'] ?? '').toString(),
          tf: (d['tf'] ?? '').toString(),
          candle: Candle.fromJson(d),
        ));
      case 'account':
        _controller.add(AccountFrame(f['d']));
      case 'position':
        _controller.add(PositionFrame(f['d']));
      case 'order':
        _controller.add(OrderFrame(f['d']));
      case 'evts':
        // One frame carrying every engine event the gateway buffered for us in
        // its flush window. Unpacked into the same frames the individual cases
        // above produce, so nothing downstream needs to know batching happened.
        final d = (f['d'] as Map).cast<String, dynamic>();
        for (final p in (d['p'] as List? ?? const [])) {
          _controller.add(PositionFrame(p));
        }
        for (final a in (d['a'] as List? ?? const [])) {
          _controller.add(AccountFrame(a));
        }
        for (final o in (d['o'] as List? ?? const [])) {
          _controller.add(OrderFrame(o));
        }
    }
  }

  void subscribe(List<String> symbols) {
    _symbols.addAll(symbols);
    // `batch: true` tells the gateway this build understands batched tick
    // frames. Older builds omit it and keep receiving one tick per frame, so a
    // server rollout cannot break an app that is already installed.
    _send({'op': 'subscribe', 'symbols': symbols, 'batch': true, 'evts': true, 'compact': true});
  }

  /// Make [want] the complete set of streamed symbols, unsubscribing anything
  /// no longer needed.
  ///
  /// [subscribe] only ever adds, so the streamed set could grow but never
  /// shrink — switching watchlist or chart symbol kept the old ones flowing for
  /// the life of the connection. On a book of this size that is most of the
  /// traffic reaching the device, for symbols nobody is looking at.
  ///
  /// Sends only the difference: a no-op call costs nothing, which matters
  /// because this is driven by a provider that rebuilds on every position and
  /// order change.
  void setSubscription(Set<String> want) {
    final add = want.difference(_symbols).toList();
    final remove = _symbols.difference(want).toList();
    if (add.isEmpty && remove.isEmpty) return;
    _symbols
      ..removeAll(remove)
      ..addAll(add);
    if (remove.isNotEmpty) _send({'op': 'unsubscribe', 'symbols': remove});
    if (add.isNotEmpty) {
      _send({'op': 'subscribe', 'symbols': add, 'batch': true, 'evts': true, 'compact': true});
    }
  }

  void watchAccount(String accountId) {
    _accounts.add(accountId);
    _send({'op': 'watch_account', 'accountId': accountId});
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _ch?.sink.add(jsonEncode(msg));
    } catch (_) {/* not open yet */}
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => _send({'op': 'ping'}));
  }

  /// On close, if the gateway rejected our token (4401), renew it first so the
  /// reconnect carries a fresh access token; otherwise just reconnect.
  Future<void> _handleClose() async {
    if (_ch?.closeCode == 4401 && onAuthExpired != null) {
      try {
        await onAuthExpired!();
      } catch (_) {/* keep tokens; backoff reconnect will retry */}
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _heartbeat?.cancel();
    if (_closedByUser) return;
    _backoff = Duration(milliseconds: (_backoff.inMilliseconds * 2).clamp(500, 10000));
    Future.delayed(_backoff, () {
      if (!_closedByUser) connect();
    });
  }

  void dispose() {
    _closedByUser = true;
    _heartbeat?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _controller.close();
  }
}
