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
final openPositionsProvider = FutureProvider.autoDispose<List<Position>>((ref) async {
  ref.watch(_chartTicker); // background reconcile (instant draw is optimistic, client-side)
  final id = ref.watch(activeAccountIdProvider);
  if (id == null) return const <Position>[];
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/positions', query: {'accountId': id, 'status': 'OPEN'}) as List;
  return data.map((e) => Position.fromJson(e)).toList();
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

/// Historical (completed) candles from the gateway. Cached per symbol+TF so
/// changing timeframe after the first load does not wait on the network again.
final candlesProvider = FutureProvider.autoDispose.family<List<Candle>, ChartReq>((ref, req) async {
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

Future<List<Candle>> _fetchCandles(Ref ref, ChartReq req) async {
  final api = ref.read(apiClientProvider);
  final data = await api.get('/market/candles', query: {
    'symbol': req.symbol,
    'tf': req.tf.api,
    // Deep history on first load; gateway caps apply server-side.
    'limit': '5000',
  }) as List;
  return data.map((e) => Candle.fromJson(e)).toList();
}

Future<void> _refreshCandles(Ref ref, ChartReq req) async {
  try {
    final candles = await _fetchCandles(ref, req);
    ref.read(_candleCacheProvider.notifier).state = {
      ...ref.read(_candleCacheProvider),
      req: candles,
    };
    ref.invalidate(candlesProvider(req));
  } catch (_) {
    // Keep serving cache on refresh failure.
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
        if (t != null) _onPrice(t.bid);
      },
      fireImmediately: true,
    );
    // Roll the bar on the clock so it completes on time even on a quiet market.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _roll());
  }

  final Ref _ref;
  final ChartReq _req;
  Timer? _timer;

  int get _nowBucket => _req.tf.bucketStart(DateTime.now().millisecondsSinceEpoch ~/ 1000);

  void _onPrice(double mid) {
    final cur = state;
    final b = _nowBucket;
    if (cur == null) {
      // First tick after opening the chart / changing timeframe. Seed from the
      // server's own current-bucket bar (market-data flushes the partial bar) so
      // the forming candle continues where history left off instead of gapping
      // to the current price.
      state = _seed(b, mid);
    } else if (b > cur.bucket) {
      // New bar: open at the previous close for continuity.
      final open = cur.c;
      state = FormingCandle(b, open, mid > open ? mid : open, mid < open ? mid : open, mid);
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
    final b = _nowBucket;
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

/// Live series: completed history from the server + the client-owned forming
/// bar at the right edge. The forming bar is never overwritten by the history
/// refetch, so wicks grow smoothly and bars complete on schedule.
final liveCandlesProvider = Provider.autoDispose.family<AsyncValue<List<Candle>>, ChartReq>((ref, req) {
  final base = ref.watch(candlesProvider(req));
  final candles = base.valueOrNull;
  if (candles == null) return base; // first load / error
  if (candles.isEmpty) return const AsyncValue.data(<Candle>[]);

  final forming = ref.watch(formingCandleProvider(req));
  if (forming == null) return AsyncValue.data(candles);

  // Keep completed bars strictly before the forming bucket, then append the live
  // bar. Drops the server's copy of the current bucket in favour of the
  // tick-accurate client one.
  final hist = candles.where((c) => c.t < forming.bucket).toList();
  return AsyncValue.data([...hist, forming.toCandle()]);
});
