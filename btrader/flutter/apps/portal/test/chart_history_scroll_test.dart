import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';

/// [n] M5 bars ending at a fixed time, with a gentle deterministic wave so every bar differs.
List<Candle> bars(int n, {int skipNewest = 0}) {
  const end = 1700000000 ~/ 300 * 300;
  return [
    for (var i = n - 1; i >= 0; i--)
      () {
        final k = end - (i + skipNewest) * 300;
        final base = 1.1 + 0.002 * ((k ~/ 300) % 37) / 37;
        return Candle(t: k, o: base, h: base + 0.0006, l: base - 0.0006, c: base + (i.isEven ? 0.0002 : -0.0002), v: 1);
      }(),
  ];
}

Widget host(Widget chart, {Key? boundary}) => MaterialApp(
      theme: AppTheme.dark(Branding.fallback),
      home: Scaffold(
        body: RepaintBoundary(key: boundary, child: SizedBox(width: 420, height: 600, child: chart)),
      ),
    );

Future<Uint8List> shot(WidgetTester t, GlobalKey key) async {
  final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  return (await t.runAsync(() async {
    final img = await b.toImage();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }))!;
}

int diffBytes(Uint8List a, Uint8List b) {
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) d++;
  }
  return d;
}

/// Drag the chart by [dx] and hold still before lifting, so the release has no velocity (no fling).
Future<void> dragAndHold(WidgetTester t, Offset dx) async {
  // In small steps like a finger (one 250 px jump would land on the price axis and start an axis zoom).
  final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
  const steps = 25;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(dx / steps.toDouble());
    await t.pump(const Duration(milliseconds: 16));
  }
  await t.pump(const Duration(milliseconds: 200));
  await g.up();
  await t.pump(const Duration(milliseconds: 500)); // the double-tap recognizer's timer
}

