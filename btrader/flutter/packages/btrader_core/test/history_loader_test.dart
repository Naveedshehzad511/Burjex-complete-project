import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gateway stand-in with a FINITE history ([total] M5 bars ending at [newest]) that honours
/// `limit` and the `before` timestamp cursor exactly like /market/candles does.
class _HistoryApi extends ApiClient {
  _HistoryApi({this.total = 3000, this.delay = Duration.zero}) : super(AuthStore());
  final int total;
  final Duration delay;
  static const step = 300;
  final int newest = 1700000000 ~/ step * step;
  final requests = <Map<String, dynamic>>[];

  int get oldest => newest - (total - 1) * step;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path != '/market/candles') return <dynamic>[];
    requests.add(Map<String, dynamic>.from(query ?? const {}));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final limit = int.parse('${query!['limit']}');
    final before = query['before'] == null ? null : int.parse('${query['before']}');
    final last = before == null ? newest : before - step;
    final out = <Map<String, dynamic>>[];
    for (var t = last; t >= oldest && out.length < limit; t -= step) {
      out.add({'t': t, 'o': 1.0, 'h': 1.1, 'l': 0.9, 'c': 1.0, 'v': 1});
    }
    return out.reversed.toList();
  }
}

void main() {
  const req = ChartReq('EURUSD', Timeframe.m5);

  Future<(ProviderContainer, _HistoryApi)> make({int total = 3000, Duration delay = Duration.zero}) async {
    final api = _HistoryApi(total: total, delay: delay);
    final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    c.listen(candlesProvider(req), (_, __) {});
    await c.read(candlesProvider(req).future);
    return (c, api);
  }

  /// loadOlder re-publishes the cache through candlesProvider asynchronously; wait for that.
  Future<void> older(ProviderContainer c, int visible) async {
    await c.read(chartHistoryLoaderProvider(req)).loadOlder(visibleBars: visible);
    await c.read(candlesProvider(req).future);
  }

  List<Candle> loaded(ProviderContainer c) => c.read(candlesProvider(req)).valueOrNull ?? const [];

  void expectContinuous(List<Candle> l) {
    for (var i = 1; i < l.length; i++) {
      expect(l[i].t - l[i - 1].t, _HistoryApi.step, reason: 'gap or duplicate at index $i');
    }
  }

  test('overlayCandles matches keying everything by time and sorting', () {
    final rnd = math.Random(7);
    for (var round = 0; round < 200; round++) {
      final n = rnd.nextInt(40);
      final base = [for (var i = 0; i < n; i++) Candle(t: 1000 + i * 60, o: 1, h: 1, l: 1, c: 1, v: 0)];
      final over = <int, Candle>{};
      for (var k = rnd.nextInt(6); k > 0; k--) {
        // existing bars, bars after the end, and the odd bar inside the range / before it
        final t = 1000 + (rnd.nextInt(n + 5) - (rnd.nextInt(8) == 0 ? 3 : 0)) * 60;
        over[t] = Candle(t: t, o: 2, h: 2, l: 2, c: 2, v: 1);
      }
      final naive = <int, Candle>{for (final c in base) c.t: c, ...over};
      final want = [for (final t in (naive.keys.toList()..sort())) naive[t]!];
      final got = overlayCandles(base, over);
      expect([for (final c in got) '${c.t}:${c.o}'], [for (final c in want) '${c.t}:${c.o}']);
    }
  });

  test('batch size follows the visible range and stays within the gateway cap', () {
    expect(olderBatchFor(0), kOlderMinBatch);
    expect(olderBatchFor(60), kOlderMinBatch); // zoomed in: light
    expect(olderBatchFor(400), 1600);
    expect(olderBatchFor(100000), kOlderMaxBatch); // zoomed far out: capped
  });

  test('older bars are prepended behind a timestamp cursor, in order, with no duplicates', () async {
    final (c, api) = await make();
    final newestBefore = loaded(c).last.t;
    final firstBefore = loaded(c).first.t;
    expect(loaded(c).length, 3000); // the first load already covers the finite history; shrink it:
    // simulate a shorter first load by using a longer history than the first request returns
    final (c2, api2) = await make(total: 12000);
    final l0 = loaded(c2);
    expect(l0.length, 5000);
    await older(c2, 400);
    final l1 = loaded(c2);
    expect(l1.length, 5000 + 1600, reason: 'batch is sized from the visible range, not a fixed page');
    expect(api2.requests.last['before'], '${l0.first.t}', reason: 'cursor is the oldest loaded bar time');
    expect(api2.requests.last['limit'], '1600');
    expectContinuous(l1);
    expect(l1.last.t, l0.last.t, reason: 'the live end of the series is untouched');
    expect(newestBefore, isNotNull);
    expect(firstBefore, isNotNull);
    expect(api.requests, isNotEmpty);
  });

  test('keeps filling until the real start of history, then stops asking', () async {
    final (c, api) = await make(total: 12000);
    final loader = c.read(chartHistoryLoaderProvider(req));
    for (var i = 0; i < 6; i++) {
      await older(c, 5000);
    }
    final l = loaded(c);
    expect(l.length, 12000, reason: 'whole history, no gaps');
    expectContinuous(l);
    expect(c.read(chartHistoryStateProvider(req)).exhausted, isTrue);
    final n = api.requests.length;
    await loader.loadOlder(visibleBars: 100);
    await loader.loadOlder(visibleBars: 100);
    expect(api.requests.length, n, reason: 'no useless requests once the start is reached');
  });

  test('a burst of calls while a request is in flight makes only one request', () async {
    final (c, api) = await make(total: 12000, delay: const Duration(milliseconds: 80));
    final before = api.requests.length;
    final loader = c.read(chartHistoryLoaderProvider(req));
    await Future.wait([for (var i = 0; i < 8; i++) loader.loadOlder(visibleBars: 300)]);
    expect(api.requests.length - before, 1);
    expectContinuous(loaded(c));
  });

  test('the previous bars stay available while older ones load (no loading state, no blank chart)', () async {
    final (c, _) = await make(total: 12000, delay: const Duration(milliseconds: 80));
    final seen = <int>[];
    c.listen<AsyncValue<List<Candle>>>(candlesProvider(req), (_, n) => seen.add(n.valueOrNull?.length ?? -1));
    final f = c.read(chartHistoryLoaderProvider(req)).loadOlder(visibleBars: 300);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(loaded(c).length, 5000, reason: 'still showing the old list mid-request');
    await f;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen.where((n) => n == -1), isEmpty, reason: 'the value never dropped to nothing');
    expect(loaded(c).length, greaterThan(5000));
  });

  test('timeframes keep separate series', () async {
    final (c, _) = await make(total: 12000);
    await c.read(chartHistoryLoaderProvider(req)).loadOlder(visibleBars: 300);
    const other = ChartReq('EURUSD', Timeframe.m15);
    expect(c.read(chartHistoryStateProvider(other)).loadingOlder, isFalse);
    expect(c.read(chartHistoryStateProvider(other)).exhausted, isFalse);
  });
}
