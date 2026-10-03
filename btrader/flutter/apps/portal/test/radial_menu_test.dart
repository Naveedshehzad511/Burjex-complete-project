import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:burjex_portal/widgets/radial_chart_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gateway stand-in: enough candle history for one symbol/timeframe combo to
/// exercise the MT5-style round chart menu end to end.
class _FakeApi extends ApiClient {
  _FakeApi() : super(AuthStore());

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/market/candles') {
      final tf = '${query?['tf']}';
      final step = Timeframe.values.firstWhere((t) => t.api == tf).seconds;
      final end = (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ step * step - step;
      // A distinct price level per timeframe, so a test can tell the series apart.
      final base = 1.1 + Timeframe.values.indexWhere((t) => t.api == tf) * 0.001;
      return [
        for (var i = 199; i >= 0; i--)
          {'t': end - i * step, 'o': base, 'h': base + 0.0004, 'l': base - 0.0004, 'c': base + (i.isEven ? 0.0001 : -0.0001), 'v': 1}
      ];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async => {'accepted': true};
  @override
  Future<dynamic> patch(String path, [dynamic body]) async => <String, dynamic>{};
}

TradeSymbol _sym(String s, String desc) => TradeSymbol.fromJson({
      'id': s,
      'symbol': s,
      'description': desc,
      'class': 'CRYPTO', // 24/7 session, so the test never lands on "market closed"
      'digits': 5,
      'minLot': 0.01,
      'maxLot': 100,
      'lotStep': 0.01,
    });

ProviderContainer? _live;

Future<ProviderContainer> _pumpChart(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi();
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    feedSubscriptionProvider.overrideWith((_) {}),
    accountsProvider.overrideWith((_) async => const <Account>[]),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => [_sym('EURUSD', 'Euro vs US Dollar'), _sym('GBPUSD', 'Great Britain Pound vs US Dollar')]),
  ]);
  _live = c;
  c.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0));
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return c;
}

Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  _live?.dispose();
  _live = null;
  await t.pump(const Duration(seconds: 1));
}