void main() {
  testWidgets('asks for history from the visible range (several screens ahead), with the visible count', (t) async {
    final asked = <int>[];
    await t.pumpWidget(host(CandleChart(
      candles: bars(2000),
      digits: 5,
      tf: Timeframe.m5,
      onNeedOlder: (n, u) => asked.add(n),
    )));
    await t.pump();
    expect(asked, isEmpty);

    await t.pumpWidget(host(CandleChart(
      key: const ValueKey('few'),
      candles: bars(300),
      digits: 5,
      tf: Timeframe.m5,
      onNeedOlder: (n, u) => asked.add(n),
    )));
    await t.pump();
    expect(asked, isNotEmpty);
    expect(asked.first, greaterThan(0));
  });

  testWidgets('a nearly empty buffer is flagged urgent (small fast batch first)', (t) async {
    final urgent = <bool>[];
    await t.pumpWidget(host(CandleChart(
      candles: bars(90), // ~ the visible 80 + 10: well under one screen buffered
      digits: 5,
      tf: Timeframe.m5,
      onNeedOlder: (n, u) => urgent.add(u),
    )));
    await t.pump();
    expect(urgent, isNotEmpty);
    expect(urgent.first, isTrue);
  });

  testWidgets('no loader is drawn over the chart', (t) async {
    await t.pumpWidget(host(CandleChart(
      candles: bars(300),
      digits: 5,
      tf: Timeframe.m5,
      onNeedOlder: (_, __) {},
    )));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('prepending older bars leaves what is on screen pixel-for-pixel unchanged', (t) async {
    final key = GlobalKey();
    final all = bars(4000);
    final tail = all.sublist(all.length - 1500);
    await t.pumpWidget(host(CandleChart(candles: tail, digits: 5, tf: Timeframe.m5, viewKey: 'x'), boundary: key));
    await t.pump();

    await dragAndHold(t, const Offset(250, 0));
    final before = await shot(t, key);

    await t.pumpWidget(host(CandleChart(candles: all, digits: 5, tf: Timeframe.m5, viewKey: 'x'), boundary: key));
    await t.pump();
    final after = await shot(t, key);

    expect(after.length, before.length);
    expect(diffBytes(before, after), 0, reason: 'the chart jumped or redrew differently after the prepend');
  });

  testWidgets('a live tick on the newest bar does not disturb a scrolled-back viewport', (t) async {
    final key = GlobalKey();
    final a = bars(1500);
    await t.pumpWidget(host(CandleChart(candles: a, digits: 5, tf: Timeframe.m5, viewKey: 'x'), boundary: key));
    await t.pump();
    await dragAndHold(t, const Offset(250, 0));
    final before = await shot(t, key);

    final b = [...a.sublist(0, a.length - 1), a.last.copyWith(c: a.last.c + 0.0003, h: a.last.h + 0.0003)];
    await t.pumpWidget(host(CandleChart(candles: b, digits: 5, tf: Timeframe.m5, viewKey: 'x'), boundary: key));
    await t.pump();
    final after = await shot(t, key);
    expect(diffBytes(before, after), lessThan(before.length ~/ 50));
  });

  // ───────────────────────── Phase 1: pan physics ─────────────────────────

  testWidgets('movement is pixel-continuous: a 2 px drag (less than one candle) moves the chart', (t) async {
    final key = GlobalKey();
    await t.pumpWidget(host(CandleChart(candles: bars(300), digits: 5, tf: Timeframe.m5, viewKey: 'p'), boundary: key));
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    await g.moveBy(const Offset(40, 0)); // past the gesture slop: the pan is running
    await t.pump(const Duration(milliseconds: 300)); // catch-up settled
    final a = await shot(t, key);
    await g.moveBy(const Offset(2, 0));
    await t.pump();
    final b = await shot(t, key);
    await g.moveBy(const Offset(2, 0));
    await t.pump();
    final c = await shot(t, key);
    expect(diffBytes(a, b), greaterThan(0), reason: 'a 2 px move should shift the candles (no candle-by-candle snapping)');
    expect(diffBytes(b, c), greaterThan(0));
    await t.pump(const Duration(milliseconds: 200));
    await g.up();
    await t.pump(const Duration(milliseconds: 600));
  });

  testWidgets('the chart follows the finger 1:1, including the distance the gesture slop swallowed', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    await t.pumpWidget(host(CandleChart(candles: bars(1000), digits: 5, tf: Timeframe.m5, viewKey: 'p', debugViewport: vp)));
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    const total = 130.0; // px of finger travel in total
    await g.moveBy(const Offset(total / 2, 0));
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(total / 2, 0));
    await t.pump(const Duration(milliseconds: 400)); // let the catch-up finish
    final slot = vp.value.slot;
    final movedPx = vp.value.offset * slot;
    expect(movedPx, closeTo(total, 1.5), reason: 'finger moved $total px, chart moved $movedPx px');
    await t.pump(const Duration(milliseconds: 200));
    await g.up();
    await t.pump(const Duration(milliseconds: 600));
  });

  testWidgets('a fast swipe keeps coasting after release, then stops', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    await t.pumpWidget(host(CandleChart(candles: bars(3000), digits: 5, tf: Timeframe.m5, viewKey: 'f', debugViewport: vp)));
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    var ts = Duration.zero; // the test pointer needs real timestamps for a velocity
    for (var i = 0; i < 8; i++) {
      ts += const Duration(milliseconds: 16);
      await g.moveBy(const Offset(40, 0), timeStamp: ts); // ~2500 px/s
      await t.pump(const Duration(milliseconds: 16));
    }
    final atRelease = vp.value.offset;
    await g.up(timeStamp: ts);
    await t.pump(const Duration(milliseconds: 100)); // the coast's first frame
    await t.pump(const Duration(milliseconds: 100));
    final later = vp.value.offset;
    await t.pump(const Duration(milliseconds: 100));
    final laterStill = vp.value.offset;
    expect(later, greaterThan(atRelease), reason: 'the chart must keep moving after the finger lifts');
    expect(laterStill, greaterThan(later));
    await t.pump(const Duration(seconds: 8)); // it decays and stops
    final end = vp.value.offset;
    await t.pump(const Duration(milliseconds: 300));
    expect(vp.value.offset, end, reason: 'the coast must come to rest');
    expect(end, lessThan(3000));
  });

  testWidgets('a fling does not hit a wall at the loaded history edge while older bars may still arrive', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    // 200 bars loaded, ~80 visible: hard edge at offset 120.
    await t.pumpWidget(host(CandleChart(
      candles: bars(200),
      digits: 5,
      tf: Timeframe.m5,
      viewKey: 'w',
      debugViewport: vp,
      onNeedOlder: (_, __) {},
      olderPending: () => true, // a request is in flight and has not answered yet
      olderExhausted: () => false,
    )));
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    var ts = Duration.zero;
    for (var i = 0; i < 12; i++) {
      ts += const Duration(milliseconds: 16);
      await g.moveBy(const Offset(45, 0), timeStamp: ts);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up(timeStamp: ts);
    await t.pump(const Duration(milliseconds: 1500));
    expect(vp.value.offset, greaterThan(120), reason: 'the view runs on into the blank margin instead of stopping dead at the edge');
    // Nothing arrives and nothing is pending any more: it eases back to the real edge.
    await t.pumpWidget(host(CandleChart(
      candles: bars(200),
      digits: 5,
      tf: Timeframe.m5,
      viewKey: 'w',
      debugViewport: vp,
      onNeedOlder: (_, __) {},
      olderPending: () => false,
      olderExhausted: () => true,
    )));
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(seconds: 3));
    expect(vp.value.offset, lessThanOrEqualTo(120.01));
  });

  testWidgets('with the start of history reached there is no margin: the edge is firm', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    await t.pumpWidget(host(CandleChart(
      candles: bars(200),
      digits: 5,
      tf: Timeframe.m5,
      viewKey: 'e',
      debugViewport: vp,
      onNeedOlder: (_, __) {},
      olderPending: () => false,
      olderExhausted: () => true,
    )));
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byType(CandleChart)));
    var ts = Duration.zero;
    for (var i = 0; i < 12; i++) {
      ts += const Duration(milliseconds: 16);
      await g.moveBy(const Offset(45, 0), timeStamp: ts);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up(timeStamp: ts);
    await t.pump(const Duration(seconds: 6));
    expect(vp.value.offset, lessThanOrEqualTo(120.01));
  });

  testWidgets('a new bar forming does not drag a scrolled-back view along; at the live edge it follows', (t) async {
    final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
    final a = bars(1500);
    await t.pumpWidget(host(CandleChart(candles: a, digits: 5, tf: Timeframe.m5, viewKey: 'n', debugViewport: vp)));
    await t.pump();

    // At the live edge: stays at the edge.
    final more = [...a, Candle(t: a.last.t + 300, o: 1.1, h: 1.1, l: 1.1, c: 1.1, v: 1)];
    await t.pumpWidget(host(CandleChart(candles: more, digits: 5, tf: Timeframe.m5, viewKey: 'n', debugViewport: vp)));
    await t.pump();
    expect(vp.value.offset, lessThanOrEqualTo(0));

    // Scrolled back 250 px: a further new bar moves the offset by one so the same bars stay on screen.
    await dragAndHold(t, const Offset(250, 0));
    final before = vp.value.offset;
    expect(before, greaterThan(0));
    final more2 = [...more, Candle(t: more.last.t + 300, o: 1.1, h: 1.1, l: 1.1, c: 1.1, v: 1)];
    await t.pumpWidget(host(CandleChart(candles: more2, digits: 5, tf: Timeframe.m5, viewKey: 'n', debugViewport: vp)));
    await t.pump();
    expect(vp.value.offset, closeTo(before + 1, 1e-9));
  });

  testWidgets('a tap on the chart still reaches the tap handler (smaller slop does not eat taps)', (t) async {
    var taps = 0;
    await t.pumpWidget(host(CandleChart(
      candles: bars(300),
      digits: 5,
      tf: Timeframe.m5,
      viewKey: 't',
      activeTool: DrawingType.horizontalLine,
      onAnchor: (_) => taps++,
    )));
    await t.pump();
    await t.tapAt(t.getCenter(find.byType(CandleChart)) + const Offset(-20, -30));
    await t.pump(const Duration(milliseconds: 400));
    expect(taps, 1);
  });
}
