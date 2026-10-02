import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/candle.dart';
import '../models/position.dart';
import '../models/tick.dart';
import 'providers.dart';
import 'live.dart';

/// Open positions for the active account — used to overlay entry/SL/TP lines on
/// the chart (MT5-style). Refreshed on demand.
/// Safety-net reconcile of the open positions (the socket is the fast path). Overridable so a
/// test can run without a live periodic timer.
final openPositionsTickProvider = StreamProvider.autoDispose<int>(
  (ref) => Stream<int>.periodic(const Duration(seconds: 30), (i) => i + 1),
);

final openPositionsProvider =
    AsyncNotifierProvider.autoDispose<OpenPositionsNotifier, List<Position>>(OpenPositionsNotifier.new);

/// A position the engine confirmed as opened, and when this client learned of it.
class _ConfirmedOpen {
  _ConfirmedOpen(this.position) : at = DateTime.now();
  final Position position;
  final DateTime at;
}

/// Trades the engine has CONFIRMED as opened (from the order response or the `opened` push),
/// kept outside the autoDispose provider so a refetch that started before the trade
/// committed cannot make it vanish and reappear.
final _confirmedOpensProvider = Provider<Map<String, _ConfirmedOpen>>((_) => <String, _ConfirmedOpen>{});

/// Open positions for the active account: the server list, plus any trade the engine has
/// already confirmed that the list has not caught up with yet.
///
/// Nothing is shown on a guess: a position enters via [addConfirmed] / [addConfirmedFill], which
/// are called only from a backend-confirmed fill (`accepted` response with a position id, or the
/// engine's `opened` push). The refetch then reconciles the list against the server.
class OpenPositionsNotifier extends AutoDisposeAsyncNotifier<List<Position>> {
  @override
  Future<List<Position>> build() async {
    // Survive leaving the screen: Trade <-> History <-> Chart must reopen on the last known
    // list (refreshing quietly behind it), never on an empty loader. Still rebuilds when the
    // account changes (watched below) and keeps reconciling on the 30 s tick.
    ref.keepAlive();
    ref.watch(openPositionsTickProvider);
    final id = ref.watch(activeAccountIdProvider);
    if (id == null) return const <Position>[];
    final api = ref.watch(apiClientProvider);
    // A trade the server reports as closed is dropped from the CURRENT list in place. It must
    // not rebuild (refetch) this provider: a Close All reports one closed id per trade, and a
    // rebuild per id both hammers /positions and, overlapping a refresh, blanked the list.
    ref.listen<Set<String>>(closedPositionIdsProvider, (_, closedNow) {
      final cur = state.valueOrNull;
      if (state.isLoading || cur == null || !cur.any((p) => closedNow.contains(p.id))) return;
      state = AsyncData([for (final p in cur) if (!closedNow.contains(p.id)) p]);
    });
    final startedAt = DateTime.now();
    final data = await api.get('/positions', query: {'accountId': id, 'status': 'OPEN', 'fresh': '1'}) as List;
    final closed = ref.read(closedPositionIdsProvider);
    final fetched = data
        .map((e) => Position.fromJson(e as Map<String, dynamic>))
        .where((p) => !closed.contains(p.id))
        .toList();
    return _withConfirmed(id, fetched, closed, startedAt);
  }

  /// Fetched rows plus confirmed opens the server list does not carry yet. A confirmed trade
  /// the list is still missing is kept only if it was confirmed AFTER this fetch began (the
  /// query may simply predate the commit); one the server omitted from a later fetch is gone.
  List<Position> _withConfirmed(String accountId, List<Position> fetched, Set<String> closed, DateTime startedAt) {
    final confirmed = ref.read(_confirmedOpensProvider);
    final have = {for (final p in fetched) p.id};
    final extra = <Position>[];
    confirmed.removeWhere((pid, c) {
      if (closed.contains(pid) || c.position.accountId != accountId) return true;
      if (have.contains(pid)) return true; // the list caught up
      if (c.at.isBefore(startedAt)) return true; // the server had its chance and omitted it
      extra.add(c.position);
      return false;
    });
    if (extra.isEmpty) return fetched;
    return [...extra, ...fetched];
  }

