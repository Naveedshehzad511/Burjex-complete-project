// Rendering benchmark for the chart's pan path. NOT part of the normal suite (timings are machine
// dependent): run it explicitly with
//
//   CHART_BENCH=1 flutter test test/perf/chart_perf_bench_test.dart
//
// What it measures is the UI-thread work of a frame (build + layout + paint recording) - the part
// Dart controls and that a phone runs several times slower than this machine. GPU raster is not
// covered. Compare numbers between runs on the SAME machine, and read them against the 16.7 ms
// (60 fps) / 8.3 ms (120 fps) budget with a safety factor for the phone.
import 'dart:io';
import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';

List<Candle> bars(int n) {
  const end = 1700000000 ~/ 300 * 300;
  final rnd = math.Random(7);
  var p = 1.1;
  return [
    for (var i = n - 1; i >= 0; i--)
      () {
        final o = p;
        p += (rnd.nextDouble() - 0.5) * 0.0008;
        final h = math.max(o, p) + rnd.nextDouble() * 0.0003;
        final l = math.min(o, p) - rnd.nextDouble() * 0.0003;
        return Candle(t: end - i * 300, o: o, h: h, l: l, c: p, v: 1 + rnd.nextDouble() * 100);
      }(),
  ];
}

class Stat {
  Stat(List<double> ms) {
    final s = [...ms]..sort();
    mean = s.reduce((a, b) => a + b) / s.length;
    p50 = s[s.length ~/ 2];
    p95 = s[(s.length * 0.95).floor().clamp(0, s.length - 1)];
    max = s.last;
  }
  late final double mean, p50, p95, max;
  @override
  String toString() => 'mean ${mean.toStringAsFixed(2)}  p50 ${p50.toStringAsFixed(2)}  p95 ${p95.toStringAsFixed(2)}  max ${max.toStringAsFixed(2)} ms';
}

Widget host(Widget chart) => MaterialApp(
      key: UniqueKey(), // a fresh route + page storage per scenario (the chart remembers its zoom there)
      theme: AppTheme.dark(Branding.fallback),
      home: Scaffold(body: SizedBox(width: 420, height: 700, child: chart)),
    );

List<ComputedIndicator> indicators(List<Candle> c, {required bool overlays}) {
  final types = overlays
      ? [IndicatorType.sma, IndicatorType.bollinger]
      : [IndicatorType.rsi, IndicatorType.macd];
  return [
    for (final t in types) computeIndicator(IndicatorConfig.defaults(t, t.name), c).withLabel(t.name),
  ];
}

void main() {
  final on = Platform.environment.containsKey('CHART_BENCH');

  Future<(Stat, int)> panFrames(WidgetTester t, {required int total, required double zoomOutTo, required bool withIndicators}) async {
    final candles = bars(total);
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    await t.pumpWidget(host(CandleChart(
      debugViewport: vp,
      candles: candles,
      digits: 5,
      tf: Timeframe.m5,
      viewKey: 'bench$total',
      overlays: withIndicators ? indicators(candles, overlays: true) : const [],
      oscillators: withIndicators ? indicators(candles, overlays: false) : const [],
    )));
    await t.pump();

    // Zoom out with the time axis (drag left) until about [zoomOutTo] bars are visible.
    if (zoomOutTo > 80) {
      final g = await t.startGesture(const Offset(210, 700 - 6));
      // each -30 px step multiplies the visible count by 1.18
      final steps = (math.log(zoomOutTo / 80) / math.log(1.18)).ceil();
      for (var i = 0; i < steps; i++) {
        await g.moveBy(const Offset(-30, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump(const Duration(milliseconds: 600));
    }

    // Pan back and forth in 3 px steps, one frame each (what a slow finger drag does).
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    await g.moveBy(const Offset(40, 0));
    await t.pump(const Duration(milliseconds: 16));
    final times = <double>[];
    final sw = Stopwatch();
    var dir = 1.0;
    for (var i = 0; i < 160; i++) {
      if (i % 40 == 0) dir = -dir;
      sw
        ..reset()
        ..start();
      await g.moveBy(Offset(3 * dir, 0));
      await t.pump(const Duration(milliseconds: 16));
      sw.stop();
      if (i >= 20) times.add(sw.elapsedMicroseconds / 1000);
    }
    await t.pump(const Duration(milliseconds: 200));
    await g.up();
    await t.pump(const Duration(seconds: 4));
    return (Stat(times), ((420 - 55) / vp.value.slot).round()); // ~chart width / slot
  }

  testWidgets('pan frame cost', (t) async {
    t.view
      ..physicalSize = const Size(420, 700)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final out = StringBuffer('\n── pan frame (build+layout+paint record), ms per frame ──\n');
    for (final total in [1500, 5000, 20000]) {
      for (final ind in [false, true]) {
        final (s, vis) = await panFrames(t, total: total, zoomOutTo: 80, withIndicators: ind);
        out.writeln('${total.toString().padLeft(6)} bars  ${vis.toString().padLeft(5)} visible  indicators:${ind ? 'on ' : 'off'}  $s');
      }
    }
    // zoomed out: many bars on screen
    for (final total in [5000, 20000]) {
      for (final ind in [false, true]) {
        final (s, vis) = await panFrames(t, total: total, zoomOutTo: 1000, withIndicators: ind);
        out.writeln('${total.toString().padLeft(6)} bars  ${vis.toString().padLeft(5)} visible  indicators:${ind ? 'on ' : 'off'}  $s');
      }
    }
    // ignore: avoid_print
    print(out);
  }, skip: !on, timeout: const Timeout(Duration(minutes: 10)));

  test('per-tick candle overlay and history-arrival costs', () {
    final out = StringBuffer('\n── per live tick: overlayCandles(history, tail) ──\n');
    for (final n in [5000, 20000, 100000]) {
      final h = bars(n);
      final over = {h.last.t: h.last.copyWith(c: h.last.c + 0.0001), h.last.t + 300: h.last};
      final sw = Stopwatch()..start();
      const iters = 100;
      for (var i = 0; i < iters; i++) {
        overlayCandles(h, over);
      }
      sw.stop();
      out.writeln('${n.toString().padLeft(6)} bars: ${(sw.elapsedMicroseconds / 1000 / iters).toStringAsFixed(3)} ms per tick');
    }
    out.writeln('\n── history arrives: indicators recomputed over the whole series, ms ──');
    for (final n in [5000, 20000, 100000]) {
      final h = bars(n);
      final sw = Stopwatch()..start();
      indicators(h, overlays: true);
      indicators(h, overlays: false);
      sw.stop();
      out.writeln('${n.toString().padLeft(6)} bars, SMA+Bollinger+RSI+MACD: ${(sw.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms');
    }
    // ignore: avoid_print
    print(out);
  }, skip: !on);
}
