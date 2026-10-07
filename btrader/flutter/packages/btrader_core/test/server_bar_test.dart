import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The bar that is forming is the SERVER's, for every timeframe: device ticks and the REST tip never
// take part, so the live bar and the finalized bar cannot disagree.
const _sym = 'XAUUSD';

Candle _bar(int t, double o, double h, double l, double c) => Candle(t: t, o: o, h: h, l: l, c: c, v: 0);

/// A chart series for [tf]: history that ends at the previous bucket plus a STORED TIP for the
/// current one (the REST copy - stale, and here deliberately carrying a false low).
class _Rig {
  _Rig(this.tf) : nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000 {
    req = ChartReq(_sym, tf);
    cur = tf.bucketStart(nowSec);
    prev = tf.bucketStart(cur - 1);
    prev2 = tf.bucketStart(prev - 1);
    history = [
      _bar(prev2, 4160, 4165, 4158, 4163),
      _bar(prev, 4163, 4170, 4162, 4169),
      _bar(cur, 4169, 4170, 4140, 4150), // stored tip with a false low
    ];
    c = ProviderContainer(overrides: [
      candlesProvider.overrideWith((ref, r) async => history),
      brokerOffsetSecProvider.overrideWith((ref) async => 0),
    ]);
  }
  final Timeframe tf;
  final int nowSec;
  late final ChartReq req;
  late final int cur, prev, prev2;
  late final List<Candle> history;
  late final ProviderContainer c;
  late final ProviderSubscription<AsyncValue<List<Candle>>> sub;

  Future<void> open() async {
    await c.read(candlesProvider(req).future);
    sub = c.listen(liveCandlesProvider(req), (_, __) {});
  }

  List<Candle> get series => sub.read().value!;
  Candle get last => series.last;

  void tick(double bid, {int? ts}) =>
      c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: bid, ask: bid + 0.2, ts: ts ?? nowSec));
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));
  void push(Candle k, [Timeframe? other]) => c.read(serverCandlesProvider.notifier).upsert(_sym, (other ?? tf).api, k);
  void dispose() => c.dispose();
}

List<List<num>> _flat(List<Candle> s) => s.map((k) => [k.t, k.o, k.h, k.l, k.c]).toList();