  /// Show a trade the engine has confirmed as opened, without waiting for a refetch.
  void addConfirmed(Position p) {
    final accountId = ref.read(activeAccountIdProvider);
    if (accountId == null || p.accountId != accountId) return;
    if (ref.read(closedPositionIdsProvider).contains(p.id)) return;
    ref.read(_confirmedOpensProvider).putIfAbsent(p.id, () => _ConfirmedOpen(p));
    final cur = state.valueOrNull;
    if (cur == null || cur.any((x) => x.id == p.id)) return;
    state = AsyncData([p, ...cur]);
  }

  /// Confirmed fill from `POST /orders` (`accepted` with a `positionId`): the response carries
  /// the id and the real fill price; the rest is what was submitted. Returns false (and adds
  /// nothing) unless the backend actually returned a position.
  bool addConfirmedFill(
    Map<dynamic, dynamic> res, {
    required String accountId,
    required String symbol,
    required int digits,
    required String side,
    required double volume,
    double? slPrice,
    double? tpPrice,
  }) {
    final pid = res['positionId'];
    final fill = double.tryParse('${res['fillPrice']}');
    if (res['accepted'] != true || pid is! String || pid.isEmpty || fill == null) return false;
    final filled = double.tryParse('${res['filledVolume']}') ?? volume;
    addConfirmed(Position(
      id: pid,
      accountId: accountId,
      side: side,
      status: 'OPEN',
      volume: filled,
      openPrice: fill,
      slPrice: slPrice,
      tpPrice: tpPrice,
      profit: 0,
      swap: 0,
      symbol: symbol,
      digits: digits,
      openedAt: DateTime.now(),
    ));
    return true;
  }
}

/// Runs [run] now, and at most ONE more time if more requests arrived while it was running.
/// No timer and no wait: the first request starts immediately and a burst of N collapses into
/// the in-flight fetch plus a single trailing one, instead of N restarted fetches that each
/// discard the previous result.
class SingleFlight {
  SingleFlight(this._run);
  final Future<void> Function() _run;
  bool _busy = false;
  bool _again = false;

  void request() {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    _loop();
  }

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        try {
          await _run().timeout(const Duration(seconds: 30));
        } catch (_) {/* the next request retries; never wedge the loop */}
      } while (_again);
    } finally {
      _busy = false;
    }
  }
}

/// Refetch the open positions (coalesced). Prefer this to `ref.invalidate(openPositionsProvider)`
/// on hot paths such as a burst of fills.
final positionsRefreshProvider = Provider<SingleFlight>((ref) {
  return SingleFlight(() async {
    // Wait for the reload to land by listening to the provider (reading `.future` here
    // dropped the list's previous value, which put a loader on the Positions list).
    final done = Completer<void>();
    final sub = ref.listen<AsyncValue<List<Position>>>(openPositionsProvider, (_, next) {
      if (!next.isLoading && !done.isCompleted) done.complete();
    });
    try {
      ref.invalidate(openPositionsProvider);
      await done.future;
    } finally {
      sub.close();
    }
  });
});

/// Refetch the account list (coalesced).
final accountsRefreshProvider = Provider<SingleFlight>((ref) {
  return SingleFlight(() async {
    ref.invalidate(accountsProvider);
    await ref.read(accountsProvider.future);
  });
});

/// The user's selected chart timeframe. Persisted to disk (SharedPreferences)
/// so it survives not just navigating away and back, but a full app restart /
/// web page refresh — instead of snapping back to the 5m default. Call
/// `.notifier.set(tf)` to change it.
class ChartTfController extends StateNotifier<Timeframe> {
  ChartTfController() : super(Timeframe.m5) {
    _restore();
  }
  static const _key = 'bt_chart_tf';

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(_key);
    if (name == null) return;
    final match = Timeframe.values.where((t) => t.name == name);
    if (match.isNotEmpty) state = match.first;
  }

  Future<void> set(Timeframe tf) async {
    state = tf;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, tf.name);
  }
}

final chartTfProvider =
    StateNotifierProvider<ChartTfController, Timeframe>((_) => ChartTfController());

/// The user's selected chart symbol. Persisted to disk (SharedPreferences) so
/// it survives navigating away (e.g. to place a trade) AND a full app restart /
/// web page refresh — instead of falling back to the EURUSD default. Call
/// `.notifier.set(symbol)` to change it.
class ChartSymbolController extends StateNotifier<String> {
  ChartSymbolController() : super('EURUSD') {
    _restore();
  }
  static const _key = 'bt_chart_symbol';

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_key);
    if (s != null && s.isNotEmpty) state = s;
  }

  Future<void> set(String symbol) async {
    state = symbol;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, symbol);
  }
}

