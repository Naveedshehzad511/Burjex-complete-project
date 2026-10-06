import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';

List<Candle> bars(int n) {
  const end = 1700000000 ~/ 300 * 300;
  return [
    for (var i = n - 1; i >= 0; i--)
      Candle(t: end - i * 300, o: 1.1000, h: 1.1010 + (i % 5) * 0.0001, l: 1.0990 - (i % 3) * 0.0001, c: 1.1004, v: 1),
  ];
}

ChartLevel line(double price, {bool draggable = false}) =>
    ChartLevel(price, Colors.blue, 'BUY 0.10', kind: LevelKind.entry, draggable: draggable, tappable: true);

void main() {
  final cs = bars(85);
  double share(List<ChartLevel> lv) {
    final base = chartRange(cs, const []);
    final r = chartRange(cs, lv);
    return (base.hi - base.lo) / (r.hi - r.lo);
  }

  test('trade lines far from the candles do not stretch the price scale', () {
    final far = [for (var i = 1; i <= 10; i++) line(1.1 + i * 0.004), line(1.0), line(0.9)];
    expect(share(far), closeTo(1.0, 1e-9), reason: 'the candles keep the whole pane');
  });

  test('a trade line close to the candles is still pulled into view', () {
    final near = [line(1.1020)]; // a few pips above the highs (within reach)
    expect(share(near), lessThan(1.0));
    final r = chartRange(cs, near);
    expect(r.hi, greaterThan(1.1020));
  });

  test('however many trades, the candles keep a usable share of the pane', () {
    for (final spread in [0.0005, 0.004, 0.02, 0.1]) {
      final lv = [for (var i = 0; i < 40; i++) line(1.1 + (i / 40 - 0.5) * spread)];
      expect(share(lv), greaterThan(0.5), reason: 'spread $spread');
    }
  });

  test('a line being edited / dragged is always kept in view, however far', () {
    final r = chartRange(cs, [line(1.2, draggable: true)]);
    expect(r.hi, greaterThan(1.2));
  });

  testWidgets('the chart pans 1:1 with many open trades, exactly as without', (t) async {
    t.view
      ..physicalSize = const Size(420, 700)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Future<double> moved(List<ChartLevel> lv, Object key) async {
      final vp = ValueNotifier<({double offset, double slot})>((offset: 0, slot: 1));
      await t.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: AppTheme.dark(Branding.fallback),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 700,
            child: CandleChart(candles: bars(1500), digits: 5, tf: Timeframe.m5, viewKey: key, levels: lv, debugViewport: vp),
          ),
        ),
      ));
      await t.pump();
      final g = await t.startGesture(const Offset(210, 300));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(6, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await t.pump(const Duration(milliseconds: 300));
      await g.up();
      await t.pump(const Duration(seconds: 4));
      return vp.value.offset;
    }

    final none = await moved(const [], 'a');
    // 12 positions, each with entry / SL / TP, right across the pane where the finger goes down.
    final many = await moved([
      for (var i = 0; i < 12; i++) ...[line(1.0990 + i * 0.0002), line(1.0970 + i * 0.0002), line(1.1030 + i * 0.0002)],
    ], 'b');
    expect(none, greaterThan(20), reason: 'it did pan');
    expect(many, closeTo(none, 0.01), reason: 'trades must not change how the chart moves');
  });
}
