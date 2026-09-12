import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import 'chart.dart';
import '../models/account.dart';
import '../models/candle.dart';
import '../models/position.dart';
import '../models/symbol.dart';
import '../models/tick.dart';
import '../ws/market_socket.dart';
import 'providers.dart';

/// Owns the WebSocket for the session and routes frames into the live stores.
/// Auto-connects when authenticated; disposes on logout.
final marketSocketProvider = Provider<MarketSocket?>((ref) {
  final auth = ref.watch(authControllerProvider);
  if (!auth.authenticated) return null;
  final store = ref.watch(authStoreProvider);
  final api = ref.watch(apiClientProvider);
  final sock = MarketSocket(
    wsUrl: BtConfig.wsUrl,
    getToken: () => store.accessToken,
    onAuthExpired: () => api.refreshAccessToken(),
    onReconnected: () {
      ref.invalidate(openPositionsProvider);
      ref.invalidate(accountsProvider);
    },
  );
  sock.connect();

  final sub = sock.frames.listen((f) {
    switch (f) {
      case TickFrame(:final tick):
        ref.read(quotesProvider.notifier).set(tick);
        ref.read(dayStatsProvider.notifier).update(tick);
      case CandleFrame(:final candle, :final symbol, :final tf):
        ref.read(serverCandlesProvider.notifier).upsert(symbol, tf, candle);
      case AccountFrame(:final data):
        ref.read(liveAccountProvider.notifier).set(data);
      case PositionFrame(:final data):
        final id = '${data['id'] ?? data['positionId'] ?? ''}';
        final status = '${data['status'] ?? ''}'.toUpperCase();
        final book = '${data['book'] ?? ''}';
        final closed = status == 'CLOSED' || book == 'closed';
        if (closed && id.isNotEmpty) {
          ref.read(livePositionNotifierProvider.notifier).forget(id);
          ref.read(closedPositionIdsProvider.notifier).add(id);
          Future.microtask(() {
            ref.invalidate(openPositionsProvider);
            ref.invalidate(accountsProvider);
          });
          break;
        }
        if (data['stale'] == true) {
          Future.microtask(() {
            ref.invalidate(openPositionsProvider);
            ref.invalidate(accountsProvider);
          });
          break;
        }
        final sym = '${data['symbol'] ?? ''}';
        final q = sym.isEmpty ? null : ref.read(quotesProvider)[sym];
        ref.read(livePositionNotifierProvider.notifier).set(data, fallbackQuote: q);
      case OrderFrame():
        Future.microtask(() {
          ref.invalidate(openPositionsProvider);
          ref.invalidate(accountsProvider);
        });
        break;
    }
  });

  ref.onDispose(() {
    sub.cancel();
    sock.dispose();
  });
  return sock;
});

/// Position ids the server has already closed. Overlay so the chart/portfolio
/// drop the row on the close event without waiting for a list refetch.
class ClosedPositionIds extends StateNotifier<Set<String>> {
  ClosedPositionIds() : super(const {});
  void add(String id) {
    if (id.isEmpty || state.contains(id)) return;
    state = {...state, id};
  }

  void clear() => state = const {};
}

final closedPositionIdsProvider =
    StateNotifierProvider<ClosedPositionIds, Set<String>>((_) => ClosedPositionIds());

/// Subscribes the WebSocket to every available symbol so ticks actually flow.
/// The WS gateway only forwards ticks for subscribed symbols — watch this
/// provider anywhere the live quotes are shown (Market Watch, Quotes screen).
/// Symbols the UI is actually showing, supplied by the app (its watchlist).
///
/// Left empty the whole book is streamed, which is the old behaviour and the
/// safe default for any caller that does not maintain a watchlist.
final feedSymbolsProvider = StateProvider<Set<String>>((_) => const <String>{});

