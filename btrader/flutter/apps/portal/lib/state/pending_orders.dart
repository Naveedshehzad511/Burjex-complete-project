import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A working (pending) order resting in the book.
class PendingOrder {
  const PendingOrder({
    required this.id,
    required this.symbol,
    required this.side,
    required this.type,
    required this.volume,
    required this.entry,
    this.sl,
    this.tp,
    this.hasStopField = false,
    this.limit,
    this.status = 'PENDING',
    this.createdAt,
    this.expiresAt,
    this.timeInForce,
    this.comment,
    this.digits,
  });
  final String id;
  final String symbol;
  final String side; // BUY | SELL
  final String type; // BUY_LIMIT | SELL_LIMIT | BUY_STOP | SELL_STOP | ...
  final double volume;
  final double entry;
  final double? sl;
  final double? tp;

  /// The stored order carries a separate `stopPrice`, so moving the trigger must
  /// update it as well (the engine triggers on stopPrice before price).
  final bool hasStopField;

  /// STOP_LIMIT only: the limit (fill) price. [entry] is then the stop trigger.
  final double? limit;

  /// Server status (PENDING | PARTIAL) and the other fields the API returns.
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final String? timeInForce;
  final String? comment;

  /// Symbol digits when the payload carried them (REST rows do, socket events don't).
  final int? digits;

  bool get isStopLimit => type == 'STOP_LIMIT';

  /// Which delete-menu bucket this order belongs to.
  bool get isLimitKind => !type.contains('STOP');
  bool get isStopKind => type.contains('STOP') && !type.contains('LIMIT');

  /// MT5 order-row title without the volume, e.g. `sell limit`.
  String get kindLabel => label.substring(0, label.lastIndexOf(' ')).toLowerCase();

  String get label {
    final t = type.toUpperCase();
    final name = switch (t) {
      'BUY_LIMIT' => 'Buy Limit',
      'SELL_LIMIT' => 'Sell Limit',
      'BUY_STOP' => 'Buy Stop',
      'SELL_STOP' => 'Sell Stop',
      'LIMIT' => '$side Limit',
      'STOP' => '$side Stop',
      'STOP_LIMIT' => side == 'BUY' ? 'Buy Stop Limit' : 'Sell Stop Limit',
      _ => t,
    };
    return '$name ${volume.toStringAsFixed(2)}';
  }

  static double? _dn(dynamic v) => v == null ? null : double.tryParse('$v');

  /// Builds an order from either the REST row (`symbol` is an object) or a socket
  /// event (`symbol` is a string). Both carry the same trading fields.
  factory PendingOrder.fromJson(Map<String, dynamic> j) {
    final sym = j['symbol'];
    final type = '${j['type']}'.toUpperCase();
    final stopLimit = type == 'STOP_LIMIT';
    final isStop = type.contains('STOP') && !type.contains('LIMIT');
    // Stops (and a Stop Limit's trigger) sit on `stopPrice`; limits rest at `price`.
    final entry = (isStop || stopLimit ? _dn(j['stopPrice']) ?? _dn(j['price']) : _dn(j['price']) ?? _dn(j['stopPrice'])) ?? 0;
    return PendingOrder(
      id: '${j['id']}',
      symbol: sym is Map ? '${sym['symbol']}' : '$sym',
      side: '${j['side']}'.toUpperCase(),
      type: type,
      volume: _dn(j['volume']) ?? 0,
      entry: entry,
      sl: _dn(j['slPrice']),
      tp: _dn(j['tpPrice']),
      hasStopField: _dn(j['stopPrice']) != null,
      limit: stopLimit ? _dn(j['price']) : null,
      status: '${j['status'] ?? 'PENDING'}'.toUpperCase(),
      createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}'),
      expiresAt: DateTime.tryParse('${j['expiresAt'] ?? ''}'),
      timeInForce: j['timeInForce'] as String?,
      comment: j['comment'] is String ? j['comment'] as String : null,
      digits: sym is Map && sym['digits'] is int ? sym['digits'] as int : null,
    );
  }
}

