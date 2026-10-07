import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chart_history_scroll_test.dart' show bars;

// The chart OPENS with the newest bar flush at the right edge (unchanged). Only a horizontal drag
// can bring it in from the edge, by a share of the visible bars - so it follows width and zoom.

Widget _host(double w, Widget chart) => MaterialApp(
      theme: AppTheme.dark(Branding.fallback),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: w, height: 600, child: chart))),
    );

Future<void> _drag(WidgetTester t, double dx, {int steps = 6}) async {
  final g = await t.startGesture(const Offset(150, 300));
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(dx / steps, 0)); // small steps, like a finger
    await t.pump(const Duration(milliseconds: 16));
  }
  await t.pump(const Duration(milliseconds: 400));
  await g.up();
  await t.pump(const Duration(seconds: 3));
}

void main() {
  for (final w in [320.0, 420.0, 600.0, 1000.0]) {
    testWidgets('width $w: opens flush at the right edge', (t) async {
      t.view
        ..physicalSize = Size(w, 700)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
      await t.pumpWidget(_host(w, CandleChart(candles: bars(1000), digits: 5, tf: Timeframe.m5, viewKey: 'o', debugViewport: vp)));
      await t.pump();
      expect(vp.value.offset, 0);
    });

    testWidgets('width $w: a drag toward the left brings the newest bar in, up to a share of the view', (t) async {
      t.view
        ..physicalSize = Size(w, 700)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
      await t.pumpWidget(_host(w, CandleChart(candles: bars(1000), digits: 5, tf: Timeframe.m5, viewKey: 'd', debugViewport: vp)));
      await t.pump();
      final plotW = vp.value.slot * 80; // 80 visible slots by default
      // A modest drag: the chart follows the finger 1:1 (newest bar moves in by that many px).
      await _drag(t, -w / 4);
      final moved = -vp.value.offset * vp.value.slot;
      expect(moved, closeTo(w / 4, 6), reason: 'the chart moved with the finger');
      // A very long drag stops at the headroom limit: around the middle, a share of the plot.
      await _drag(t, -w * 3);
      final share = -vp.value.offset * vp.value.slot / plotW;
      expect(share, closeTo(0.6, 0.02), reason: 'limit as a share of the plot at width $w');
    });
  }

  testWidgets('the position is the user\'s: it does not drift back, and a drag the other way still pans history', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    await t.pumpWidget(_host(420, CandleChart(candles: bars(1000), digits: 5, tf: Timeframe.m5, viewKey: 'p', debugViewport: vp)));
    await t.pump();
    await _drag(t, -120);
    final inFromEdge = vp.value.offset;
    expect(inFromEdge, lessThan(0));
    await t.pump(const Duration(seconds: 5));
    expect(vp.value.offset, inFromEdge);
    await _drag(t, 300); // back toward older bars
    expect(vp.value.offset, greaterThan(0));
  });

  testWidgets('a new bar does not move the view: history shifts, the newest bar keeps its place', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    Widget chart(int n) => _host(420, CandleChart(candles: bars(n), digits: 5, tf: Timeframe.m5, viewKey: 'n', debugViewport: vp));
    await t.pumpWidget(chart(1000));
    await t.pump();
    await _drag(t, -120);
    final before = vp.value.offset;
    await t.pumpWidget(chart(1001));
    await t.pump();
    expect(vp.value.offset, closeTo(before, 1e-9));
  });

  testWidgets('changing the timeframe returns to the flush default', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    Widget chart(Timeframe tf) => _host(420, CandleChart(candles: bars(1000), digits: 5, tf: tf, viewKey: 'x', debugViewport: vp));
    await t.pumpWidget(chart(Timeframe.m5));
    await t.pump();
    await _drag(t, -120);
    expect(vp.value.offset, lessThan(0));
    await t.pumpWidget(chart(Timeframe.m15));
    await t.pump();
    expect(vp.value.offset, 0);
  });
}
