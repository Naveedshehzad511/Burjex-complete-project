// How the chart behaves with many open trades (entry / SL / TP lines). Run explicitly:
//
//   CHART_BENCH=1 flutter test test/perf/chart_levels_bench_test.dart
//
// Prints (1) the UI-thread cost of a pan frame as the number of trade lines grows and (2) how much
// of the pane the candles use, i.e. whether the price scale is being stretched by the trade lines.
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
        return Candle(t: end - i * 300, o: o, h: h, l: l, c: p, v: 1);
      }(),
  ];
}

/// [trades] open positions spread over [spread] of price around 1.10: entry + SL + TP each.
List<ChartLevel> levels(int trades, double spread) {
  final rnd = math.Random(3);
  return [
    for (var i = 0; i < trades; i++) ...() {
      final entry = 1.1 + (rnd.nextDouble() - 0.5) * spread;
      final buy = i.isEven;
      return [
        ChartLevel(entry, buy ? Colors.blue : Colors.red, '${buy ? 'BUY' : 'SELL'} 0.10, +${(rnd.nextDouble() * 20).toStringAsFixed(2)} USD',
            id: 'p$i', kind: LevelKind.entry, tappable: true, plColor: Colors.blue),
        ChartLevel(entry + (buy ? -0.004 : 0.004), Colors.red, 'SL, -${(rnd.nextDouble() * 30).toStringAsFixed(2)} USD', id: 'p$i', kind: LevelKind.sl, tappable: true),
        ChartLevel(entry + (buy ? 0.006 : -0.006), Colors.green, 'TP, +${(rnd.nextDouble() * 50).toStringAsFixed(2)} USD', id: 'p$i', kind: LevelKind.tp, tappable: true),
      ];
    }(),
  ];
}

Widget host(Widget chart) => MaterialApp(
      key: UniqueKey(),
      theme: AppTheme.dark(Branding.fallback),
      home: Scaffold(body: SizedBox(width: 420, height: 700, child: chart)),
    );

void main() {
  final on = Platform.environment.containsKey('CHART_BENCH');

  testWidgets('pan frame cost vs number of trades', (t) async {
    t.view
      ..physicalSize = const Size(420, 700)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final out = StringBuffer('\n── pan frame ms, by number of open trades (3 lines each) ──\n');
    for (final (trades, spread) in [(0, 0.004), (3, 0.004), (10, 0.004), (30, 0.004), (30, 0.0004)]) {
      final candles = bars(3000);
      await t.pumpWidget(host(CandleChart(candles: candles, digits: 5, tf: Timeframe.m5, viewKey: 'k$trades$spread', levels: levels(trades, spread))));
      await t.pump();
      final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
      await g.moveBy(const Offset(40, 0));
      await t.pump(const Duration(milliseconds: 16));
      final times = <double>[];
      final sw = Stopwatch();
      var dir = 1.0;
      for (var i = 0; i < 140; i++) {
        if (i % 35 == 0) dir = -dir;
        sw
          ..reset()
          ..start();
        await g.moveBy(Offset(3 * dir, 0));
        await t.pump(const Duration(milliseconds: 16));
        sw.stop();
        if (i >= 20) times.add(sw.elapsedMicroseconds / 1000);
      }
      await g.up();
      await t.pump(const Duration(seconds: 3));
      times.sort();
      out.writeln('${trades.toString().padLeft(3)} trades (${trades * 3} lines, spread $spread): mean ${(times.reduce((a, b) => a + b) / times.length).toStringAsFixed(2)}  p95 ${times[(times.length * .95).floor()].toStringAsFixed(2)}  max ${times.last.toStringAsFixed(2)} ms');
    }
    // ignore: avoid_print
    print(out);
  }, skip: !on, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('how much of the price pane the candles use', (t) async {
    t.view
      ..physicalSize = const Size(420, 700)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final out = StringBuffer('\n── share of the price range taken by the visible candles (100% = fills the pane) ──\n');
    final candles = bars(3000);
    final visible = candles.sublist(candles.length - 85);
    var cHi = visible.first.h, cLo = visible.first.l;
    for (final k in visible) {
      cHi = math.max(cHi, k.h);
      cLo = math.min(cLo, k.l);
    }
    for (final spread in [0.0, 0.004, 0.02, 0.1]) {
      final lv = levels(spread == 0 ? 0 : 10, spread);
      final r = chartRange(visible, lv);
      out.writeln('trades spread ${spread.toStringAsFixed(3)} of price: candles use ${(((cHi - cLo) / (r.hi - r.lo)) * 100).toStringAsFixed(0)}% of the pane');
    }
    // ignore: avoid_print
    print(out);
  }, skip: !on);
}