final chartSymbolProvider =
    StateNotifierProvider<ChartSymbolController, String>((_) => ChartSymbolController());

/// Request key for a chart series.
class ChartReq {
  final String symbol;
  final Timeframe tf;
  const ChartReq(this.symbol, this.tf);

  @override
  bool operator ==(Object o) => o is ChartReq && o.symbol == symbol && o.tf == tf;
  @override
  int get hashCode => Object.hash(symbol, tf);
}

/// Fires periodically so the cached candle history is refetched and stays in
/// step with the server's freshly-pushed completed bars. The *forming* (current)
/// bar is owned client-side (see formingCandleProvider), so this only reconciles
/// finished history — it never resets the live bar.
final _chartTicker = StreamProvider.autoDispose<int>(
  (ref) => Stream<int>.periodic(const Duration(seconds: 30), (i) => i + 1),
);

/// In-memory candle history by [ChartReq]. Survives timeframe switches so the
/// first open downloads history, then TF / revisit is instant from cache.
final _candleCacheProvider =
    StateProvider<Map<ChartReq, List<Candle>>>((_) => const {});

/// Historical-scrollback paging state per series: whether an older-history
/// fetch is in flight (never queue two), and whether the feed confirmed there
/// is nothing further back (stop asking). Read by [CandleChart] to decide
/// whether it is worth calling [loadOlderCandles] again.
class ChartHistoryState {
  const ChartHistoryState({this.loadingOlder = false, this.exhausted = false, this.retryAtMs = 0});
  final bool loadingOlder;
  final bool exhausted;

  /// After a failed page request, don't ask again before this epoch-ms — the
  /// chart re-asks on every rebuild while parked at the edge.
  final int retryAtMs;
  ChartHistoryState copyWith({bool? loadingOlder, bool? exhausted, int? retryAtMs}) => ChartHistoryState(
        loadingOlder: loadingOlder ?? this.loadingOlder,
        exhausted: exhausted ?? this.exhausted,
        retryAtMs: retryAtMs ?? this.retryAtMs,
      );
}

final chartHistoryStateProvider =
    StateProvider.family<ChartHistoryState, ChartReq>((_, __) => const ChartHistoryState());

/// One "page" of older history per lazy-load step (matches the gateway's
/// `before` pagination — see market.controller.ts).
const int kOlderPageSize = 500;

/// The broker's UTC offset in seconds (the gateway's `BROKER_UTC_OFFSET_SEC`), which decides where
/// H4 and D1 bars begin. Fetched once per session from `/market/clock`; 0 when unavailable, which
/// is the plain UTC grid and exactly what the client did before this existed.
final brokerOffsetSecProvider = FutureProvider<int>((ref) async {
  ref.watch(sessionEpochProvider);
  try {
    final api = ref.watch(apiClientProvider);
    final d = await api.get('/market/clock');
    final v = d is Map ? d['brokerUtcOffsetSec'] : null;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? 0}') ?? 0;
  } catch (_) {
    return 0;
  }
});

/// Historical (completed) candles from the gateway. Cached per symbol+TF so
/// changing timeframe after the first load does not wait on the network again.
final candlesProvider = FutureProvider.autoDispose.family<List<Candle>, ChartReq>((ref, req) async {
  // The offset decides where H4 / D1 bars begin, so it is known before any bar is placed.
  await ref.watch(brokerOffsetSecProvider.future);
  final cache = ref.read(_candleCacheProvider);
  final cached = cache[req];
  // KeepAlive while this chart series is in use; cache outlives the provider.
  final link = ref.keepAlive();
  Timer? disposeTimer;
  ref.onCancel(() {
    disposeTimer?.cancel();
    disposeTimer = Timer(const Duration(minutes: 15), link.close);
  });
  ref.onResume(() => disposeTimer?.cancel());
  ref.onDispose(() => disposeTimer?.cancel());

  // Soft background refresh only when we already have data (don't blank UI).
  if (cached != null && cached.isNotEmpty) {
    ref.listen(_chartTicker, (_, __) {
      _refreshCandles(ref, req);
    });
    return cached;
  }

  final candles = await _fetchCandles(ref, req);
  ref.read(_candleCacheProvider.notifier).state = {...ref.read(_candleCacheProvider), req: candles};
  return candles;
});