final feedSubscriptionProvider = Provider<void>((ref) {
  final sock = ref.watch(marketSocketProvider);
  final symbols = ref.watch(symbolsProvider).valueOrNull;
  if (sock == null || symbols == null || symbols.isEmpty) return;
  final all = {for (final s in symbols) s.symbol};

  // Stream only what something on screen depends on.
  //
  // Subscribing to the entire book meant a phone received every tick for all
  // of them — the overwhelming majority for symbols the user was not looking
  // at. MT5 streams only its Market Watch for exactly this reason, so this was
  // one of the few places the platform did strictly more work than MT5 for no
  // benefit.
  //
  // The SET is decided by the app, not here: it must also cover open positions,
  // working orders and the current chart symbol, and those providers live in
  // layers this file cannot import without a cycle. Empty means "the app has
  // not told us yet", which falls back to the whole book so a cold start never
  // shows a dead price list.
  final want = ref.watch(feedSymbolsProvider);
  final target = want.intersection(all);
  sock.setSubscription(target.isEmpty ? all : target);
});

/// Live quote map keyed by symbol, fed by the socket.
class QuotesNotifier extends StateNotifier<Map<String, Tick>> {
  QuotesNotifier() : super(const {});

  /// Accept a tick unless it is strictly older than the one already held.
  ///
  /// The socket can deliver out of order after a reconnect, a batched bridge
  /// flush, or plain async scheduling. Unconditional assignment let a stale
  /// tick replace a newer one — and because the chart's forming bar and the
  /// SELL/BUY buttons both read the latest quote, a late tick could drag
  /// close/high/low back to a price the market had already left.
  ///
  /// Equal timestamps are ACCEPTED on purpose: feeds legitimately emit several
  /// updates within the same millisecond, and MT5 quotes often share a
  /// second-resolution stamp. Dropping those would discard real price moves.
  /// Only a strictly older stamp is rejected.
  ///
  /// A missing stamp (`ts <= 0`) carries no ordering information, so it is
  /// accepted rather than guessed at.
  /// Ticks are buffered and published at most once per frame.
  ///
  /// Every screen that shows a price watches this whole map — indexing it after
  /// `watch` does not narrow the dependency — and the client subscribes to the
  /// entire symbol book. At the observed feed rate that meant a full map copy
  /// and a rebuild of the Portfolio, chart and trade trees roughly two thousand
  /// times a second. A desktop browser absorbs that; a phone spends its whole
  /// frame budget on it and visibly stutters, which is exactly the difference
  /// between "web is perfect" and "the APK lags".
  ///
  /// Coalescing costs nothing visually: no display refreshes faster than about
  /// 60Hz, so publishing more often than that renders frames nobody can see.
  /// The newest tick per symbol still wins, and the ordering guard below still
  /// rejects genuinely stale ones — it just compares against whatever is
  /// pending as well as what is already published.
  void set(Tick t) {
    final prev = _pending[t.symbol] ?? state[t.symbol];
    if (prev != null && t.ts > 0 && prev.ts > 0 && t.ts < prev.ts) return;
    _pending[t.symbol] = t;
    _flush ??= Timer(const Duration(milliseconds: 16), _publish);
  }

  /// Ticks accepted since the last publish, newest per symbol.
  final Map<String, Tick> _pending = {};
  Timer? _flush;

  void _publish() {
    _flush = null;
    if (_pending.isEmpty) return;
    state = {...state, ..._pending};
    _pending.clear();
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }

  /// Seed last-known prices for symbols not yet live, so the watchlist is never
  /// blank. `putIfAbsent` means a live tick (already set) is never overwritten
  /// by a stale seed.
  void seedAll(List<Tick> ticks) {
    final m = {...state};
    for (final t in ticks) {
      m.putIfAbsent(t.symbol, () => t);
    }
    state = m;
  }
}

final quotesProvider = StateNotifierProvider<QuotesNotifier, Map<String, Tick>>((_) => QuotesNotifier());

