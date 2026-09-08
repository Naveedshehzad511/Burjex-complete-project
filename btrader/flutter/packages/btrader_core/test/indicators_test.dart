import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

Candle _k(double o, double h, double l, double c) => Candle(t: 0, o: o, h: h, l: l, c: c, v: 0);

/// Build candles from a close series (o=h=l=c) for source-agnostic MA/RSI tests.
List<Candle> _closes(List<double> cs) => [for (final c in cs) _k(c, c, c, c)];

void main() {
  group('SMA', () {
    test('nulls during warm-up, then trailing average', () {
      final out = sma([1, 2, 3, 4, 5], 3);
      expect(out[0], isNull);
      expect(out[1], isNull);
      expect(out[2], closeTo(2, 1e-9)); // (1+2+3)/3
      expect(out[3], closeTo(3, 1e-9));
      expect(out[4], closeTo(4, 1e-9));
    });
  });

  group('EMA', () {
    test('seeds on SMA then smooths', () {
      final out = ema([1, 2, 3, 4, 5], 3);
      expect(out[0], isNull);
      expect(out[1], isNull);
      expect(out[2], closeTo(2, 1e-9)); // SMA seed of first 3
      // k = 0.5; next = (4-2)*0.5 + 2 = 3
      expect(out[3], closeTo(3, 1e-9));
      // (5-3)*0.5 + 3 = 4
      expect(out[4], closeTo(4, 1e-9));
    });
  });

  group('WMA', () {
    test('linear weights, newest heaviest', () {
      // period 3 over [1,2,3]: (1*1 + 2*2 + 3*3)/(1+2+3) = 14/6
      final out = wma([1, 2, 3], 3);
      expect(out[2], closeTo(14 / 6, 1e-9));
    });
  });

  group('Bollinger', () {
    test('basis equals SMA, bands are symmetric', () {
      final bb = bollinger([2, 4, 6], 3, 2);
      expect(bb.middle[2], closeTo(4, 1e-9));
      // population std of [2,4,6] = sqrt((4+0+4)/3) = 1.632993...
      final sd = bb.upper[2]! - bb.middle[2]!;
      expect(sd, closeTo(2 * 1.6329931619, 1e-6));
      expect(bb.middle[2]! - bb.lower[2]!, closeTo(sd, 1e-9));
    });
  });

  group('RSI', () {
    test('all-up series → 100', () {
      final out = rsi([1, 2, 3, 4, 5, 6], 3);
      expect(out[3], closeTo(100, 1e-9));
    });

    test('classic Wilder example first value', () {
      // Well-known 14-period RSI textbook series → ~70.53 on the first value.
      final closes = [
        44.34, 44.09, 44.15, 43.61, 44.33, 44.83, 45.10, 45.42,
        45.84, 46.08, 45.89, 46.03, 45.61, 46.28, 46.28,
      ];
      final out = rsi(closes, 14);
      expect(out[14], closeTo(70.53, 0.1));
    });
  });

  group('ATR', () {
    test('constant-range candles → that range', () {
      // Each bar spans 2.0 and closes flush, so TR is 2.0 throughout → ATR 2.0.
      final candles = [for (var i = 0; i < 10; i++) _k(10, 11, 9, 10)];
      final out = atr(candles, 3);
      expect(out[3], closeTo(2, 1e-9));
      expect(out.last, closeTo(2, 1e-9));
    });
  });

  group('MACD', () {
    test('line/signal/hist align and hist = macd - signal', () {
      final src = List<double>.generate(60, (i) => 100 + i.toDouble());
      final m = macd(src, 12, 26, 9);
      expect(m.macd.length, 60);
      // Find an index where all three are present and check the identity.
      for (var i = 0; i < 60; i++) {
        if (m.macd[i] != null && m.signal[i] != null && m.hist[i] != null) {
          expect(m.hist[i], closeTo(m.macd[i]! - m.signal[i]!, 1e-9));
        }
      }
    });
  });

  group('Stochastic', () {
    test('%K = 100 at the top of the range', () {
      // Rising closes that each print the period high → %K pinned near 100.
      final candles = _closes([1, 2, 3, 4, 5, 6, 7, 8]);
      final s = stochastic(candles, 3, 1, 1);
      expect(s.k.last, closeTo(100, 1e-9));
    });
  });

  group('priceSeries', () {
    test('hlc3 averages high/low/close', () {
      final s = priceSeries([_k(1, 4, 2, 3)], IndicatorSource.hlc3);
      expect(s.first, closeTo((4 + 2 + 3) / 3, 1e-9));
    });
  });

  group('CCI', () {
    test('null during warm-up then finite', () {
      final candles = _closes(List<double>.generate(30, (i) => 100 + (i % 5).toDouble()));
      final out = cci(candles, 20);
      expect(out[18], isNull);
      expect(out[19], isNotNull);
      expect(out.last!.isFinite, isTrue);
    });
  });

  group('ADX', () {
    test('DI/ADX in 0..100 and appear after warm-up', () {
      final candles = [for (var i = 0; i < 60; i++) _k(100 + i.toDouble(), 101 + i.toDouble(), 99 + i.toDouble(), 100.5 + i.toDouble())];
      final a = adx(candles, 14);
      expect(a.adx[27], isNull); // < 2*period
      final v = a.adx[a.adx.length - 1];
      expect(v, isNotNull);
      expect(v! >= 0 && v <= 100, isTrue);
      // Steady uptrend → +DI should dominate −DI.
      expect(a.plusDi.last! > a.minusDi.last!, isTrue);
    });
  });

  group('Parabolic SAR', () {
    test('sits below price in an uptrend', () {
      final candles = [for (var i = 0; i < 30; i++) _k(100 + i.toDouble(), 101 + i.toDouble(), 99.5 + i.toDouble(), 100.8 + i.toDouble())];
      final out = parabolicSar(candles, 0.02, 0.2);
      // After a few bars of clean uptrend, SAR trails beneath the low.
      expect(out.last! < candles.last.l, isTrue);
    });
  });

  group('Ichimoku', () {
    test('components warm up and Tenkan/Kijun are midpoints; Chikou = close', () {
      final candles = [for (var i = 0; i < 60; i++) _k(100 + i.toDouble(), 101 + i.toDouble(), 99 + i.toDouble(), 100.5 + i.toDouble())];
      final ich = ichimoku(candles, 9, 26, 52);
      expect(ich.tenkan[7], isNull); // < 9
      expect(ich.tenkan[8], isNotNull);
      expect(ich.senkouB[50], isNull); // < 52
      expect(ich.senkouB[51], isNotNull);
      // Tenkan = (max high + min low)/2 over last 9 bars.
      final tk = ich.tenkan[10]!;
      double hi = candles[2].h, lo = candles[2].l;
      for (var j = 2; j <= 10; j++) {
        if (candles[j].h > hi) hi = candles[j].h;
        if (candles[j].l < lo) lo = candles[j].l;
      }
      expect(tk, closeTo((hi + lo) / 2, 1e-9));
      expect(ich.chikou.last, candles.last.c);
    });

    test('computeIndicator emits 5 lines with cloud + displacement shifts', () {
      final candles = [for (var i = 0; i < 60; i++) _k(100 + i.toDouble(), 101 + i.toDouble(), 99 + i.toDouble(), 100.5 + i.toDouble())];
      final ind = computeIndicator(IndicatorConfig.defaults(IndicatorType.ichimoku, 'i'), candles);
      expect(ind.isOverlay, isTrue);
      expect(ind.lines.length, 5);
      expect(ind.ichimokuCloud, isTrue);
      expect(ind.futureShift, 26);
      expect(ind.lines[2].shift, 26); // Senkou A forward
      expect(ind.lines[4].shift, -26); // Chikou back
    });
  });

  group('computeIndicator', () {
    test('overlay flag and line count per type', () {
      final candles = _closes(List<double>.generate(40, (i) => 100 + i.toDouble()));
      final ema = computeIndicator(IndicatorConfig.defaults(IndicatorType.ema, 'a'), candles);
      expect(ema.isOverlay, isTrue);
      expect(ema.lines.length, 1);

      final bb = computeIndicator(IndicatorConfig.defaults(IndicatorType.bollinger, 'b'), candles);
      expect(bb.lines.length, 3);

      final macdI = computeIndicator(IndicatorConfig.defaults(IndicatorType.macd, 'c'), candles);
      expect(macdI.isOverlay, isFalse);
      expect(macdI.histogram, isNotNull);
      expect(macdI.zeroLine, isTrue);

      final rsiI = computeIndicator(IndicatorConfig.defaults(IndicatorType.rsi, 'd'), candles);
      expect(rsiI.fixedRange, isNotNull);
      expect(rsiI.guides, [30, 70]);
    });
  });

  group('Timeframe calendar bucketing', () {
    int secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

    test('W1 bucket lands on Monday 00:00 UTC, at or before t', () {
      final t = secs(DateTime.utc(2026, 7, 16, 13, 30)); // a Thursday
      final b = Timeframe.w1.bucketStart(t);
      final d = DateTime.fromMillisecondsSinceEpoch(b * 1000, isUtc: true);
      expect(d.weekday, DateTime.monday);
      expect(d.hour, 0);
      expect(d.minute, 0);
      expect(b <= t, isTrue);
      expect(t - b < 604800, isTrue);
    });

    test('MN1 bucket is the 1st of the month 00:00 UTC', () {
      final t = secs(DateTime.utc(2026, 7, 16, 13, 30));
      final d = DateTime.fromMillisecondsSinceEpoch(Timeframe.mn1.bucketStart(t) * 1000, isUtc: true);
      expect(d.year, 2026);
      expect(d.month, 7);
      expect(d.day, 1);
      expect(d.hour, 0);
    });

    test('MN1 nextBucketStart rolls Dec→Jan', () {
      final t = secs(DateTime.utc(2026, 12, 20));
      final d = DateTime.fromMillisecondsSinceEpoch(Timeframe.mn1.nextBucketStart(t) * 1000, isUtc: true);
      expect(d.year, 2027);
      expect(d.month, 1);
      expect(d.day, 1);
    });

    test('intraday bucket still aligns to the fixed grid', () {
      final t = secs(DateTime.utc(2026, 7, 16, 13, 37, 42));
      expect(Timeframe.m5.bucketStart(t) % 300, 0);
      expect(t - Timeframe.m5.bucketStart(t) < 300, isTrue);
    });
  });

  group('DrawingObject JSON', () {
    test('round-trips anchors, type and color', () {
      final d = DrawingObject(
        id: 'd1',
        symbol: 'EURUSD',
        type: DrawingType.fibRetracement,
        anchors: const [DrawingAnchor(1000, 1.1), DrawingAnchor(2000, 1.2)],
        colorArgb: 0xFF26A69A,
      );
      final back = DrawingObject.fromJson(d.toJson());
      expect(back.id, 'd1');
      expect(back.symbol, 'EURUSD');
      expect(back.type, DrawingType.fibRetracement);
      expect(back.anchors.length, 2);
      expect(back.anchors.last.price, 1.2);
      expect(back.colorArgb, 0xFF26A69A);
    });

    test('anchor counts per type', () {
      expect(DrawingType.horizontalLine.anchorCount, 1);
      expect(DrawingType.trendline.anchorCount, 2);
      expect(DrawingType.fibRetracement.anchorCount, 2);
    });
  });

  group('IndicatorConfig JSON', () {
    test('round-trips', () {
      final cfg = IndicatorConfig.defaults(IndicatorType.bollinger, 'x')
          .copyWith(source: IndicatorSource.hlc3, colors: [1, 2, 3]);
      final back = IndicatorConfig.fromJson(cfg.toJson());
      expect(back.id, 'x');
      expect(back.type, IndicatorType.bollinger);
      expect(back.source, IndicatorSource.hlc3);
      expect(back.colors, [1, 2, 3]);
      expect(back.paramInt('period'), cfg.paramInt('period'));
    });
  });
}