Future<List<Candle>> _fetchCandles(Ref ref, ChartReq req, {int? before}) async {
  final api = ref.read(apiClientProvider);
  final data = await api.get('/market/candles', query: {
    'symbol': req.symbol,
    'tf': req.tf.api,
    // Deep history on first load; gateway caps apply server-side.
    'limit': before == null ? '5000' : '$kOlderPageSize',
    if (before != null) 'before': '$before',
  }) as List;
  return data.map((e) => Candle.fromJson(e)).toList();
}

/// Merge a freshly-fetched (always latest-tail) series over the cached one by
/// timestamp: the fresh fetch wins where they overlap (it reflects the latest
/// close/high/low), but anything older that the fresh fetch doesn't cover
/// (i.e. history already paged in via [loadOlderCandles]) is kept rather than
/// dropped. A plain overwrite here would silently undo every "scroll back"
/// page the next time the 30s soft-refresh ticks.
List<Candle> _mergeKeepingOlder(List<Candle>? existing, List<Candle> fresh) {
  if (existing == null || existing.isEmpty) return fresh;
  if (fresh.isEmpty) return existing;
  final byT = <int, Candle>{for (final c in existing) c.t: c};
  for (final c in fresh) {
    byT[c.t] = c;
  }
  final times = byT.keys.toList()..sort();
  return [for (final t in times) byT[t]!];
}

Future<void> _refreshCandles(Ref ref, ChartReq req) async {
  try {
    final fresh = await _fetchCandles(ref, req);
    final cache = ref.read(_candleCacheProvider);
    ref.read(_candleCacheProvider.notifier).state = {
      ...cache,
      req: _mergeKeepingOlder(cache[req], fresh),
    };
    ref.invalidate(candlesProvider(req));
  } catch (_) {
    // Keep serving cache on refresh failure.
  }
}

/// Fetch and prepend one page of history older than what is currently loaded
/// for a [ChartReq]. Guards against a duplicate in-flight request and against
/// re-asking once the feed has confirmed there is nothing further back, and
/// never touches the already-loaded tail (no full reload, no jump — the
/// existing bars keep the same distance-from-newest, so the viewport the user
/// is looking at does not move).
///
/// A plain top-level `Future<void> Function(Ref, ChartReq)` cannot be called
/// with a widget's `WidgetRef` (Riverpod keeps `Ref` and `WidgetRef` as
/// separate types on purpose — a widget may not `ref.watch` outside build).
/// Wrapping the body in a provider sidesteps that cleanly: `ref.read(...)` on
/// either kind of ref is always valid and returns this loader, built with the
/// real provider-side [Ref] it then uses internally.
final chartHistoryLoaderProvider =
    Provider.autoDispose.family<ChartHistoryLoader, ChartReq>((ref, req) => ChartHistoryLoader(ref, req));

class ChartHistoryLoader {
  ChartHistoryLoader(this._ref, this._req);
  final Ref _ref;
  final ChartReq _req;

  /// Called by [CandleChart] when the user pans near the beginning of the
  /// loaded window.
  Future<void> loadOlder() async {
    final ref = _ref;
    final req = _req;
    final st = ref.read(chartHistoryStateProvider(req));
    if (st.loadingOlder || st.exhausted || DateTime.now().millisecondsSinceEpoch < st.retryAtMs) return;
    final have = ref.read(_candleCacheProvider)[req];
    if (have == null || have.isEmpty) return;
    ref.read(chartHistoryStateProvider(req).notifier).state = st.copyWith(loadingOlder: true);
    try {
      final oldestT = have.first.t;
      final older = await _fetchCandles(ref, req, before: oldestT);
      final distinct = older.where((c) => c.t < oldestT).toList();
      if (distinct.isEmpty) {
        ref.read(chartHistoryStateProvider(req).notifier).state =
            const ChartHistoryState(loadingOlder: false, exhausted: true);
        return;
      }
      final cache = ref.read(_candleCacheProvider);
      ref.read(_candleCacheProvider.notifier).state = {
        ...cache,
        req: [...distinct, ...have],
      };
      ref.read(chartHistoryStateProvider(req).notifier).state = ChartHistoryState(
        loadingOlder: false,
        // Only an empty page proves the start of history: a rolled-up page can
        // legitimately hold fewer than kOlderPageSize bars and still have more
        // behind it.
        exhausted: false,
      );
      ref.invalidate(candlesProvider(req));
    } catch (_) {
      ref.read(chartHistoryStateProvider(req).notifier).state =
          st.copyWith(loadingOlder: false, retryAtMs: DateTime.now().millisecondsSinceEpoch + 5000);
    }
  }
}