/// Working orders for the active trading account.
///
/// The server is the source of truth: the list is loaded over REST (bypassing the
/// gateway's read cache) and re-loaded on account/session change and after a socket
/// reconnect. Between loads the order events pushed over the socket are applied
/// directly — created / modified orders are upserted, and filled / cancelled /
/// rejected / expired ones are removed — so a pending line appears, moves and
/// disappears the instant the server says so, with no refresh.
class PendingOrdersController extends StateNotifier<AsyncValue<List<PendingOrder>>> {
  PendingOrdersController(this._ref) : super(const AsyncValue.loading()) {
    _ref.listen<String?>(activeAccountIdProvider, (_, __) => reload(), fireImmediately: false);
    _ref.listen<int>(sessionEpochProvider, (_, __) => reload());
    _ref.listen<int>(socketEpochProvider, (_, __) {
      // Events sent while the socket was down are gone, so reconcile with the server.
      // The second pass, once the new socket is subscribed, closes the window between
      // the first fetch and the subscription going live.
      reload();
      _settleTimer?.cancel();
      _settleTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) reload();
      });
    });
    _ref.listen<OrderEvent?>(lastOrderEventProvider, (_, e) {
      if (e != null) _apply(e.order);
    });
    reload();
  }
  final Ref _ref;
  Timer? _settleTimer;

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  /// Bumped by every applied event; a REST response that started before an event
  /// is discarded (and re-run) so it can never overwrite newer pushed state.
  int _version = 0;
  bool _reloading = false;
  bool _again = false;

  String? get _accountId => _ref.read(activeAccountIdProvider);

  /// Load from the server. Safe to call repeatedly; overlapping calls coalesce.
  Future<void> reload() async {
    if (_reloading) {
      _again = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _again = false;
        final id = _accountId;
        if (id == null) {
          if (mounted) state = const AsyncValue.data(<PendingOrder>[]);
          break;
        }
        final startedAt = _version;
        try {
          final data = await _ref.read(apiClientProvider).get('/orders', query: {'accountId': id, 'status': 'PENDING', 'fresh': '1'}) as List;
          if (!mounted) return;
          if (_version != startedAt || id != _accountId) {
            _again = true; // an event (or account switch) landed while loading
            continue;
          }
          state = AsyncValue.data([for (final e in data) PendingOrder.fromJson((e as Map).cast<String, dynamic>())]);
        } catch (e, st) {
          // Keep showing what we have; only surface an error when there is nothing.
          if (mounted && state.valueOrNull == null) state = AsyncValue.error(e, st);
        }
      } while (_again && mounted);
    } finally {
      _reloading = false;
    }
  }

  void _apply(Map<String, dynamic> o) {
    final acct = '${o['accountId'] ?? ''}';
    if (acct.isNotEmpty && acct != _accountId) return; // another account's order
    final id = '${o['id'] ?? ''}';
    if (id.isEmpty) return;
    final status = '${o['status'] ?? ''}'.toUpperCase();
    final cur = state.valueOrNull ?? const <PendingOrder>[];
    _version++;
    if (status == 'PENDING' || status == 'PARTIAL') {
      final next = PendingOrder.fromJson(o);
      final i = cur.indexWhere((x) => x.id == id);
      state = AsyncValue.data(i < 0 ? [...cur, next] : [for (final x in cur) x.id == id ? next : x]);
    } else {
      // FILLED / CANCELLED / REJECTED / EXPIRED — no longer resting.
      state = AsyncValue.data([for (final x in cur) if (x.id != id) x]);
    }
  }

  /// Cancel every resting order matching [test] (all when null) through the
  /// existing `DELETE /orders/:id`, dropping each locally once the server accepts
  /// it. Returns how many were cancelled; failures are left in place and the list
  /// is reconciled with the server afterwards.
  Future<int> cancelWhere([bool Function(PendingOrder)? test]) async {
    final targets = [for (final o in state.valueOrNull ?? const <PendingOrder>[]) if (test == null || test(o)) o];
    final api = _ref.read(apiClientProvider);
    var n = 0;
    await Future.wait([
      for (final o in targets)
        () async {
          try {
            await api.delete('/orders/${o.id}');
            if (mounted) removeLocal(o.id);
            n++;
          } catch (_) {}
        }(),
    ]);
    await reload();
    return n;
  }

  /// Drop an order locally right after the server accepted its cancellation.
  void removeLocal(String id) {
    _version++;
    state = AsyncValue.data([for (final x in state.valueOrNull ?? const <PendingOrder>[]) if (x.id != id) x]);
  }
}

final pendingOrdersProvider = StateNotifierProvider<PendingOrdersController, AsyncValue<List<PendingOrder>>>(
  (ref) => PendingOrdersController(ref),
);