/// Fetches the server's last-known-quote snapshot once and seeds [quotesProvider]
/// so symbols that aren't currently ticking still show their last real price
/// (MT5-style), instead of a blank. Live WS ticks then take over.
final quotesSeedProvider = FutureProvider<void>((ref) async {
  final auth = ref.watch(authControllerProvider);
  if (!auth.authenticated) return;
  final api = ref.watch(apiClientProvider);
  try {
    final data = await api.get('/market/quotes') as List;
    final ticks = data.map((e) => Tick.fromJson(e as Map<String, dynamic>)).toList();
    ref.read(quotesProvider.notifier).seedAll(ticks);
  } catch (_) {
    // No snapshot yet — the WS will fill quotes as ticks arrive.
  }
});

/// Per-symbol session reference: the first mid seen ("day open") plus running
/// high/low. Drives MT5-style % change, high/low, and the blue(up)/red(down)
/// coloring. NOTE: "open" resets when the app launches; once a real feed is in,
/// seed it from the daily (1d) candle's open for a true day-start reference.
class DayStat {
  final double open;
  final double high;
  final double low;
  const DayStat({required this.open, required this.high, required this.low});

  double changePct(double mid) => open == 0 ? 0 : (mid - open) / open * 100;
}

class DayStatsNotifier extends StateNotifier<Map<String, DayStat>> {
  DayStatsNotifier() : super(const {});

  /// Running high/low, updated on EVERY tick. Kept separate from [state] so a
  /// tick costs one map write instead of copying the whole book — the copy is
  /// what made a busy feed expensive on a phone.
  final Map<String, DayStat> _working = {};
  Timer? _flush;

  /// Accumulates every tick but publishes at most once per frame.
  ///
  /// The extremes must see all of them — a high set by a single tick between
  /// two frames is still the day's high — so accumulation stays per-tick and
  /// only the publish is throttled. Watchers cannot render faster than the
  /// display anyway.
  void update(Tick t) {
    final mid = (t.bid + t.ask) / 2;
    final cur = _working[t.symbol];
    _working[t.symbol] = cur == null
        ? DayStat(open: mid, high: mid, low: mid)
        : DayStat(
            open: cur.open,
            high: mid > cur.high ? mid : cur.high,
            low: mid < cur.low ? mid : cur.low,
          );
    _flush ??= Timer(const Duration(milliseconds: 16), _publish);
  }

  void _publish() {
    _flush = null;
    state = {..._working};
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}

final dayStatsProvider =
    StateNotifierProvider<DayStatsNotifier, Map<String, DayStat>>((_) => DayStatsNotifier());

/// Latest account snapshot per accountId (equity/margin/etc.) pushed live.
class LiveAccountNotifier extends StateNotifier<Map<String, Account>> {
  LiveAccountNotifier() : super(const {});

  /// When each account's snapshot last arrived over the WS. Used to ignore
  /// STALE entries in cross-account aggregates: a closed/idle account stops
  /// ticking, so its final snapshot would otherwise linger in the map forever
  /// and poison sums like the Overview's total floating P/L. Single-account
  /// views (a trader's own account) don't need this — they self-correct.
  final Map<String, DateTime> seenAt = {};

  void set(Map<String, dynamic> snap) {
    final id = snap['accountId'] as String? ?? snap['id'] as String?;
    if (id == null) return;
    seenAt[id] = DateTime.now();
    final prev = state[id];
    // Merge into the existing account when possible so login / group metadata
    // survive and floatingPL / equity update from the engine snapshot.
    if (prev != null) {
      state = {...state, id: prev.withSnapshot(snap)};
      return;
    }
    state = {
      ...state,
      id: Account.fromJson({
        ...snap,
        'id': id,
        'login': snap['login']?.toString() ?? id,
      }),
    };
  }

