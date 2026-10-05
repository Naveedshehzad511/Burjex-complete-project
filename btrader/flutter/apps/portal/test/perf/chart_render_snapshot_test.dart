// Visual safety net for performance work: renders the chart in a spread of states and either
// writes the pixels to a directory or compares them with a previous run - byte for byte.
//
//   CHART_SNAP=write   CHART_SNAP_DIR=<dir> flutter test test/perf/chart_render_snapshot_test.dart
//   CHART_SNAP=compare CHART_SNAP_DIR=<dir> flutter test test/perf/chart_render_snapshot_test.dart
//
// Run "write" on the code BEFORE an optimisation and "compare" after it: any difference fails.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';

List<Candle> bars(int n) {
  const end = 1700000000 ~/ 300 * 300;
  final rnd = math.Random(11);
  var p = 1.1;
  return [
    for (var i = n - 1; i >= 0; i--)
      () {
        final o = p;
        p += (rnd.nextDouble() - 0.5) * 0.0008;
        return Candle(
            t: end - i * 300,
            o: o,
            h: math.max(o, p) + rnd.nextDouble() * 0.0003,
            l: math.min(o, p) - rnd.nextDouble() * 0.0003,
            c: p,
            v: 1 + rnd.nextDouble() * 100);
      }(),
  ];
}

void main() {
  final mode = Platform.environment['CHART_SNAP'];
  final dir = Platform.environment['CHART_SNAP_DIR'];
  final on = mode != null && dir != null;

  Future<Uint8List> shot(WidgetTester t, GlobalKey key) async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    return (await t.runAsync(() async {
      final img = await b.toImage();
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!.buffer.asUint8List();
    }))!;
  }

  Future<void> check(WidgetTester t, String name, GlobalKey key) async {
    final px = await shot(t, key);
    final f = File('$dir/$name.rgba');
    if (mode == 'write') {
      await t.runAsync(() async {
        await Directory(dir!).create(recursive: true);
        await f.writeAsBytes(px);
      });
    } else {
      final old = await t.runAsync(() => f.readAsBytes());
      expect(old!.length, px.length, reason: name);
      var diff = 0;
      for (var i = 0; i < px.length; i++) {
        if (old[i] != px[i]) diff++;
      }
      expect(diff, 0, reason: '$name differs from the baseline in $diff bytes');
    }
  }

  Widget host(GlobalKey key, Widget chart) => MaterialApp(
        key: UniqueKey(),
        theme: AppTheme.dark(Branding.fallback),
        home: Scaffold(body: RepaintBoundary(key: key, child: SizedBox(width: 420, height: 700, child: chart))),
      );

  List<ComputedIndicator> ind(List<Candle> c, List<IndicatorType> types) =>
      [for (final t in types) computeIndicator(IndicatorConfig.defaults(t, t.name), c).withLabel(t.name)];

  Future<void> drag(WidgetTester t, Offset by, {int steps = 20}) async {
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    for (var i = 0; i < steps; i++) {
      await g.moveBy(by / steps.toDouble());
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(milliseconds: 250)); // hold: no fling
    await g.up();
    await t.pump(const Duration(milliseconds: 600));
  }

  testWidgets('chart pixels are unchanged', (t) async {
    t.view
      ..physicalSize = const Size(420, 700)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    final c = bars(3000);

    // 1. default
    await t.pumpWidget(host(key, CandleChart(candles: c, digits: 5, tf: Timeframe.m5, viewKey: 's1', livePrice: c.last.c, askPrice: c.last.c + 0.0002)));
    await t.pump();
    await check(t, 'default', key);

    // 2. scrolled back, odd (sub-bar) distance
    await drag(t, const Offset(237, 0));
    await check(t, 'scrolled', key);

    // 3. zoomed out with the time axis
    await t.pumpWidget(host(key, CandleChart(candles: c, digits: 5, tf: Timeframe.m5, viewKey: 's3')));
    await t.pump();
    final g = await t.startGesture(const Offset(210, 694));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(-30, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 600));
    await check(t, 'zoomed_out', key);

    // 4. indicators: overlays + oscillators
    await t.pumpWidget(host(
        key,
        CandleChart(
          candles: c,
          digits: 5,
          tf: Timeframe.m5,
          viewKey: 's4',
          overlays: ind(c, [IndicatorType.sma, IndicatorType.bollinger]),
          oscillators: ind(c, [IndicatorType.rsi, IndicatorType.macd]),
        )));
    await t.pump();
    await drag(t, const Offset(120, 0));
    await check(t, 'indicators', key);

    // 5. crosshair
    await t.pumpWidget(host(key, CandleChart(candles: c, digits: 5, tf: Timeframe.m5, viewKey: 's5', crosshairMode: true)));
    await t.pump();
    await t.tapAt(const Offset(150, 250));
    await t.pump(const Duration(milliseconds: 400));
    await check(t, 'crosshair', key);

    // 6. order levels + drawings
    final t0 = c[c.length - 60].t, t1 = c[c.length - 10].t;
    await t.pumpWidget(host(
        key,
        CandleChart(
          candles: c,
          digits: 5,
          tf: Timeframe.m5,
          viewKey: 's6',
          livePrice: c.last.c,
          askPrice: c.last.c + 0.0002,
          levels: [
            ChartLevel(c.last.c + 0.0010, Colors.redAccent, 'SL', id: 'sl', kind: LevelKind.sl, draggable: true),
            ChartLevel(c.last.c - 0.0012, Colors.lightBlueAccent, 'TP', id: 'tp', kind: LevelKind.tp, draggable: true),
            ChartLevel(c.last.c, Colors.white70, 'BUY 0.10, +1.20 USD', id: 'p', kind: LevelKind.entry),
          ],
          drawings: [
            DrawingObject(id: 'd1', symbol: 'X', type: DrawingType.trendline, anchors: [DrawingAnchor(t0, c.last.c - 0.001), DrawingAnchor(t1, c.last.c + 0.0008)], colorArgb: 0xFFFFB74D),
            DrawingObject(id: 'd2', symbol: 'X', type: DrawingType.horizontalLine, anchors: [DrawingAnchor(t0, c.last.c + 0.0003)], colorArgb: 0xFF42A5F5),
            DrawingObject(id: 'd3', symbol: 'X', type: DrawingType.fibRetracement, anchors: [DrawingAnchor(t0, c.last.c - 0.0015), DrawingAnchor(t1, c.last.c + 0.0015)], colorArgb: 0xFFAB47BC),
          ],
        )));
    await t.pump();
    await check(t, 'levels_drawings', key);

    // 7. line chart + a small, odd-sized series
    await t.pumpWidget(host(key, CandleChart(candles: bars(37), digits: 5, tf: Timeframe.m5, viewKey: 's7', type: ChartType.line)));
    await t.pump();
    await check(t, 'line_small', key);
  }, skip: !on);
}
