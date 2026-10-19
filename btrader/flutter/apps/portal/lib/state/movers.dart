import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One card of Top Gainers / Top Losers (from `GET /market/movers`). Everything is the server's: the name the
/// client's trading group shows, the category, the live price and the % against the previous day's close.
class Mover {
  const Mover({
    required this.symbol,
    required this.name,
    required this.category,
    required this.price,
    required this.digits,
    required this.changePct,
  });
  final String symbol;
  final String name;

  /// COMMODITIES | CRYPTO | INDICES | STOCKS.
  final String category;
  final double price;
  final int digits;
  final double changePct;

  factory Mover.fromJson(Map<String, dynamic> j) => Mover(
        symbol: '${j['symbol'] ?? ''}',
        name: '${j['name'] ?? ''}',
        category: '${j['category'] ?? ''}'.toUpperCase(),
        price: (j['price'] as num?)?.toDouble() ?? 0,
        digits: (j['digits'] as num?)?.toInt() ?? 2,
        changePct: (j['changePct'] as num?)?.toDouble() ?? 0,
      );
}

class MoversData {
  const MoversData({required this.asOf, required this.gainers, required this.losers});
  final DateTime asOf;
  final List<Mover> gainers;
  final List<Mover> losers;

  factory MoversData.fromJson(Map<String, dynamic> j) {
    List<Mover> list(Object? v) => [
          for (final e in (v as List? ?? const [])) Mover.fromJson((e as Map).cast<String, dynamic>()),
        ];
    return MoversData(
      asOf: DateTime.fromMillisecondsSinceEpoch((j['asOf'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
      gainers: list(j['gainers']),
      losers: list(j['losers']),
    );
  }
}

class MoversState {
  const MoversState({this.data, this.failed = false});

  /// The last good answer (kept on screen while a refresh is running or has failed).
  final MoversData? data;

  /// The latest refresh failed: [data], if any, is stale.
  final bool failed;

  bool get loading => data == null && !failed;
  bool get stale => data != null && failed;
}

/// The movers for the active account: fetched when Home opens and again on every beat of Home's own refresh timer
/// ([MoversNotifier.refresh]), keeping the last good answer so a slow or failed refresh never blanks the cards.
class MoversNotifier extends StateNotifier<MoversState> {
  MoversNotifier(this._ref, this._accountId) : super(MoversState(data: _accountId != null && _accountId == _lastAccount ? _last : null)) {
    // The trading session may still be opening (no account yet): nothing to ask until it has one.
    if (_accountId != null) unawaited(refresh());
  }

  final Ref _ref;
  final String? _accountId;
  bool _busy = false;

  /// What the last Home visit ended with, so coming back shows cards at once (then refreshes).
  static MoversData? _last;
  static String? _lastAccount;

  Future<void> refresh() async {
    if (_busy || _accountId == null) return;
    _busy = true;
    try {
      final body = await _ref.read(apiClientProvider).get('/market/movers', query: {'accountId': _accountId});
      if (body is! Map) throw const FormatException('movers');
      final data = MoversData.fromJson(body.cast<String, dynamic>());
      _last = data;
      _lastAccount = _accountId;
      if (mounted) state = MoversState(data: data);
    } catch (_) {
      if (mounted) state = MoversState(data: state.data, failed: true);
    } finally {
      _busy = false;
    }
  }
}

final moversProvider = StateNotifierProvider.autoDispose<MoversNotifier, MoversState>((ref) {
  ref.watch(authControllerProvider);
  ref.watch(sessionEpochProvider);
  return MoversNotifier(ref, ref.watch(activeAccountIdProvider));
});
