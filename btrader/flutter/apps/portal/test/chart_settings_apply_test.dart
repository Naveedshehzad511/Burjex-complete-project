import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/chart_settings_screen.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/state/chart_settings.dart';
import 'package:burjex_portal/state/chart_trade.dart';
import 'package:burjex_portal/state/pending_orders.dart';
import 'package:burjex_portal/widgets/big_figure_price.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:burjex_portal/widgets/pending_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _q = Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0);

/// Gateway stand-in: candles per timeframe, empty positions / orders, and an
/// order endpoint that accepts and records what the chart sent.
class _FakeApi extends ApiClient {
  _FakeApi() : super(AuthStore());
  final posts = <Map<String, dynamic>>[];
  final patches = <String, Map<String, dynamic>>{};
  final candleTfs = <String>[];
  List<Map<String, dynamic>> positions = [];
  List<Map<String, dynamic>> orders = [];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/market/candles') {
      final tf = '${query?['tf']}';
      final sym = '${query?['symbol']}';
      candleTfs.add('$sym:$tf');
      final step = Timeframe.values.firstWhere((t) => t.api == tf).seconds;
      final end = (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ step * step - step;
      // A distinct price level per timeframe, so a test can tell the series apart.
      final base = 1.1 + Timeframe.values.indexWhere((t) => t.api == tf) * 0.001;
      return [
        for (var i = 199; i >= 0; i--)
          {'t': end - i * step, 'o': base, 'h': base + 0.0004, 'l': base - 0.0004, 'c': base + (i.isEven ? 0.0001 : -0.0001), 'v': 1}
      ];
    }
    if (path == '/positions') return positions;
    if (path == '/orders') return orders;
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    if (path == '/orders') {
      posts.add(Map<String, dynamic>.from(body as Map));
      return {'accepted': true, 'orderId': 'o${posts.length}', 'fillPrice': 1.1};
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> patch(String path, [dynamic body]) async {
    patches[path] = Map<String, dynamic>.from(body as Map);
    return <String, dynamic>{};
  }
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

class _Harness {
  _Harness(this.api, this.container);
  final _FakeApi api;
  final ProviderContainer container;
}

Future<_Harness> _pumpChart(WidgetTester t, Size size, {void Function(_FakeApi api)? seed}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi();
  seed?.call(api);
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    feedSubscriptionProvider.overrideWith((_) {}),
    accountsProvider.overrideWith((_) async => const <Account>[]),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    // Same data path as the app (GET /positions through the fake api), minus its 30 s refresh
    // ticker (a test can't outlive it).
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => [_sym('EURUSD', 'Euro vs US Dollar'), _sym('GBPUSD', 'Great Britain Pound vs US Dollar')]),
  ]);
  _live = c;
  c.read(quotesProvider.notifier).set(_q);
  c.read(quotesProvider.notifier).set(const Tick(symbol: 'GBPUSD', bid: 1.30000, ask: 1.30020, ts: 0));
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return _Harness(api, c);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

ProviderContainer? _live;

/// Tear the screen and its providers down so their periodic timers stop before
/// the test's pending-timer check.
Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  _live?.dispose();
  _live = null;
  await t.pump(const Duration(seconds: 1));
}

/// A SELL / BUY panel showing exactly [v] (prices render MT5-style, big pip digits).
Finder _price(double v) => find.byWidgetPredicate((w) => w is BigFigurePrice && (w.value - v).abs() < 1e-9);

CandleChart _chart(WidgetTester t) => t.widget<CandleChart>(find.byType(CandleChart));


