import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One closed (or partly closed) trade as the chart draws it: the entry, the exit, and the line between them.
/// Built from the same `/history/deals` rows the History tab lists, so nothing here is computed or invented.
class ChartTrade {
  const ChartTrade({
    required this.id,
    required this.positionId,
    required this.symbol,
    required this.side,
    required this.volume,
    required this.openPrice,
    required this.openTime,
    required this.closePrice,
    required this.closeTime,
    required this.profit,
    required this.digits,
    this.ticket,
  });

  /// The CLOSE deal's id — one per close, so a partly closed position has several.
  final String id;

  /// The position this closed (its entry is drawn once however many closes it had).
  final String positionId;
  final String symbol;

  /// The position's side: 'BUY' or 'SELL'. The exit is the opposite deal.
  final String side;
  final double volume;
  final double openPrice;
  final int openTime; // epoch seconds
  final double closePrice;
  final int closeTime; // epoch seconds
  final double profit;
  final int digits;
  final String? ticket;

  bool get isBuy => side.toUpperCase() == 'BUY';
}

/// The chart's trades from the history deals: closed trades with everything the markers need (symbol, side, entry
/// and exit price and time). Balance operations, deals without an entry, and duplicates (the same deal twice, e.g. a
/// refetch while another is in flight) are left out. Oldest first.
List<ChartTrade> chartTradesFromDeals(Iterable<Deal> deals) {
  final seen = <String>{};
  final out = <ChartTrade>[];
  for (final d in deals) {
    if (!d.isTrade || d.symbol == null || d.side == null || d.price == null || d.openPrice == null || d.openedAt == null) continue;
    if (!seen.add(d.id)) continue;
    out.add(ChartTrade(
      id: d.id,
      positionId: d.positionId ?? d.id,
      symbol: d.symbol!,
      side: d.side!,
      volume: d.volume ?? 0,
      openPrice: d.openPrice!,
      openTime: d.openedAt!.millisecondsSinceEpoch ~/ 1000,
      closePrice: d.price!,
      closeTime: d.createdAt.millisecondsSinceEpoch ~/ 1000,
      profit: d.profit,
      digits: d.digits,
      ticket: d.ticket,
    ));
  }
  out.sort((a, b) => a.closeTime.compareTo(b.closeTime));
  return out;
}

class TradeHistoryState {
  const TradeHistoryState({this.account, this.fromSec, this.trades = const []});
  final String? account;

  /// Start of the window the trades cover (epoch seconds); null before the first fetch.
  final int? fromSec;
  final List<ChartTrade> trades;
}

/// The closed trades the chart shows for Chart Settings > Trade history. One request covers the account from the
/// oldest loaded candle to now; it is repeated when older candles load (swiping back), when the account changes
/// and when a trade event arrives (a close). Failures keep what is already shown.
class TradeHistoryController extends StateNotifier<TradeHistoryState> {
  TradeHistoryController(this._ref) : super(const TradeHistoryState());
  final Ref _ref;
  bool _busy = false;
  int? _wantFrom;
  String? _wantAccount;

  /// Never reach further back than this, however old the candles are (one request stays small).
  static const maxLookback = Duration(days: 400);

  /// True when [fromSec] / [account] are not yet covered by what is loaded.
  bool needs(String? account, int fromSec) =>
      account != null && (state.account != account || state.fromSec == null || fromSec < state.fromSec!);

  Future<void> ensure(String? account, int fromSec) async {
    if (account == null) return;
    final floor = DateTime.now().subtract(maxLookback).millisecondsSinceEpoch ~/ 1000;
    final from = fromSec < floor ? floor : fromSec;
    if (!needs(account, from)) return;
    // Keep what is already covered: ask for the older of the two starts.
    _wantFrom = state.account == account && state.fromSec != null && state.fromSec! < from ? state.fromSec : from;
    _wantAccount = account;
    await _run();
  }

  /// Fetch again over the same window (a trade was opened or closed).
  Future<void> refresh() async {
    if (state.account == null || state.fromSec == null) return;
    _wantAccount = state.account;
    _wantFrom = state.fromSec;
    await _run();
  }

  Future<void> _run() async {
    if (_busy) return; // the request in flight finishes first, then picks up the latest wish below
    _busy = true;
    try {
      while (_wantAccount != null && _wantFrom != null) {
        final account = _wantAccount!, from = _wantFrom!;
        _wantAccount = null;
        _wantFrom = null;
        try {
          final data = await _ref.read(apiClientProvider).get('/history/deals', query: {
            'accountId': account,
            'from': DateTime.fromMillisecondsSinceEpoch(from * 1000, isUtc: true).toIso8601String(),
          }) as List;
          if (!mounted) return;
          state = TradeHistoryState(
            account: account,
            fromSec: from,
            trades: chartTradesFromDeals(data.map((e) => Deal.fromJson(Map<String, dynamic>.from(e as Map)))),
          );
        } catch (_) {/* keep the markers already shown; the next trigger retries */}
      }
    } finally {
      _busy = false;
    }
  }
}

final tradeHistoryProvider = StateNotifierProvider<TradeHistoryController, TradeHistoryState>((ref) => TradeHistoryController(ref));