void main() {
  group('serverAuthoritativeSeries', () {
    final h = [_bar(60, 1, 2, 0, 1), _bar(120, 1, 2, 0, 1), _bar(180, 1, 9, 0, 1)];

    test('leaves out only the trailing bars at or after the current bucket that were not pushed', () {
      expect(serverAuthoritativeSeries(h, null, currentBucket: 180).map((k) => k.t), [60, 120]);
    });

    test('a pushed bar for the current bucket takes the stored one\'s place', () {
      final out = serverAuthoritativeSeries(h, {180: _bar(180, 1, 3, 1, 2)}, currentBucket: 180);
      expect(out.map((k) => k.t), [60, 120, 180]);
      expect(out.last.h, 3);
    });

    test('everything older than the current bucket is untouched', () {
      expect(serverAuthoritativeSeries(h, null, currentBucket: 1000).length, 3);
    });

    test('feed not live (null bucket): nothing is forming, every stored bar stays', () {
      expect(serverAuthoritativeSeries(h, null, currentBucket: null).last.t, 180);
    });
  });

  for (final tf in Timeframe.values) {
    group(tf.name, () {
      test('first load / quiet symbol: the stored tip is not drawn, nothing is invented', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open(); // no quote, no pushed bar
        expect(r.last.t, r.prev);
        expect(r.series.any((k) => k.t == r.cur), isFalse);
        expect(r.series.any((k) => k.l < 4150), isFalse); // the tip's false low is not on the chart
      });

      test('device ticks, including bad ones, never create or change a bar', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open();
        final before = _flat(r.series);
        for (final px in [4172.0, 4159.6, 4172.1, 4159.5, 4159.4]) {
          r.tick(px); // the last two are close together: the old spike guard let that through
          await r.settle();
        }
        expect(_flat(r.series), before);
      });

      test('the pushed bar becomes the current bar exactly, whatever the device saw', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open();
        r.tick(4159.6);
        await r.settle();
        final srv = _bar(r.cur, 4171, 4172.6, 4170.9, 4172.5);
        r.push(srv);
        expect([r.last.t, r.last.o, r.last.h, r.last.l, r.last.c], [srv.t, srv.o, srv.h, srv.l, srv.c]);
        r.tick(4150.0); // a device-only tick afterwards changes nothing
        await r.settle();
        expect([r.last.o, r.last.h, r.last.l, r.last.c], [srv.o, srv.h, srv.l, srv.c]);
      });

      test('reconnect: the gateway snapshot restores the current bar, then live frames continue', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open();
        expect(r.last.t, r.prev); // socket just (re)connected: no server bar yet
        r.push(_bar(r.cur, 4171, 4172, 4170, 4171.5)); // the snapshot is an ordinary candle frame
        expect([r.last.t, r.last.c], [r.cur, 4171.5]);
        r.push(_bar(r.cur, 4171, 4173, 4170, 4172.9)); // next live frame
        expect([r.last.h, r.last.c], [4173, 4172.9]);
      });

      test('rapid movement: the drawn bar is always the newest server bar', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open();
        var h = 4171.0, l = 4171.0;
        for (var i = 0; i < 200; i++) {
          final px = 4171.0 + ((i * 37) % 23) - 11; // swings up and down
          if (px > h) h = px;
          if (px < l) l = px;
          r.tick(px + (i.isEven ? 0 : -30)); // device ticks disagree with the server
          r.push(_bar(r.cur, 4171, h, l, px));
          final k = r.last;
          expect([k.t, k.o, k.h, k.l, k.c], [r.cur, 4171, h, l, px]);
        }
      });

      test('close: the last live bar and the finalized bar are identical, with no step', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        await r.open();
        r.push(_bar(r.cur, 4171, 4172.6, 4170.9, 4172.5));
        r.tick(4159.6); // device-only noise right before the close
        await r.settle();
        final live = r.series.firstWhere((k) => k.t == r.cur);
        // The closing push of the same bar, then the next bucket's first push.
        r.push(_bar(r.cur, 4171, 4172.6, 4170.9, 4172.5));
        final next = tf.nextBucketStart(r.cur);
        r.push(_bar(next, 4172.5, 4172.5, 4172.5, 4172.5));
        final fin = r.series.firstWhere((k) => k.t == r.cur);
        expect([fin.o, fin.h, fin.l, fin.c], [live.o, live.h, live.l, live.c]);
        expect(r.last.t, next);
      });

      test('closed market: a stale quote means nothing is forming, the last stored bar stays', () async {
        final r = _Rig(tf);
        addTearDown(r.dispose);
        final old = r.nowSec - 3 * 86400; // everything is old; nothing is forming now
        r.history
          ..clear()
          ..addAll([_bar(tf.bucketStart(old - 1), 1, 2, 0, 1), _bar(tf.bucketStart(old), 1, 3, 0, 2)]);
        await r.open();
        r.tick(2.0, ts: old);
        await r.settle();
        expect([r.last.t, r.last.h], [tf.bucketStart(old), 3]);
      });
    });
  }

  test('timeframe switching: every timeframe holds its own server bar, frames never leak across', () async {
    final rigs = [for (final tf in Timeframe.values) _Rig(tf)];
    for (final r in rigs) {
      addTearDown(r.dispose);
      await r.open();
      // The gateway sends the frames of EVERY timeframe of the symbol; each series keeps its own.
      for (final other in Timeframe.values) {
        r.push(_bar(other.bucketStart(r.nowSec), 1, 1 + other.index.toDouble(), 0.5, 1), other);
      }
      r.push(_bar(r.cur, 4171, 4172, 4170, 4171.5));
      expect([r.last.t, r.last.h, r.last.l], [r.cur, 4172, 4170]);
    }
  });

  test('the forming price does not take a stale cached history\'s close as its open', () async {
    const req = ChartReq(_sym, Timeframe.h1);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final b = Timeframe.h1.bucketStart(now);
    final c = ProviderContainer(overrides: [
      candlesProvider.overrideWith((ref, r) async => [_bar(b - 6 * 3600, 4159, 4160, 4158, 4159.6)]),
    ]);
    addTearDown(c.dispose);
    await c.read(candlesProvider(req).future);
    c.listen(formingCandleProvider(req), (_, __) {});
    c.read(quotesProvider.notifier).set(Tick(symbol: _sym, bid: 4172.0, ask: 4172.2, ts: b + 5));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final f = c.read(formingCandleProvider(req))!;
    expect([f.o, f.h, f.l, f.c], [4172.0, 4172.0, 4172.0, 4172.0]);
  });
}
