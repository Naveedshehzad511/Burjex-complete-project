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

  String get label {
    final t = type.toUpperCase();
    final name = switch (t) {
      'BUY_LIMIT' => 'Buy Limit',
      'SELL_LIMIT' => 'Sell Limit',
      'BUY_STOP' => 'Buy Stop',
      'SELL_STOP' => 'Sell Stop',
      'LIMIT' => '$side Limit',
      'STOP' => '$side Stop',
      _ => t,
    };
    return '$name ${volume.toStringAsFixed(2)}';
  }

  static double? _dn(dynamic v) => v == null ? null : double.tryParse('$v');

  factory PendingOrder.fromJson(Map<String, dynamic> j) {
    final sym = j['symbol'];
    final type = '${j['type']}'.toUpperCase();
    final isStop = type.contains('STOP') && !type.contains('LIMIT');
    // Stops trigger on `stopPrice`; limits rest at `price`.
    final entry = (isStop ? _dn(j['stopPrice']) ?? _dn(j['price']) : _dn(j['price']) ?? _dn(j['stopPrice'])) ?? 0;
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
    );
  }
}

/// Pending orders for the active trading account. Refetched whenever the account,
/// session or an order/position event changes it (the socket invalidates the
/// order + position providers; this one also watches the position list so a
/// fill removes the resting line immediately).
final pendingOrdersProvider = FutureProvider.autoDispose<List<PendingOrder>>((ref) async {
  final id = ref.watch(activeAccountIdProvider);
  ref.watch(sessionEpochProvider);
  ref.watch(openPositionsProvider); // a triggered order becomes a position
  if (id == null) return const [];
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/orders', query: {'accountId': id, 'status': 'PENDING', 'fresh': '1'}) as List;
  return [for (final e in data) PendingOrder.fromJson((e as Map).cast<String, dynamic>())];
});