/// The chart's `GestureDetector` also wires `onDoubleTap` (Auto fit), so a
/// single tap's own callback is deliberately held back by Flutter until the
/// double-tap window elapses, in case a second tap follows — pre-existing
/// behaviour, unrelated to the round menu. Real taps see the same short delay.
Future<void> _tapChart(WidgetTester t, Finder finder) async {
  await t.tap(finder);
  await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

void main() {
  testWidgets('tap the chart opens the round menu; tap again closes it', (t) async {
    await _pumpChart(t);
    expect(find.byType(RadialChartMenu), findsNothing);

    await _tapChart(t, find.byType(CandleChart));
    expect(find.byType(RadialChartMenu), findsOneWidget, reason: 'a plain tap on empty chart space opens the round menu');

    // The ring offers drawing tools — timeframes are not on this menu.
    final menu = t.widget<RadialChartMenu>(find.byType(RadialChartMenu));
    expect(menu.tools, containsAll([DrawingType.trendline, DrawingType.arrow, DrawingType.rectangle]));

    // Tapping the menu's dead centre (the crosshair hole) just dismisses it —
    // the menu's own GestureDetector has no onDoubleTap, so this is immediate.
    await t.tap(find.byType(RadialChartMenu));
    await t.pump();
    expect(find.byType(RadialChartMenu), findsNothing);

    // It can be reopened.
    await _tapChart(t, find.byType(CandleChart));
    expect(find.byType(RadialChartMenu), findsOneWidget);
    await _unmount(t);
  });

  testWidgets('picking a tool on the ring closes the menu and arms that tool', (t) async {
    await _pumpChart(t);
    await _tapChart(t, find.byType(CandleChart));
    final menu = t.widget<RadialChartMenu>(find.byType(RadialChartMenu));

    menu.onSelectTool(DrawingType.rectangle);
    await t.pump();

    expect(find.byType(RadialChartMenu), findsNothing, reason: 'the menu closes once a tool is picked');
    expect(t.widget<CandleChart>(find.byType(CandleChart)).activeTool, DrawingType.rectangle);
    expect(find.text('Rect: drag on the chart'), findsOneWidget);
    await _unmount(t);
  });

  testWidgets('Duplicate opens Charts, New Window adds a second pane, tile + remove work', (t) async {
    await _pumpChart(t);
    await _tapChart(t, find.byType(CandleChart));
    final menu = t.widget<RadialChartMenu>(find.byType(RadialChartMenu));

    menu.onDuplicate();
    await t.pumpAndSettle();
    expect(find.text('Charts'), findsOneWidget);
    expect(find.text('New Window'), findsOneWidget);
    expect(find.text('Tile Horizontally'), findsNothing, reason: 'only one window exists so far');

    await t.tap(find.text('New Window'));
    await t.pumpAndSettle();
    expect(find.byType(CandleChart), findsNWidgets(2), reason: 'the second chart window is now showing');
    expect(find.text('Tile Horizontally'), findsOneWidget);
    expect(find.text('Tile Vertically'), findsOneWidget);

    final addRow = t.widget<ListTile>(find.widgetWithText(ListTile, 'New Window'));
    expect(addRow.enabled, isFalse, reason: 'the max supported window count (2) was reached');

    await t.tap(find.text('Tile Vertically'));
    await t.pumpAndSettle();
    expect(find.byType(Row).evaluate().any((_) => true), isTrue);

    // Select the second window and remove it — back to a single chart.
    await t.tap(find.byIcon(Icons.drag_handle).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    expect(find.byType(CandleChart), findsOneWidget);
    await _unmount(t);
  });

  // Real pointer taps (not callback calls), so the whole tap path through the Stack is exercised.
  Future<void> tapMenuTool(WidgetTester t, DrawingType tool) async {
    final menu = t.widget<RadialChartMenu>(find.byType(RadialChartMenu));
    final origin = t.getTopLeft(find.byType(RadialChartMenu));
    final i = menu.tools.indexOf(tool);
    final ang = (i + 0.5) * 2 * math.pi / menu.tools.length - math.pi / 2;
    final r = (menu.outerRadius + menu.innerRadius) / 2;
    await t.tapAt(origin + menu.center + Offset(r * math.cos(ang), r * math.sin(ang)));
    await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
  }

  for (final tool in kRadialTools) {
    testWidgets('${tool.label}: pick on the menu → ${tool.anchorCount >= 2 ? 'touch-drag-release' : 'one tap'} creates it → tool resets → next tap reopens the menu', (t) async {
      final c = await _pumpChart(t);
      final chart = find.byType(CandleChart);
      CandleChart widget() => t.widget<CandleChart>(chart);
      final centre = t.getCenter(chart);

      await _tapChart(t, chart);
      expect(find.byType(RadialChartMenu), findsOneWidget);
      await tapMenuTool(t, tool);

      // The tap that picked the tool neither reopened the menu nor placed a point.
      expect(find.byType(RadialChartMenu), findsNothing);
      expect(widget().activeTool, tool);
      expect(widget().pendingAnchors, isEmpty);

      if (tool.anchorCount >= 2) {
        // MT5-style: ONE touch -> drag -> release draws it. No per-point taps, and the drag must not pan.
        expect(find.text('${tool.shortLabel}: drag on the chart'), findsOneWidget);
        final g = await t.startGesture(centre + const Offset(-60, -30));
        await g.moveBy(const Offset(40, 25));
        await t.pump();
        await g.moveBy(const Offset(70, 45));
        await t.pump();
        await g.up();
        await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      } else {
        expect(find.text('${tool.shortLabel}: tap the chart'), findsOneWidget);
        await t.tapAt(centre + const Offset(-60, -30));
        await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      }
      expect(find.byType(RadialChartMenu), findsNothing, reason: 'creating a drawing never opens the menu');

      // Complete: one drawing of this type with its own number of points, tool inactive, hint gone.
      final drawn = c.read(chartDrawingsProvider);
      expect(drawn, hasLength(1));
      expect(drawn.single.type, tool);
      expect(drawn.single.anchors, hasLength(tool.anchorCount));
      expect(widget().activeTool, isNull);
      expect(find.textContaining('chart'), findsNothing, reason: 'the hint is gone once the tool is done');

      // Only now does a plain chart tap open the round menu again. Tap away from the drawing.
      await t.tapAt(centre + const Offset(110, -170));
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      expect(find.byType(RadialChartMenu), findsOneWidget);
      await _unmount(t);
    });
  }

  group('existing drawings', () {
    // Draws a Trend by touch-drag-release and returns the container, leaving the chart in normal mode.
    Future<ProviderContainer> drawTrend(WidgetTester t) async {
      final c = await _pumpChart(t);
      final chart = find.byType(CandleChart);
      final centre = t.getCenter(chart);
      await _tapChart(t, chart);
      await tapMenuTool(t, DrawingType.trendline);
      final g = await t.startGesture(centre + const Offset(-80, 0));
      await g.moveBy(const Offset(60, 20));
      await g.moveBy(const Offset(100, 40));
      await g.up();
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      expect(c.read(chartDrawingsProvider), hasLength(1));
      return c;
    }

    testWidgets('dragging a drawing by its body moves the whole thing and persists; it does not pan or open the menu', (t) async {
      final c = await drawTrend(t);
      final before = c.read(chartDrawingsProvider).single;
      final chart = find.byType(CandleChart);
      final centre = t.getCenter(chart);
      // The middle of the line: (-80,0) .. (+80,+60) relative to the chart centre.
      final g = await t.startGesture(centre + const Offset(0, 30));
      await g.moveBy(const Offset(0, -60));
      await g.moveBy(const Offset(0, -60));
      await g.up();
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));

      final after = c.read(chartDrawingsProvider).single;
      expect(after.id, before.id);
      expect(after.anchors, hasLength(2));
      final d0 = after.anchors[0].price - before.anchors[0].price;
      final d1 = after.anchors[1].price - before.anchors[1].price;
      expect(d0, greaterThan(0), reason: 'dragged up -> higher price');
      expect(d1, closeTo(d0, d0.abs() * 0.01 + 1e-9), reason: 'both ends move by the same amount (the shape is kept)');
      expect(find.byType(RadialChartMenu), findsNothing);
      await _unmount(t);
    });

    testWidgets('dragging a handle of the selected drawing changes only that end', (t) async {
      final c = await drawTrend(t);
      final chart = find.byType(CandleChart);
      final centre = t.getCenter(chart);
      // Select it by tapping its body, then drag the END handle (right end of the line).
      await t.tapAt(centre + const Offset(0, 30));
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      final before = c.read(chartDrawingsProvider).single;
      final g = await t.startGesture(centre + const Offset(80, 60));
      await g.moveBy(const Offset(0, -50));
      await g.moveBy(const Offset(0, -50));
      await g.up();
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      final after = c.read(chartDrawingsProvider).single;
      expect(after.anchors[0].t, before.anchors[0].t, reason: 'the start did not move');
      expect(after.anchors[0].price, before.anchors[0].price, reason: 'the start did not move');
      expect(after.anchors[1].price, isNot(before.anchors[1].price), reason: 'the end changed');
      await _unmount(t);
    });

    testWidgets('a tap outside every drawing opens the round menu and moves nothing', (t) async {
      final c = await drawTrend(t);
      final before = c.read(chartDrawingsProvider).single;
      await t.tapAt(t.getCenter(find.byType(CandleChart)) + const Offset(110, -170));
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      expect(find.byType(RadialChartMenu), findsOneWidget);
      final now = c.read(chartDrawingsProvider).single.anchors;
      for (var i = 0; i < now.length; i++) {
        expect(now[i].t, before.anchors[i].t);
        expect(now[i].price, before.anchors[i].price);
      }
      await _unmount(t);
    });

    testWidgets('with no tool armed and no drawing under the finger, a drag still pans (no drawing, no menu)', (t) async {
      final c = await _pumpChart(t);
      final chart = find.byType(CandleChart);
      final centre = t.getCenter(chart);
      await t.dragFrom(centre + const Offset(-50, -100), const Offset(120, 0));
      await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
      expect(c.read(chartDrawingsProvider), isEmpty);
      expect(find.byType(RadialChartMenu), findsNothing);
      await _unmount(t);
    });
  });
}
