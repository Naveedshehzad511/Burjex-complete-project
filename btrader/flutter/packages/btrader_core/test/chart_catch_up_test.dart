import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Coming back to a chart (app reopened, resumed, tab shown again): the chart never draws a live bar after bars it has not
/// fetched yet, fetches the whole missed stretch at once, and ends on one continuous, ordered series.

const _sym = 'XAUUSD';
const _step = 60;
const _req = ChartReq(_sym, Timeframe.m1);

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Candle _bar(int t, [double p = 4000]) => Candle(t: t, o: p, h: p + 1, l: p - 1, c: p, v: 1);

/// Gateway stand-in: one M1 bar for every minute from [oldest] to [newest] except those in [missing] (a market break),
/// honouring `limit` and the `before` cursor like /market/candles. Can be slow ([delay]) or fail ([failNext] calls).
class _Gateway extends ApiClient {
  _Gateway({required this.oldest, required this.newest, this.delay = Duration.zero, this.missing = const {}}) : super(AuthStore());
  final int oldest;
  int newest;
  Duration delay;
  final Set<int> missing;
  int failNext = 0;
  bool failAlways = false;
  final requests = <Map<String, dynamic>>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path != '/market/candles') return <dynamic>[];
    requests.add(Map<String, dynamic>.from(query ?? const {}));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failAlways || failNext > 0) {
      if (failNext > 0) failNext--;
      throw Exception('network down');
    }
    final limit = int.parse('${query!['limit']}');
    final before = query['before'] == null ? null : int.parse('${query['before']}');
    final out = <Map<String, dynamic>>[];
    for (var t = before == null ? newest : before - _step; t >= oldest && out.length < limit; t -= _step) {
      if (missing.contains(t)) continue;
      out.add({'t': t, 'o': 4000.0, 'h': 4001.0, 'l': 3999.0, 'c': 4000.0, 'v': 1});
    }
    return out.reversed.toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int nowB; // the minute forming now

  setUp(() {
    nowB = _nowSec() ~/ _step * _step;
    debugSyncRetryMs = const [40, 40, 40, 40];
    debugFirstLoadRetryMs = const [20, 20];
    debugEmptyRecheckMs = 10;
    serverClockSkewMs = null;
  });
  tearDown(() => serverClockSkewMs = null);

  /// The app saved [n] bars ending at [lastT] on an earlier run.
  void savedOnDisk(int lastT, {int n = 300}) {
    final rows = [for (var t = lastT - (n - 1) * _step; t <= lastT; t += _step) [t, 4000.0, 4001.0, 3999.0, 4000.0, 1.0]];
    SharedPreferences.setMockInitialValues({'bt_candles_v1|$_sym|${Timeframe.m1.api}': jsonEncode(rows)});
  }

  ProviderContainer make(_Gateway api) {
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      brokerOffsetSecProvider.overrideWith((ref) async => 0),
    ]);
    addTearDown(c.dispose);
    c.listen(liveCandlesProvider(_req), (_, __) {});
    c.listen(chartUpdatingProvider(_req), (_, __) {});
    return c;
  }

  /// The socket connected now (as it does on every reopen) and the server pushed the bar that is forming.
  void liveNow(ProviderContainer c) {
    c.read(socketLiveSinceProvider.notifier).state = DateTime.now().millisecondsSinceEpoch;
    c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: 4000, ask: 4000.2, ts: _nowSec()));
    c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(nowB, 4005));
  }

  List<Candle> shown(ProviderContainer c) => c.read(liveCandlesProvider(_req)).valueOrNull ?? const [];

  void expectContinuous(List<Candle> l, {Set<int> breaks = const {}}) {
    for (var i = 1; i < l.length; i++) {
      final d = l[i].t - l[i - 1].t;
      if (d == _step) continue;
      expect(breaks.contains(l[i - 1].t + _step), isTrue, reason: 'hole or duplicate before ${l[i].t} (step $d)');
    }
  }

  Future<void> settle([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

  group('a page refresh / the app reopened a moment later', () {
    test('the current candle is there as soon as the history is, before the socket has reconnected', () async {
      savedOnDisk(nowB - _step); // saved a minute ago
      final api = _Gateway(oldest: nowB - 86400, newest: nowB); // the store already holds the forming bar
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: 4000, ask: 4000.2, ts: _nowSec()));
      await settle(); // history fetched; nothing pushed yet
      expect(shown(c).last.t, nowB, reason: 'the stored forming bar is shown');
      expectContinuous(shown(c));
      c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(nowB, 4007));
      expect(shown(c).last.c, 4007, reason: 'then the live one takes over');
      expect(shown(c).where((k) => k.t == nowB), hasLength(1));
    });

    test('a forming bar only from the saved copy is not shown as current', () async {
      final rows = [for (var t = nowB - 9 * _step; t <= nowB; t += _step) [t, 3000.0, 3001.0, 2999.0, 3000.0, 1.0]];
      SharedPreferences.setMockInitialValues({'bt_candles_v1|$_sym|${Timeframe.m1.api}': jsonEncode(rows)});
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step, delay: const Duration(seconds: 2));
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: 4000, ask: 4000.2, ts: _nowSec()));
      await settle(50); // the fetch is still on its way
      expect(shown(c).last.t, nowB - _step, reason: 'the saved forming bar is stale: left out');
    });
  });

  group('reopened from the saved copy after hours away', () {
    test('the live bar is not drawn across the hole; then the whole series appears at once, ending on the live bar', () async {
      final savedLast = nowB - 9 * 3600;
      savedOnDisk(savedLast);
      final api = _Gateway(oldest: nowB - 3 * 86400, newest: nowB - _step, delay: const Duration(milliseconds: 150));
      final c = make(api);
      await c.read(candlesProvider(_req).future); // the saved bars, at once
      liveNow(c);

      // While the missed stretch is on its way: the last complete chart, no jump to the live bar.
      expect(shown(c).last.t, savedLast);
      expect(c.read(chartUpdatingProvider(_req)), isTrue);
      expectContinuous(shown(c));

      await settle();
      final l = shown(c);
      expect(l.last.t, nowB, reason: 'ends on the live bar');
      expect(l.last.c, 4005, reason: 'the live bar is the server-pushed one');
      expect(l.first.t, savedLast - 299 * _step, reason: 'the saved bars are kept, not replaced');
      expectContinuous(l);
      expect(c.read(chartUpdatingProvider(_req)), isFalse);
    });

    test('the whole missed stretch is asked for in one request', () async {
      savedOnDisk(nowB - 2 * 86400); // two days away: 2880 M1 bars
      final api = _Gateway(oldest: nowB - 5 * 86400, newest: nowB - _step);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle();
      final tail = api.requests.where((q) => q['before'] == null).toList();
      expect(tail, hasLength(1));
      expect(int.parse('${tail.single['limit']}'), greaterThanOrEqualTo(2880));
      expect(api.requests.where((q) => q['before'] != null), isEmpty, reason: 'no page-by-page bridging needed');
      expectContinuous(shown(c));
      expect(shown(c).last.t, nowB);
    });

    test('failed requests are retried; nothing is drawn across the hole meanwhile', () async {
      final savedLast = nowB - 3 * 3600;
      savedOnDisk(savedLast);
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step)..failNext = 2;
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle(30);
      expect(shown(c).last.t, savedLast);
      await settle(500);
      expect(api.requests.length, greaterThanOrEqualTo(3));
      expect(shown(c).last.t, nowB);
      expectContinuous(shown(c));
    });

    test('a catch-up that keeps failing never gives up into drawing the hole', () async {
      final savedLast = nowB - 3 * 3600;
      savedOnDisk(savedLast);
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step)..failAlways = true;
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle(600); // every retry spent
      expect(shown(c).last.t, savedLast, reason: 'still the last complete chart');
      expect(c.read(chartUpdatingProvider(_req)), isTrue);
      // The network comes back: the next live bar asks again, and the chart completes.
      api.failAlways = false;
      c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(nowB + _step, 4006));
      await settle();
      expect(shown(c).last.t, nowB + _step);
      expectContinuous(shown(c));
    });

    test('a real market break stays a break, the bars around it are complete', () async {
      final breakStart = nowB - 90 * 60;
      final breakBars = {for (var t = breakStart; t < breakStart + 60 * 60; t += _step) t};
      savedOnDisk(nowB - 5 * 3600);
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step, missing: breakBars);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle();
      final l = shown(c);
      expect(l.last.t, nowB);
      expect(l.where((k) => breakBars.contains(k.t)), isEmpty, reason: 'no invented bars in the break');
      expectContinuous(l, breaks: {breakStart});
    });
  });

  group('market closures are not missing candles', () {
    test('reopened after a weekend: the weekend stays empty, everything around it is complete', () async {
      final weekendStart = nowB - 50 * 3600;
      final weekend = {for (var t = weekendStart; t < weekendStart + 48 * 3600; t += _step) t};
      savedOnDisk(weekendStart - 3600); // closed the app on Friday evening
      final api = _Gateway(oldest: nowB - 5 * 86400, newest: nowB - _step, missing: weekend);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle();
      final l = shown(c);
      expect(l.last.t, nowB);
      expect(l.where((k) => weekend.contains(k.t)), isEmpty);
      expectContinuous(l, breaks: {weekendStart});
      expect(c.read(chartUpdatingProvider(_req)), isFalse);
    });

    test('opened while the market is closed: the last session is shown complete and nothing waits forever', () async {
      final closedAt = nowB - 3 * 3600;
      savedOnDisk(nowB - 10 * 3600);
      final api = _Gateway(oldest: nowB - 86400, newest: closedAt);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      c.read(socketLiveSinceProvider.notifier).state = DateTime.now().millisecondsSinceEpoch;
      // The last quote is from when the market closed: nothing is forming.
      c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: 4000, ask: 4000.2, ts: closedAt + 30));
      await settle();
      expect(shown(c).last.t, closedAt);
      expectContinuous(shown(c));
      expect(c.read(chartUpdatingProvider(_req)), isFalse);
    });
  });

  group('a phone clock that is wrong', () {
    test('a phone clock 10 minutes behind does not let the bars missed while away through', () async {
      serverClockSkewMs = 10 * 60 * 1000; // the server is 10 minutes ahead of this phone
      final serverB = (_nowSec() + 600) ~/ _step * _step;
      final t0 = serverB - 5 * _step; // stored up to 5 minutes ago (server time)
      final c = ProviderContainer(overrides: [
        candlesProvider.overrideWith((ref, r) async => [for (var i = 0; i < 10; i++) _bar(t0 - (9 - i) * _step)]),
        brokerOffsetSecProvider.overrideWith((ref) async => 0),
      ]);
      addTearDown(c.dispose);
      c.listen(liveCandlesProvider(_req), (_, __) {});
      // The app came back just now (phone clock); the bars of the last 4 minutes were never received.
      c.read(socketLiveSinceProvider.notifier).state = DateTime.now().millisecondsSinceEpoch;
      c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(serverB, 4002));
      await c.read(candlesProvider(_req).future);
      expect(c.read(liveCandlesProvider(_req)).valueOrNull!.last.t, t0, reason: 'judged in server time, not phone time');
    });

    test('the server clock is measured from /market/clock', () async {
      final api = _ClockApi(serverAheadMs: 7 * 60 * 1000);
      final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
      addTearDown(c.dispose);
      SharedPreferences.setMockInitialValues({});
      await c.read(brokerOffsetSecProvider.future);
      expect(serverClockSkewMs, closeTo(7 * 60 * 1000, 2000));
      expect(serverNowMs() - DateTime.now().millisecondsSinceEpoch, closeTo(7 * 60 * 1000, 2000));
    });
  });

  group('requests', () {
    test('a chart kept but not on screen does not fetch when the app comes back; it does when shown again', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        brokerOffsetSecProvider.overrideWith((ref) async => 0),
      ]);
      addTearDown(c.dispose);
      await c.read(candlesProvider(_req).future); // warmed (as the prefetch does), nobody watching
      await settle(20);
      final before = api.requests.length;
      c.read(chartResumeEpochProvider.notifier).state++;
      await settle(100);
      expect(api.requests.length, before, reason: 'not on screen: no request');
      c.listen(liveCandlesProvider(_req), (_, __) {}); // the chart shows it again
      await settle(100);
      expect(api.requests.length, before + 1, reason: 'what it missed is fetched once, when shown');
    });

    test('a normal live chart makes no extra requests as bars roll', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      liveNow(c);
      await settle(50);
      final before = api.requests.length;
      for (var i = 1; i <= 5; i++) {
        c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(nowB + i * _step, 4000.0 + i));
      }
      await settle(100);
      expect(api.requests.length, before);
      expect(shown(c).last.t, nowB + 5 * _step);
      expectContinuous(shown(c));
    });

    test('coming back makes one request per chart on screen', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      final before = api.requests.length;
      c.read(chartResumeEpochProvider.notifier).state++;
      c.read(socketEpochProvider.notifier).state++; // the socket reconnects in the same moment
      await settle(200);
      expect(api.requests.length, inInclusiveRange(before + 1, before + 2));
    });
  });

  group('catch-up triggers', () {
    Future<(ProviderContainer, _Gateway)> loaded() async {
      SharedPreferences.setMockInitialValues({});
      final api = _Gateway(oldest: nowB - 86400, newest: nowB - _step);
      final c = make(api);
      await c.read(candlesProvider(_req).future);
      return (c, api);
    }

    test('coming back to the foreground fetches at once, without waiting for a reconnect', () async {
      final (c, api) = await loaded();
      final before = api.requests.length;
      c.read(chartResumeEpochProvider.notifier).state++;
      await settle(50);
      expect(api.requests.length, before + 1);
    });

    test('a trigger that arrives while a catch-up is running is not dropped', () async {
      final (c, api) = await loaded();
      api.delay = const Duration(milliseconds: 150);
      final before = api.requests.length;
      c.read(chartResumeEpochProvider.notifier).state++; // starts one
      await settle(20);
      c.read(socketEpochProvider.notifier).state++; // the socket reconnects while it runs
      await settle(500);
      expect(api.requests.length, before + 2, reason: 'the second trigger runs after the first, not never');
    });
  });

  group('which live bars are drawn after the stored ones', () {
    final t0 = 1700000000 ~/ _step * _step;

    ProviderContainer display() {
      final c = ProviderContainer(overrides: [
        candlesProvider.overrideWith((ref, r) async => [for (var i = 0; i < 10; i++) _bar(t0 - (9 - i) * _step)]),
        brokerOffsetSecProvider.overrideWith((ref) async => 0),
      ]);
      addTearDown(c.dispose);
      c.listen(liveCandlesProvider(_req), (_, __) {});
      return c;
    }

    Future<List<int>> times(ProviderContainer c) async {
      await c.read(candlesProvider(_req).future);
      return [for (final k in c.read(liveCandlesProvider(_req)).valueOrNull!) k.t];
    }

    void push(ProviderContainer c, int t) => c.read(serverCandlesProvider.notifier).upsert(_sym, Timeframe.m1.api, _bar(t, 4002));

    test('an unbroken run after the stored bars is drawn (normal live chart)', () async {
      final c = display();
      push(c, t0 + _step);
      push(c, t0 + 2 * _step);
      expect((await times(c)).last, t0 + 2 * _step);
    });

    test('a bar after a missing bucket nobody vouched for is held back', () async {
      final c = display();
      push(c, t0 + _step);
      push(c, t0 + 4 * _step); // two minutes never received
      expect((await times(c)).last, t0 + _step);
    });

    test('drawn once the server was asked after the missing buckets and had nothing', () async {
      final c = display();
      push(c, t0 + 5 * _step);
      c.read(chartVerifiedAtProvider(_req).notifier).state = t0 + 5 * _step + 15;
      expect((await times(c)).last, t0 + 5 * _step);
    });

    test('drawn when the missing buckets began while the live stream was reaching the device (minutes without trades)', () async {
      final c = display();
      c.read(socketLiveSinceProvider.notifier).state = (t0 - 600) * 1000;
      push(c, t0 + 3 * _step);
      expect((await times(c)).last, t0 + 3 * _step);
    });

    test('a daily session break watched live is drawn at once', () async {
      final c = display();
      c.read(socketLiveSinceProvider.notifier).state = (t0 - 600) * 1000;
      push(c, t0 + 61 * _step); // the market reopened an hour later
      expect((await times(c)).last, t0 + 61 * _step);
    });

    test('a stored bar is still replaced by the live one', () async {
      final c = display();
      push(c, t0);
      final l = c.read(liveCandlesProvider(_req)).valueOrNull ?? await c.read(candlesProvider(_req).future);
      await c.read(candlesProvider(_req).future);
      final last = c.read(liveCandlesProvider(_req)).valueOrNull!.last;
      expect(l, isNotEmpty);
      expect(last.t, t0);
      expect(last.c, 4002);
    });
  });
}

/// Answers /market/clock with a server clock [serverAheadMs] ahead of this machine's.
class _ClockApi extends ApiClient {
  _ClockApi({required this.serverAheadMs}) : super(AuthStore());
  final int serverAheadMs;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path != '/market/clock') return <dynamic>[];
    return {'serverEpochMs': DateTime.now().millisecondsSinceEpoch + serverAheadMs, 'brokerUtcOffsetSec': 0};
  }
}