/// Warm every timeframe for [symbol] so TF chips switch instantly after first open.
Future<void> prefetchChartHistory(
  String symbol,
  Future<List<Candle>> Function(ChartReq req) load,
) async {
  for (final tf in Timeframe.values) {
    try {
      await load(ChartReq(symbol, tf));
    } catch (_) {
      // Ignore individual TF failures; chart still works for loaded TFs.
    }
  }
}

/// The current, still-forming candle — built entirely client-side from the live
/// tick stream so it behaves like MT5: the close tracks the price tick-by-tick,
/// the high/low wicks extend as price moves within the bar, and a fresh bar
/// rolls when the timeframe bucket advances (on the clock, even with no ticks).
class FormingCandle {
  final int bucket; // bar open time, epoch seconds, aligned to tf
  final double o, h, l, c;
  const FormingCandle(this.bucket, this.o, this.h, this.l, this.c);
  Candle toCandle() => Candle(t: bucket, o: o, h: h, l: l, c: c, v: 0);
}

class FormingCandleNotifier extends StateNotifier<FormingCandle?> {
  FormingCandleNotifier(this._ref, this._req) : super(null) {
    // React to every live tick for this symbol. Chart bars are BID-based (MT5
    // convention, and the bridge pushes MT5 bid bars), so the forming bar tracks
    // the bid — this keeps it flush with the completed history (no half-spread
    // step when a bar closes).
    _ref.listen<Tick?>(
      quotesProvider.select((m) => m[_req.symbol]),
      (_, t) {
        if (t != null) _onPrice(t);
      },
      fireImmediately: true,
    );
    // Roll the bar on the clock so it completes on time even on a quiet market.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _roll());
  }

  final Ref _ref;
  final ChartReq _req;
  Timer? _timer;

  /// Prefer the tick's market timestamp so the forming bar stays locked to the
  /// same clock as the server candle buckets (avoids price-line / candle drift
  /// when the device clock is skewed).
  int _bucketFor(Tick? t) {
    var ts = t?.ts ?? 0;
    if (ts > 1000000000000) ts = ts ~/ 1000; // ms → sec
    if (ts <= 0) ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _req.tf.bucketStart(ts, brokerOffsetSec: _ref.read(brokerOffsetSecProvider).valueOrNull ?? 0);
  }

  /// A single tick further than this fraction from the bar's last close is held back until
  /// a second tick agrees with it (see [_onPrice]).
  static const double _jumpFrac = 0.002;
  double? _pendingJump;

  /// Reject ticks that cannot be a real quote: a non-positive bid, or a bid / ask so far
  /// apart (> 1 % of price) that one side is clearly stale or wrong.
  bool _plausible(Tick t) {
    if (!(t.bid > 0)) return false;
    if (t.ask > 0 && (t.ask - t.bid).abs() > t.bid * 0.01) return false;
    return true;
  }

  void _onPrice(Tick tick) {
    if (!_plausible(tick)) return;
    final mid = tick.bid;
    final cur = state;
    final b = _bucketFor(tick);
    // Spike guard. The forming bar is built here from raw ticks, and one bad bid (a
    // stale or mis-quoted tick) used to stretch its high / low into a long wick that
    // vanished when the server's finished bar replaced it at close. A tick that jumps
    // more than [_jumpFrac] from the current close is therefore NOT drawn on its own; it
    // is drawn only once a following tick lands near it too (a real move / gap), and a
    // lone spike that the next tick abandons is dropped.
    if (cur != null && b >= cur.bucket && cur.c > 0 && (mid - cur.c).abs() / cur.c > _jumpFrac) {
      final p = _pendingJump;
      if (p == null || (mid - p).abs() / p > _jumpFrac) {
        _pendingJump = mid;
        return;
      }
    }
    _pendingJump = null;
    if (cur == null) {
      // First tick after opening the chart / changing timeframe. Seed from the
      // server's own current-bucket bar (market-data flushes the partial bar) so
      // the forming candle continues where history left off instead of gapping
      // to the current price.
      state = _seed(b, mid);
    } else if (b > cur.bucket) {
      // New bar: open at the FIRST tick of the new bucket — the same rule the
      // server's candle engine uses (open is written once, from the first tick).
      // Any difference from the previous close is the real tick-to-tick move in
      // the feed, never something this app manufactures or hides.
      state = FormingCandle(b, mid, mid, mid, mid);
    } else if (b == cur.bucket) {
      // Same bar: close follows price; wicks extend to new extremes.
      state = FormingCandle(cur.bucket, cur.o, mid > cur.h ? mid : cur.h, mid < cur.l ? mid : cur.l, mid);
    }
  }