  /// True if this account pushed a live snapshot within [within]. Callers that
  /// aggregate across accounts should prefer the fresh HTTP value when false.
  bool isFresh(String id, {Duration within = const Duration(seconds: 6)}) {
    final ts = seenAt[id];
    return ts != null && DateTime.now().difference(ts) <= within;
  }
}

final liveAccountProvider =
    StateNotifierProvider<LiveAccountNotifier, Map<String, Account>>((_) => LiveAccountNotifier());

/// Live floating P/L by position id, with the price it was computed at.
///
/// The engine throttles these pushes to one per symbol per 500ms, so treating
/// the pushed number as the whole answer left P/L visibly trailing a fast
/// market: the price ticked several times a second while the figure beside it
/// sat still. Keeping the price the server priced against turns that number
/// into an ANCHOR the UI can carry forward on every tick, and each push
/// re-anchors it — so it tracks the market without drifting away from the
/// server's authoritative figure.
class LiveSnap {
  const LiveSnap(this.pl, this.price, this.vol);

  /// Floating P/L as last pushed, by position id.
  final Map<String, double> pl;

  /// The close price each [pl] was computed at, by position id.
  final Map<String, double> price;

  /// The VOLUME each [pl] was computed at, by position id.
  ///
  /// A partial close leaves the id unchanged but halves the size, so the last
  /// pushed figure describes a position that no longer exists. Without this the
  /// UI kept showing the whole trade's profit against the remainder until the
  /// server happened to push again — the number looked authoritative and was
  /// simply for the wrong quantity.
  final Map<String, double> vol;
}

class LivePositionNotifier extends StateNotifier<LiveSnap> {
  LivePositionNotifier() : super(const LiveSnap({}, {}, {}));
  void set(Map<String, dynamic> data, {Tick? fallbackQuote}) {
    final id = data['id'] as String?;
    if (id == null) return;
    final pl = double.tryParse('${data['profit']}') ?? 0;
    final isBuy = '${data['side']}'.toUpperCase() == 'BUY';
    final at = double.tryParse('${data['currentPrice']}') ??
        (isBuy ? fallbackQuote?.bid : fallbackQuote?.ask);
    final v = double.tryParse('${data['volume']}');
    state = LiveSnap(
      {...state.pl, id: pl},
      at == null ? state.price : {...state.price, id: at},
      v == null ? state.vol : {...state.vol, id: v},
    );
  }