void main() {
  group('Period separators', () {
    test('MT5 mapping: M1-H1 days, H4 weeks (Monday), D1 months, W1/MN years', () {
      final a = DateTime(2025, 11, 5, 23, 55); // Wed
      final b = DateTime(2025, 11, 6, 0, 5); // Thu, next day
      for (final tf in [Timeframe.m1, Timeframe.m5, Timeframe.m15, Timeframe.m30, Timeframe.h1]) {
        expect(periodSeparatorKey(a, tf) == periodSeparatorKey(b, tf), isFalse, reason: '$tf');
        expect(periodSeparatorKey(DateTime(2025, 11, 5, 1), tf), periodSeparatorKey(DateTime(2025, 11, 5, 22), tf), reason: '$tf');
      }
      // H4: Mon 3 Nov .. Sun 9 Nov is one week; Mon 10 Nov starts the next.
      expect(periodSeparatorKey(DateTime(2025, 11, 3, 0), Timeframe.h4), periodSeparatorKey(DateTime(2025, 11, 9, 20), Timeframe.h4));
      expect(periodSeparatorKey(DateTime(2025, 11, 9, 20), Timeframe.h4) == periodSeparatorKey(DateTime(2025, 11, 10, 0), Timeframe.h4), isFalse);
      // D1: months. W1 / MN: years.
      expect(periodSeparatorKey(DateTime(2025, 11, 1), Timeframe.d1), periodSeparatorKey(DateTime(2025, 11, 30), Timeframe.d1));
      expect(periodSeparatorKey(DateTime(2025, 11, 30), Timeframe.d1) == periodSeparatorKey(DateTime(2025, 12, 1), Timeframe.d1), isFalse);
      expect(periodSeparatorKey(DateTime(2025, 1, 1), Timeframe.w1), periodSeparatorKey(DateTime(2025, 12, 31), Timeframe.w1));
      expect(periodSeparatorKey(DateTime(2025, 12, 31), Timeframe.mn1) == periodSeparatorKey(DateTime(2026, 1, 1), Timeframe.mn1), isFalse);
    });

    testWidgets('the setting reaches the chart immediately and is off by default', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      expect(_chart(t).periodSeparators, isFalse);
      h.container.read(chartSettingsProvider.notifier).setPeriodSeparators(true);
      await t.pump();
      expect(_chart(t).periodSeparators, isTrue);
      expect(t.takeException(), isNull);
      for (final tf in [Timeframe.m1, Timeframe.h1, Timeframe.h4, Timeframe.d1, Timeframe.w1, Timeframe.mn1, Timeframe.m5]) {
        h.container.read(chartTfProvider.notifier).set(tf);
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(t.takeException(), isNull, reason: '$tf');
        expect(_chart(t).periodSeparators, isTrue, reason: '$tf');
      }
      h.container.read(chartSettingsProvider.notifier).setPeriodSeparators(false);
      await t.pump();
      expect(_chart(t).periodSeparators, isFalse);
      await _unmount(t);
    });
  });

  group('Trading panel at the bottom', () {
    testWidgets('unticked (default): the panel is under the toolbar, above the chart', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      final panel = find.byKey(const ValueKey('trade-panel'));
      expect(h.container.read(chartSettingsProvider).tradingPanelAtBottom, isFalse);
      expect(panel, findsOneWidget);
      expect(t.getTopLeft(panel).dy, lessThan(t.getTopLeft(find.byType(CandleChart)).dy), reason: 'at the top, as before');
      await _unmount(t);
    });

    testWidgets('ticked: the same panel moves below the chart; unticking brings it back to the top; one panel at a time', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      final panel = find.byKey(const ValueKey('trade-panel'));
      final chartH = t.getSize(find.byType(CandleChart)).height;
      final set = h.container.read(chartSettingsProvider.notifier);

      set.setTradingPanelAtBottom(true);
      await t.pump();
      expect(panel, findsOneWidget, reason: 'never two panels');
      expect(t.getTopLeft(panel).dy, greaterThanOrEqualTo(t.getBottomLeft(find.byType(CandleChart)).dy - 0.5), reason: 'at the bottom');
      expect(t.getSize(find.byType(CandleChart)).height, closeTo(chartH, 0.5), reason: 'the panel only changed place');
      expect(_price(1.10000), findsOneWidget);
      expect(_price(1.10020), findsOneWidget);

      set.setTradingPanelAtBottom(false);
      await t.pump();
      expect(panel, findsOneWidget);
      expect(t.getTopLeft(panel).dy, lessThan(t.getTopLeft(find.byType(CandleChart)).dy), reason: 'back at the top');
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('BUY / SELL, the volume and live prices work the same at the bottom; the toolbar toggle still hides it', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      final panel = find.byKey(const ValueKey('trade-panel'));
      h.container.read(chartSettingsProvider.notifier).setTradingPanelAtBottom(true);
      await t.pump();

      await t.tap(find.byTooltip('Increase volume'));
      await t.pump();
      await t.tap(find.text('BUY'));
      await _settle(t);
      await t.tap(find.text('SELL'));
      await _settle(t);
      expect(h.api.posts.map((p) => '${p['type']} ${p['side']} ${p['volume']}'), ['MARKET BUY 0.11', 'MARKET SELL 0.11']);

      h.container.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.10100, ask: 1.10120, ts: 0));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(_price(1.10100), findsOneWidget);
      expect(_price(1.10120), findsOneWidget);

      // The toolbar's Buy / Sell toggle is unchanged: it hides / shows the panel wherever it sits.
      await t.tap(find.byTooltip('Hide Buy / Sell'));
      await t.pump();
      expect(panel, findsNothing);
      await t.tap(find.byTooltip('Show Buy / Sell'));
      await t.pump();
      expect(panel, findsOneWidget);
      expect(t.getTopLeft(panel).dy, greaterThanOrEqualTo(t.getBottomLeft(find.byType(CandleChart)).dy - 0.5));
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('the exact user flow in Settings: tick, pick a timeframe, untick, go back, open / close the timeframe strip', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      final panel = find.byKey(const ValueKey('trade-panel'));
      double panelY() => t.getTopLeft(panel).dy;
      double chartTop() => t.getTopLeft(find.byType(CandleChart)).dy;
      Future<void> settle() async {
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
      }

      // Flips the checkbox in the real Settings screen, pushed over the chart as the app does.
      Future<void> flipInSettings() async {
        final nav = Navigator.of(t.element(find.byType(ChartsScreen)));
        nav.push(MaterialPageRoute<void>(builder: (_) => const ChartSettingsScreen()));
        await t.pumpAndSettle();
        final tile = find.byKey(const ValueKey('cs-panel-bottom'));
        await t.ensureVisible(tile);
        await t.pump();
        await t.tap(tile);
        await settle();
        nav.pop();
        await t.pumpAndSettle();
      }

      Future<void> pickTimeframe(String label) async {
        await t.tap(find.byKey(const ValueKey('tf-current'))); // opens the strip
        await settle();
        expect(find.text('MN'), findsOneWidget, reason: 'the strip is open');
        await t.tap(find.text(label)); // picking one closes it
        await settle();
        expect(find.text('MN'), findsNothing, reason: 'the strip is closed');
      }

      expect(panelY(), lessThan(chartTop()), reason: 'starts at the top');
      await flipInSettings(); // tick
      expect(h.container.read(chartSettingsProvider).tradingPanelAtBottom, isTrue);
      expect(panelY(), greaterThanOrEqualTo(t.getBottomLeft(find.byType(CandleChart)).dy - 0.5), reason: 'ticked: bottom');
      await pickTimeframe('M15');
      expect(panelY(), greaterThanOrEqualTo(t.getBottomLeft(find.byType(CandleChart)).dy - 0.5), reason: 'still bottom after a timeframe');
      await flipInSettings(); // untick
      expect(h.container.read(chartSettingsProvider).tradingPanelAtBottom, isFalse);
      expect(panel, findsOneWidget);
      expect(panelY(), lessThan(chartTop()), reason: 'unticked: back at the top');
      await t.tap(find.byKey(const ValueKey('tf-current')));
      await settle();
      expect(panelY(), lessThan(chartTop()), reason: 'strip open: still at the top');
      await t.tap(find.text('M5'));
      await settle();
      expect(panelY(), lessThan(chartTop()), reason: 'strip closed: still at the top');
      expect(t.takeException(), isNull);
      await _unmount(t);
    });
  });
}