  /// Build the initial forming bar continuous with history: prefer the server's
  /// bar for the current bucket (real open + high/low so far), else open at the
  /// last completed bar's close, else the first live price.
  FormingCandle _seed(int b, double mid) {
    final hist = _ref.read(candlesProvider(_req)).valueOrNull;
    if (hist != null && hist.isNotEmpty) {
      for (final c in hist) {
        if (c.t == b) {
          return FormingCandle(b, c.o, mid > c.h ? mid : c.h, mid < c.l ? mid : c.l, mid);
        }
      }
      final open = hist.last.c; // history is oldest→newest; last = latest close
      return FormingCandle(b, open, mid > open ? mid : open, mid < open ? mid : open, mid);
    }
    return FormingCandle(b, mid, mid, mid, mid);
  }

  void _roll() {
    final cur = state;
    if (cur == null) return;
    final tick = _ref.read(quotesProvider)[_req.symbol];
    final b = _bucketFor(tick);
    if (b > cur.bucket) {
      // Time advanced without a tick → open a flat bar at the last close (MT5
      // shows a doji until the next tick moves it).
      state = FormingCandle(b, cur.c, cur.c, cur.c, cur.c);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final formingCandleProvider =
    StateNotifierProvider.autoDispose.family<FormingCandleNotifier, FormingCandle?, ChartReq>(
  (ref, req) => FormingCandleNotifier(ref, req),
);

/// Live series = REST history, overlaid with the server's pushed bars (the
/// canonical candle engine's OHLC), with this device's tick stream extending only
/// the tip's close and extremes.
///
/// Why: the server owns OHLC. Rebuilding the forming bar purely from the ticks this
/// device happened to receive meant a reconnect, a backgrounded tab or a dropped
/// frame produced a bar whose open/high/low differed from the server's — a
/// platform-made discontinuity. Now the open always comes from the server bar when
/// it has one; ticks can only widen high/low (both are real feed prices) and move
/// the close to the latest price.
final liveCandlesProvider = Provider.autoDispose.family<AsyncValue<List<Candle>>, ChartReq>((ref, req) {
  final base = ref.watch(candlesProvider(req));
  final history = base.valueOrNull;
  if (history == null) return base; // first load / error
  if (history.isEmpty) return const AsyncValue.data(<Candle>[]);

  final pushed = ref.watch(serverCandlesProvider.select((m) => m[ServerCandlesNotifier.seriesKey(req.symbol, req.tf.api)]));
  final forming = ref.watch(formingCandleProvider(req));

  // Identity is the bucket time: a bar present in both sources collapses into one.
  final byT = <int, Candle>{for (final c in history) c.t: c};
  if (pushed != null) byT.addAll(pushed);

  if (forming != null) {
    final newestPushed = pushed == null || pushed.isEmpty ? 0 : pushed.keys.reduce((a, b) => a > b ? a : b);
    // A device that is behind the server must not overwrite a newer server bar.
    if (forming.bucket >= newestPushed) {
      final s = byT[forming.bucket];
      byT[forming.bucket] = s == null
          ? forming.toCandle()
          : Candle(
              t: s.t,
              o: s.o,
              h: forming.h > s.h ? forming.h : s.h,
              l: forming.l < s.l ? forming.l : s.l,
              c: forming.c,
              v: s.v,
            );
    }
  }

  final times = byT.keys.toList()..sort();
  return AsyncValue.data([for (final t in times) byT[t]!]);
});