  /// Forget a position's cached figure. Used the moment a close is confirmed,
  /// so a stale number cannot outlive the size it was computed for.
  void forget(String id) {
    state = LiveSnap(
      {...state.pl}..remove(id),
      {...state.price}..remove(id),
      {...state.vol}..remove(id),
    );
  }
}

final livePositionNotifierProvider =
    StateNotifierProvider<LivePositionNotifier, LiveSnap>((_) => LivePositionNotifier());

/// Floating P/L by position id. Unchanged shape for callers that only want the
/// last pushed figure (admin views, which are not tick-driven).
final livePositionProvider =
    Provider<Map<String, double>>((ref) => ref.watch(livePositionNotifierProvider).pl);

/// The price each pushed P/L was computed at. Pair with [livePositionProvider]
/// to move the figure between pushes.
final livePositionAnchorProvider =
    Provider<Map<String, double>>((ref) => ref.watch(livePositionNotifierProvider).price);

/// The volume each pushed P/L was computed at.
final livePositionVolumeProvider =
    Provider<Map<String, double>>((ref) => ref.watch(livePositionNotifierProvider).vol);

/// Client-side floating P/L from the live quote book when the engine WS push
/// is missing/stale. BUY closes at bid, SELL at ask (MT5 convention).
double estimatePositionProfit({
  required String side,
  required double volume,
  required double openPrice,
  required double closePrice,
  required double contractSize,
  double swap = 0,
}) {
  final diff = side.toUpperCase() == 'BUY' ? (closePrice - openPrice) : (openPrice - closePrice);
  return diff * volume * contractSize + swap;
}

/// Resolve P/L for one open position: engine WS push first, else quote estimate
/// so Portfolio / Trade never stick at 0.00 while quotes are moving.
double resolvePositionPl(
  Position p, {
  required Map<String, double> livePl,
  required Map<String, Tick> quotes,
  required List<TradeSymbol> symbols,
  Map<String, double> anchors = const {},
  Map<String, double> volumes = const {},
}) {
  final fromWs = livePl[p.id];
  final tick = quotes[p.symbol];
  TradeSymbol? spec;
  for (final s in symbols) {
    if (s.symbol == p.symbol) {
      spec = s;
      break;
    }
  }
  final cs = spec?.contractSize ?? 100000.0;
  // A pushed figure is only usable while it still describes THIS position. A
  // partial close keeps the id and changes the size, so the last push becomes a
  // number for a quantity that is no longer held — showing the whole trade's
  // profit against what is left. Falling back to the tick-derived estimate is
  // both correct and immediate; the next push re-establishes the authoritative
  // base a moment later.
  // The pushed volume is fresher than the REST list, which only refetches on a
  // 30s reconcile. After a partial close the push carries the new size AND the
  // profit for it within 500ms, while the REST list still reports the old size
  // for seconds — so the push is what the figure should be measured against.
  final liveVol = volumes[p.id];
  final size = liveVol ?? p.volume;
  if (fromWs != null) {
    // Carry the server's figure forward to the current tick. The server value
    // is authoritative — it includes swap, commission and any conversion to
    // the account currency — so it stays the base, and only the movement since
    // it was priced is added on top.
    final anchor = anchors[p.id];
    if (tick == null || anchor == null) return fromWs;
    final now = p.side.toUpperCase() == 'BUY' ? tick.bid : tick.ask;
    final dir = p.side.toUpperCase() == 'BUY' ? 1.0 : -1.0;
    return fromWs + (now - anchor) * dir * size * cs;
  }
  if (tick == null) return p.profit;
  final close = p.side.toUpperCase() == 'BUY' ? tick.bid : tick.ask;
  return estimatePositionProfit(
    side: p.side,
    volume: size,
    openPrice: p.openPrice,
    closePrice: close,
    contractSize: cs,
    swap: p.swap,
  );
}

/// Live chart bars pushed by the server, keyed `symbol|tf` → bucket → bar.
///
/// Identity is `symbol + timeframe + bucket time`, never list position, so a
/// historical bar and a live update for the same bucket collapse into ONE bar
/// instead of appending a duplicate. Upserts are idempotent, which makes
/// reconnect replay harmless.
class ServerCandlesNotifier extends StateNotifier<Map<String, Map<int, Candle>>> {
  ServerCandlesNotifier() : super(const {});

  /// Keep memory bounded: a chart never renders more than a few thousand bars,
  /// and history beyond that comes from the REST endpoint on demand.
  static const _maxPerSeries = 3000;

  static String seriesKey(String symbol, String tf) => '$symbol|$tf';

  void upsert(String symbol, String tf, Candle candle) {
    if (symbol.isEmpty || tf.isEmpty) return;
    final key = seriesKey(symbol, tf);
    final series = {...?state[key]};
    series[candle.t] = candle;

    if (series.length > _maxPerSeries) {
      final cutoff = series.keys.toList()..sort();
      for (final t in cutoff.take(series.length - _maxPerSeries)) {
        series.remove(t);
      }
    }
    state = {...state, key: series};
  }

  /// Bars for a series, oldest → newest.
  List<Candle> series(String symbol, String tf) {
    final m = state[seriesKey(symbol, tf)];
    if (m == null || m.isEmpty) return const [];
    final times = m.keys.toList()..sort();
    return [for (final t in times) m[t]!];
  }

  void clearSymbol(String symbol) {
    state = {
      for (final e in state.entries)
        if (!e.key.startsWith('$symbol|')) e.key: e.value,
    };
  }
}

final serverCandlesProvider =
    StateNotifierProvider<ServerCandlesNotifier, Map<String, Map<int, Candle>>>(
  (_) => ServerCandlesNotifier(),
);
