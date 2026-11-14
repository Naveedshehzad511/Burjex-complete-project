import 'dart:async';
import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.live = true,
  });
  final String symbol;
  final String name;

  /// COMMODITIES | CRYPTO | INDICES | STOCKS.
  final String category;
  final double price;
  final int digits;
  final double changePct;

  /// False: the market is closed for this symbol and the card shows its last trading day (e.g. Friday on Saturday).
  final bool live;

  Map<String, dynamic> toJson() =>
      {'symbol': symbol, 'name': name, 'category': category, 'price': price, 'digits': digits, 'changePct': changePct, 'live': live};

  factory Mover.fromJson(Map<String, dynamic> j) => Mover(
        symbol: '${j['symbol'] ?? ''}',
        name: '${j['name'] ?? ''}',
        category: '${j['category'] ?? ''}'.toUpperCase(),
        price: (j['price'] as num?)?.toDouble() ?? 0,
        digits: (j['digits'] as num?)?.toInt() ?? 2,
        changePct: (j['changePct'] as num?)?.toDouble() ?? 0,
        live: j['live'] as bool? ?? true,
      );
}

class MoversData {
  const MoversData({required this.asOf, required this.gainers, required this.losers, DateTime? gainersAsOf, DateTime? losersAsOf})
      : gainersAsOf = gainersAsOf ?? asOf,
        losersAsOf = losersAsOf ?? asOf;
  final DateTime asOf;
  final List<Mover> gainers;
  final List<Mover> losers;

  /// When each side was last computed with cards: a side the server answered empty keeps its last good cards.
  final DateTime gainersAsOf;
  final DateTime losersAsOf;

  /// [fresh] from the server, each side kept from this one when the server sent it empty (never blank a good side).
  MoversData mergedWith(MoversData fresh) => MoversData(
        asOf: fresh.asOf,
        gainers: fresh.gainers.isNotEmpty || gainers.isEmpty ? fresh.gainers : gainers,
        gainersAsOf: fresh.gainers.isNotEmpty || gainers.isEmpty ? fresh.asOf : gainersAsOf,
        losers: fresh.losers.isNotEmpty || losers.isEmpty ? fresh.losers : losers,
        losersAsOf: fresh.losers.isNotEmpty || losers.isEmpty ? fresh.asOf : losersAsOf,
      );

  Map<String, dynamic> toJson() => {
        'asOf': asOf.millisecondsSinceEpoch,
        'gainersAsOf': gainersAsOf.millisecondsSinceEpoch,
        'losersAsOf': losersAsOf.millisecondsSinceEpoch,
        'gainers': [for (final m in gainers) m.toJson()],
        'losers': [for (final m in losers) m.toJson()],
      };

  factory MoversData.fromJson(Map<String, dynamic> j) {
    List<Mover> list(Object? v) => [
          for (final e in (v as List? ?? const [])) Mover.fromJson((e as Map).cast<String, dynamic>()),
        ];
    DateTime? at(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return MoversData(
      asOf: at(j['asOf']) ?? DateTime.now(),
      gainers: list(j['gainers']),
      losers: list(j['losers']),
      gainersAsOf: at(j['gainersAsOf']),
      losersAsOf: at(j['losersAsOf']),
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
    if (_accountId != null) {
      if (state.data == null) unawaited(_restore());
      unawaited(refresh());
    }
  }

  static String _key(String account) => 'bt_movers|$account';

  /// The last good cards saved on this device (app restarted while offline / the server cannot be reached).
  Future<void> _restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(_accountId!));
      if (raw == null || !mounted || state.data != null) return;
      state = MoversState(data: MoversData.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>()), failed: state.failed);
    } catch (_) {/* nothing saved, or unreadable: wait for the server */}
  }

  Future<void> _save(MoversData d) async {
    if (d.gainers.isEmpty && d.losers.isEmpty) return; // never replace good cards with nothing
    try {
      await (await SharedPreferences.getInstance()).setString(_key(_accountId!), jsonEncode(d.toJson()));
    } catch (_) {/* best effort */}
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
      final fresh = MoversData.fromJson(body.cast<String, dynamic>());
      final prev = state.data;
      final data = prev == null ? fresh : prev.mergedWith(fresh);
      _last = data;
      unawaited(_save(data));
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
