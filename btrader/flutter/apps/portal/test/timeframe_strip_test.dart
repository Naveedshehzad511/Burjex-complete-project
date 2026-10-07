import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester t, double width, double textScale, {Timeframe selected = Timeframe.m5}) async {
  t.view.physicalSize = Size(width, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: TimeframeStrip(selected: selected, onPick: (_) {}, onSettings: () {})),
    ),
  ));
}

Rect _label(WidgetTester t, Timeframe tf) =>
    t.getRect(find.descendant(of: find.byKey(ValueKey('tf-${tf.name}')), matching: find.text(tf.mt5Label)));

void main() {
  for (final width in [280.0, 320.0, 360.0, 393.0, 411.0, 600.0]) {
    for (final scale in [0.85, 1.0, 1.3, 1.6, 2.0]) {
      testWidgets('w=$width text x$scale: all nine show in full, with equal gaps', (t) async {
        await _pump(t, width, scale);
        expect(t.takeException(), isNull); // no overflow
        final rects = [for (final tf in Timeframe.values) _label(t, tf)];
        // Every label is on screen, left of the settings gear, in order.
        final gear = t.getRect(find.byIcon(Icons.settings_outlined));
        for (var i = 0; i < rects.length; i++) {
          expect(rects[i].left, greaterThanOrEqualTo(-0.01), reason: 'label $i clipped on the left');
          expect(rects[i].right, lessThanOrEqualTo(gear.left + 0.5), reason: 'label $i runs into the gear');
          if (i > 0) expect(rects[i].left, greaterThan(rects[i - 1].right), reason: 'labels $i overlap');
        }
        // The space between neighbouring labels is the same everywhere (when it is not scaled down
        // as a whole, which only happens when even the smallest font cannot fit).
        final gaps = [for (var i = 1; i < rects.length; i++) rects[i].left - rects[i - 1].right];
        final spread = gaps.reduce((a, b) => a > b ? a : b) - gaps.reduce((a, b) => a < b ? a : b);
        expect(spread, lessThan(1.0), reason: 'gaps differ: $gaps');
      });
    }
  }

  testWidgets('picking a timeframe does not move the other labels', (t) async {
    await _pump(t, 360, 1.0, selected: Timeframe.m1);
    final before = [for (final tf in Timeframe.values) _label(t, tf).center.dx];
    await _pump(t, 360, 1.0, selected: Timeframe.h4);
    final after = [for (final tf in Timeframe.values) _label(t, tf).center.dx];
    for (var i = 0; i < before.length; i++) {
      expect(after[i], closeTo(before[i], 0.01));
    }
  });
}
