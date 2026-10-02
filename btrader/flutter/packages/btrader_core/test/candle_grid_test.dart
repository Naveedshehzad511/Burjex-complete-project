import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// H4 / D1 bars begin on the BROKER's grid, the same one the server's history rollup, the MT5 bridge
/// and the live candle engine use. A forming bar on any other grid overlaps the bar beside it.
int _utc(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) => DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch ~/ 1000;

void main() {
  const off = 10800; // broker UTC+3 (BROKER_UTC_OFFSET_SEC=10800)

  group('Timeframe.bucketStart', () {
    test('offset 0 is the plain UTC grid (unchanged behaviour)', () {
      final t = _utc(2026, 10, 2, 10, 30);
      expect(Timeframe.h4.bucketStart(t), _utc(2026, 10, 2, 8));
      expect(Timeframe.d1.bucketStart(t), _utc(2026, 10, 2));
    });

    test('H4 / D1 follow the broker clock', () {
      final t = _utc(2026, 10, 2, 10, 30);
      expect(Timeframe.d1.bucketStart(t, brokerOffsetSec: off), _utc(2026, 10, 1, 21));
      expect(Timeframe.h4.bucketStart(t, brokerOffsetSec: off), _utc(2026, 10, 2, 9));
      expect(Timeframe.h4.bucketStart(_utc(2026, 10, 2, 8, 59, 59), brokerOffsetSec: off), _utc(2026, 10, 2, 5));
    });

    test('intraday, weekly and monthly bars ignore the offset', () {
      final t = _utc(2026, 10, 2, 10, 37, 21);
      for (final tf in [Timeframe.m1, Timeframe.m5, Timeframe.m15, Timeframe.m30, Timeframe.h1, Timeframe.w1, Timeframe.mn1]) {
        expect(tf.bucketStart(t, brokerOffsetSec: off), tf.bucketStart(t), reason: tf.name);
      }
    });

    test('matches the server formula (gateway tfBucketStart / bridge aggregate) at every moment', () {
      int server(int t, int sec) => ((t + off) ~/ sec) * sec - off;
      for (var t = _utc(2026, 10, 1); t < _utc(2026, 10, 4); t += 977) {
        expect(Timeframe.h4.bucketStart(t, brokerOffsetSec: off), server(t, 14400));
        expect(Timeframe.d1.bucketStart(t, brokerOffsetSec: off), server(t, 86400));
      }
    });

    test('the bar after the current one starts exactly where the next bucket begins', () {
      final t = _utc(2026, 10, 2, 10, 30);
      for (final tf in [Timeframe.h4, Timeframe.d1]) {
        final next = tf.nextBucketStart(t, brokerOffsetSec: off);
        expect(next, tf.bucketStart(t, brokerOffsetSec: off) + tf.seconds);
        expect(tf.bucketStart(next, brokerOffsetSec: off), next);
        expect(tf.bucketStart(next - 1, brokerOffsetSec: off), isNot(next));
      }
    });
  });

  group('forming candle uses the broker grid', () {
    ProviderContainer make(int offset) {
      final c = ProviderContainer(overrides: [
        candlesProvider.overrideWith((ref, r) async => <Candle>[]),
        brokerOffsetSecProvider.overrideWith((ref) async => offset),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    for (final (tf, expected) in [(Timeframe.d1, _utc(2026, 10, 1, 21)), (Timeframe.h4, _utc(2026, 10, 2, 9))]) {
      test('${tf.name}: the forming bar opens on the broker boundary and keeps its high / low', () async {
        final c = make(off);
        await c.read(brokerOffsetSecProvider.future);
        final req = ChartReq('XAUUSD', tf);
        c.listen(formingCandleProvider(req), (_, __) {});
        final ts = _utc(2026, 10, 2, 10, 30);
        void tick(double bid) => c.read(quotesProvider.notifier).set(Tick(symbol: 'XAUUSD', bid: bid, ask: bid + 0.2, ts: ts));
        tick(2440.00);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        tick(2440.50);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        tick(2440.20);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final f = c.read(formingCandleProvider(req))!;
        expect(f.bucket, expected);
        expect([f.o, f.h, f.l, f.c], [2440.00, 2440.50, 2440.00, 2440.20]);
      });
    }
  });
}
