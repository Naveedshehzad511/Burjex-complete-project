import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
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
  group('Stop Limit model', () {
    Map<String, String> check(ChartEdit e) => e.errors(_q, minLot: 0.01, maxLot: 100, lotStep: 0.01);

    test('Buy Stop Limit: stop above Ask, limit below stop, SL / TP from the limit', () {
      ChartEdit d({double stop = 1.1010, double? limit = 1.1005}) =>
          ChartEdit.draft(type: OrderType.stopLimit, side: 'BUY', volume: 0.1, entry: stop, limit: limit);
      expect(check(d()), isEmpty);
      expect(check(d(stop: 1.1000))['entry'], 'Must be above the Ask');
      expect(check(d(limit: 1.1015))['limit'], 'Must be below the stop price');
      expect(check(d(limit: null))['limit'], isNotNull);
      // SL between limit and stop is below the stop but ABOVE the fill price → invalid.
      expect(check(d()..sl = 1.1007)['sl'], 'Must be below the limit');
      expect(check(d()..sl = 1.0990), isEmpty);
      expect(check(d()..tp = 1.1007), isEmpty, reason: 'TP only needs to be above the limit');
      expect(d().typeLabel, 'Buy Stop Limit');
    });

    test('Sell Stop Limit: stop below Bid, limit above stop, SL / TP from the limit', () {
      ChartEdit d({double stop = 1.0990, double? limit = 1.0995}) =>
          ChartEdit.draft(type: OrderType.stopLimit, side: 'SELL', volume: 0.1, entry: stop, limit: limit);
      expect(check(d()), isEmpty);
      expect(check(d(stop: 1.1001))['entry'], 'Must be below the Bid');
      expect(check(d(limit: 1.0985))['limit'], 'Must be above the stop price');
      expect(check(d()..sl = 1.0993)['sl'], 'Must be above the limit');
      expect(check(d()..tp = 1.0980), isEmpty);
      expect(d().typeLabel, 'Sell Stop Limit');
    });

    test('a STOP_LIMIT row keeps both prices', () {
      final o = PendingOrder.fromJson({
        'id': 'x',
        'symbol': 'EURUSD',
        'side': 'SELL',
        'type': 'STOP_LIMIT',
        'volume': 0.3,
        'price': 1.0995,
        'stopPrice': 1.0990,
      });
      expect(o.entry, 1.0990, reason: 'entry is the stop trigger');
      expect(o.limit, 1.0995);
      expect(o.isStopLimit, isTrue);
      expect(o.label, 'Sell Stop Limit 0.30');
    });

    test('order modes map to engine types', () {
      expect(OrderMode.values.map((m) => m.api), [
        'MARKET', 'BUY_LIMIT', 'SELL_LIMIT', 'BUY_STOP', 'SELL_STOP', 'BUY_STOP_LIMIT', 'SELL_STOP_LIMIT',
      ]);
      expect(OrderMode.buyStopLimit.type, OrderType.stopLimit);
      expect(OrderMode.sellStopLimit.side, 'SELL');
    });
  });

  group('ChartTradeController', () {
    test('Buy / Sell panel is a real toggle and volume is one value', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(chartTradeProvider).panelVisible, isTrue);
      c.read(chartTradeProvider.notifier).togglePanel();
      expect(c.read(chartTradeProvider).panelVisible, isFalse);
      c.read(chartTradeProvider.notifier).togglePanel();
      expect(c.read(chartTradeProvider).panelVisible, isTrue);
      c.read(chartTradeProvider.notifier).setVolume(0.25);
      expect(c.read(chartTradeProvider).volume, 0.25);
      final p = await SharedPreferences.getInstance();
      expect(p.getDouble('bt_chart_trade_volume'), 0.25);
    });
  });

  group('Order panel', () {
    Future<void> pump(WidgetTester t, ChartEdit e, {List<String>? log}) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.light(Branding.fallback),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PendingPanel(
              edit: e,
              symbolLabel: 'EURUSD',
              digits: 5,
              quote: _q,
              minLot: 0.01,
              maxLot: 100,
              lotStep: 0.01,
              busy: false,
              serverError: null,
              onChanged: () {},
              onPickType: (m) => log?.add('mode:${m.api}'),
              onAddSl: () {},
              onAddTp: () {},
              onRemoveSl: () {},
              onRemoveTp: () {},
              onApply: () => log?.add('apply'),
              onMarket: (side) => log?.add('market:$side'),
              onClose: () {},
              onCancelOrder: () {},
            ),
          ),
        ),
      ));
    }

    testWidgets('all seven modes are offered and the current one is marked', (t) async {
      final log = <String>[];
      await pump(t, ChartEdit.draft(type: OrderType.market, volume: 0.1), log: log);
      for (final l in ['Market Execution', 'Buy Limit', 'Sell Limit', 'Buy Stop', 'Sell Stop', 'Buy Stop Limit', 'Sell Stop Limit']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      await t.ensureVisible(find.text('Sell Stop Limit'));
      await t.tap(find.text('Sell Stop Limit'));
      expect(log, ['mode:SELL_STOP_LIMIT']);
    });

    testWidgets('Market mode: no entry, Sell / Buy by Market', (t) async {
      final log = <String>[];
      await pump(t, ChartEdit.draft(type: OrderType.market, volume: 0.1), log: log);
      expect(find.text('EURUSD'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Entry price'), findsNothing);
      await t.ensureVisible(find.text('Buy by Market'));
      await t.tap(find.text('Buy by Market'));
      await t.ensureVisible(find.text('Sell by Market'));
      await t.tap(find.text('Sell by Market'));
      expect(log, ['market:BUY', 'market:SELL']);
    });

    testWidgets('Stop Limit shows Stop and Limit prices and blocks a bad limit', (t) async {
      final e = ChartEdit.draft(type: OrderType.stopLimit, side: 'BUY', volume: 0.1, entry: 1.1010, limit: 1.1015);
      await pump(t, e);
      expect(find.widgetWithText(TextField, 'Stop price'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Limit price'), findsOneWidget);
      expect(find.text('Must be below the stop price'), findsOneWidget);
      final btn = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Place Buy Stop Limit 0.10'));
      expect(btn.onPressed, isNull);
    });
  });

  const sizes = {
    '360x640': Size(360, 640),
    '390x844': Size(390, 844),
    '412x915': Size(412, 915),
    'tablet 1024x768': Size(1024, 768),
  };

  for (final entry in sizes.entries) {
    group('Chart screen ${entry.key}', () {
      final size = entry.value;

      testWidgets('MT5 header, caption and the Buy / Sell toggle', (t) async {
        final h = await _pumpChart(t, size);
        expect(t.takeException(), isNull);
        expect(find.byTooltip('Menu'), findsNothing, reason: 'no drawer menu on the chart screen');
        for (final tip in ['Crosshair', 'Indicators', 'Chart type', 'New order', 'Hide Buy / Sell']) {
          expect(find.byTooltip(tip), findsOneWidget, reason: tip);
        }
        expect(find.byKey(const ValueKey('symbol-caption')), findsOneWidget);
        expect(find.text('Euro vs US Dollar'), findsOneWidget);
        // Live Bid / Ask on the panel.
        expect(_price(1.10000), findsOneWidget);
        expect(_price(1.10020), findsOneWidget);

        final withPanel = t.getSize(find.byType(CandleChart)).height;
        expect(find.byKey(const ValueKey('trade-panel')), findsOneWidget);
        await t.tap(find.byTooltip('Hide Buy / Sell'));
        await t.pump(); // hidden on the very next frame, no animation
        expect(find.byKey(const ValueKey('trade-panel')), findsNothing);
        expect(find.text('SELL'), findsNothing);
        final without = t.getSize(find.byType(CandleChart)).height;
        expect(without, greaterThan(withPanel + 30), reason: 'the chart takes the freed height');
        await t.tap(find.byTooltip('Show Buy / Sell'));
        await t.pump();
        expect(find.byKey(const ValueKey('trade-panel')), findsOneWidget);
        expect(t.getSize(find.byType(CandleChart)).height, closeTo(withPanel, 0.5));
        expect(h.container.read(chartTradeProvider).panelVisible, isTrue);
        expect(t.takeException(), isNull);
        await _unmount(t);
      });

      testWidgets('timeframe strip switches the series, keeps the zoom', (t) async {
        final h = await _pumpChart(t, size);
        // Collapsed behind the current timeframe on every screen size (MT5).
        expect(find.byKey(const ValueKey('tf-h1')), findsNothing);
        await t.tap(find.byKey(const ValueKey('tf-current')));
        await t.pump();
        for (final tf in Timeframe.values) {
          expect(find.byKey(ValueKey('tf-${tf.name}')), findsOneWidget);
        }
        expect(find.byTooltip('Chart settings'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('tf-h1')));
        await _settle(t);
        expect(h.container.read(chartTfProvider), Timeframe.h1);
        expect(_chart(t).tf, Timeframe.h1);
        // H1 candles really are on screen (the fake gives each TF its own price level).
        expect(_chart(t).candles.first.o, closeTo(1.1 + Timeframe.h1.index * 0.001, 1e-9));
        expect(h.api.candleTfs, contains('EURUSD:1h'));
        expect(find.byKey(const ValueKey('tf-h1')), findsNothing, reason: 'strip collapses after a pick');
        expect(find.descendant(of: find.byKey(const ValueKey('tf-current')), matching: find.text('H1')), findsOneWidget);
        expect(t.takeException(), isNull);
        await _unmount(t);
      });

      testWidgets('crosshair toggle drives the chart', (t) async {
        await _pumpChart(t, size);
        expect(_chart(t).crosshairMode, isFalse);
        await t.tap(find.byTooltip('Crosshair'));
        await t.pump();
        expect(_chart(t).crosshairMode, isTrue);
        await t.tapAt(t.getCenter(find.byType(CandleChart)));
        await t.pump();
        await t.tap(find.byTooltip('Crosshair'));
        await t.pump();
        expect(_chart(t).crosshairMode, isFalse);
        expect(t.takeException(), isNull);
        await _unmount(t);
      });

      testWidgets('market BUY / SELL use the shared volume', (t) async {
        final h = await _pumpChart(t, size);
        await t.tap(find.byTooltip('Increase volume')); // 0.10 → 0.11
        await t.pump();
        await t.tap(find.text('BUY'));
        await _settle(t);
        await t.tap(find.text('SELL'));
        await _settle(t);
        expect(h.api.posts.map((p) => '${p['type']} ${p['side']} ${p['volume']}'), ['MARKET BUY 0.11', 'MARKET SELL 0.11']);
        expect(h.api.posts.first['price'], 1.10020, reason: 'BUY at the Ask');
        await _unmount(t);
      });

      testWidgets('order panel: every pending type places with its lines', (t) async {
        final h = await _pumpChart(t, size);
        await t.tap(find.byTooltip('New order'));
        await t.pump();
        expect(find.byKey(const ValueKey('panel-handle')), findsOneWidget, reason: 'opens collapsed (MT5-style) so the chart stays visible');
        await t.tap(find.byKey(const ValueKey('panel-toggle'))); // expand to check the header/title
        await t.pumpAndSettle();
        // The header no longer spells out a sentence (MT5 just shows the symbol) —
        // Market mode is confirmed by its own Buy/Sell-by-Market action buttons.
        expect(find.text('Buy by Market'), findsOneWidget, reason: 'opens on the last mode (Market)');
        expect(find.text('Sell by Market'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('panel-toggle'))); // back to collapsed for the rest of this test
        await t.pumpAndSettle();
        for (final m in OrderMode.values.where((m) => !m.isMarket)) {
          if (find.byType(PendingPanel).evaluate().isEmpty) {
            await t.tap(find.byTooltip('New order'));
            await t.pump();
          }
          await t.ensureVisible(find.text(m.label));
          await t.tap(find.text(m.label));
          await t.pumpAndSettle();
          final kinds = _chart(t).levels.where((l) => l.id == 'draft').map((l) => l.kind).toList();
          expect(kinds, m.isStopLimit ? [LevelKind.draft, LevelKind.limit] : [LevelKind.draft], reason: m.label);
          final place = find.textContaining('Place ${m.label}');
          await t.ensureVisible(place);
          await t.pumpAndSettle();
          await t.tap(place);
          await _settle(t);
        }
        final sent = h.api.posts.map((p) => '${p['type']}/${p['side']}').toList();
        expect(sent, ['BUY_LIMIT/BUY', 'SELL_LIMIT/SELL', 'BUY_STOP/BUY', 'SELL_STOP/SELL', 'STOP_LIMIT/BUY', 'STOP_LIMIT/SELL']);
        final bsl = h.api.posts[4], ssl = h.api.posts[5];
        expect((bsl['price'] as double) < (bsl['stopPrice'] as double), isTrue, reason: 'buy: limit below stop');
        expect((ssl['price'] as double) > (ssl['stopPrice'] as double), isTrue, reason: 'sell: limit above stop');
        expect(h.api.posts[2]['stopPrice'], h.api.posts[2]['price'], reason: 'plain stops unchanged');
        await _unmount(t);
      });

      testWidgets('dragging the Stop Limit lines and SL / TP updates the order', (t) async {
        final h = await _pumpChart(t, size);
        await t.tap(find.byTooltip('New order'));
        await t.pump();
        await t.ensureVisible(find.text('Buy Stop Limit'));
        await t.tap(find.text('Buy Stop Limit'));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('panel-toggle'))); // expand for the SL/TP "add line" buttons
        await t.pumpAndSettle();
        final levels = _chart(t).levels;
        ChartLevel lv(LevelKind k) => levels.firstWhere((l) => l.id == 'draft' && l.kind == k);
        _chart(t).onLevelDragEnd!(lv(LevelKind.draft), 1.10300);
        await t.pump();
        _chart(t).onLevelDragEnd!(_chart(t).levels.firstWhere((l) => l.kind == LevelKind.limit), 1.10250);
        await t.pump();
        // Reveal the Stop Levels fields, then add SL / TP lines and drag them.
        await t.ensureVisible(find.byKey(const ValueKey('add-stop-levels')));
        await t.tap(find.byKey(const ValueKey('add-stop-levels')));
        await t.pump();
        await t.ensureVisible(find.byTooltip('Add Stop loss line'));
        await t.tap(find.byTooltip('Add Stop loss line'));
        await t.pump();
        await t.ensureVisible(find.byTooltip('Add Take profit line'));
        await t.tap(find.byTooltip('Add Take profit line'));
        await t.pump();
        _chart(t).onLevelDragEnd!(_chart(t).levels.firstWhere((l) => l.id == 'draft' && l.kind == LevelKind.sl), 1.10100);
        _chart(t).onLevelDragEnd!(_chart(t).levels.firstWhere((l) => l.id == 'draft' && l.kind == LevelKind.tp), 1.10500);
        await t.pump();
        expect(find.text('1.10300'), findsWidgets);
        expect(find.text('1.10250'), findsWidgets);
        final place = find.textContaining('Place Buy Stop Limit');
        await t.ensureVisible(place);
        await t.tap(place);
        await _settle(t);
        final p = h.api.posts.single;
        expect([p['type'], p['side'], p['stopPrice'], p['price'], p['slPrice'], p['tpPrice']], ['STOP_LIMIT', 'BUY', 1.103, 1.1025, 1.101, 1.105]);
        await _unmount(t);
      });

      testWidgets('symbol switch via the caption', (t) async {
        final h = await _pumpChart(t, size);
        await t.tap(find.byKey(const ValueKey('symbol-caption')));
        await t.pumpAndSettle(const Duration(milliseconds: 50));
        await t.tap(find.text('GBPUSD').last);
        await t.pumpAndSettle(const Duration(milliseconds: 50));
        expect(h.container.read(chartSymbolProvider), 'GBPUSD');
        expect(find.text('Great Britain Pound vs US Dollar'), findsOneWidget);
        expect(_price(1.30020), findsOneWidget, reason: 'panel follows the new symbol');
        await _unmount(t);
      });
    });
  }

  testWidgets('live ticks move the panel prices and the forming candle', (t) async {
    final h = await _pumpChart(t, const Size(390, 844));
    h.container.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.10110, ask: 1.10130, ts: 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(_price(1.10110), findsOneWidget);
    expect(_price(1.10130), findsOneWidget);
    expect(_chart(t).candles.last.c, closeTo(1.10110, 1e-9), reason: 'forming bar tracks the bid');
    expect(_chart(t).livePrice, closeTo(1.10110, 1e-9));
    // The chart's own Bid/Ask lines track the same live quote the panels show,
    // and the gap between them widens/narrows with the real spread.
    expect(_chart(t).askPrice, closeTo(1.10130, 1e-9));
    h.container.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.10200, ask: 1.10260, ts: 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(_chart(t).livePrice, closeTo(1.10200, 1e-9));
    expect(_chart(t).askPrice, closeTo(1.10260, 1e-9), reason: 'ask line moves independently as the spread widens');
    await _unmount(t);
  });

  testWidgets('existing position: tap its line, set SL / TP, Apply', (t) async {
    final h = await _pumpChart(t, const Size(390, 844), seed: (api) {
      api.positions = [
        {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.5, 'openPrice': 1.09950, 'symbol': 'EURUSD'},
      ];
    });
    await _settle(t);
    final entry = _chart(t).levels.firstWhere((l) => l.id == 'p1' && l.kind == LevelKind.entry);
    _chart(t).onLevelTap!(entry);
    await t.pump();
    expect(find.byKey(const ValueKey('panel-handle')), findsOneWidget, reason: 'opens collapsed');
    await t.tap(find.byKey(const ValueKey('panel-toggle')));
    await t.pumpAndSettle();
    expect(find.text('Position'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('add-stop-levels')));
    await t.pump();
    await t.tap(find.byTooltip('Add Stop loss line'));
    await t.pump();
    _chart(t).onLevelDragEnd!(_chart(t).levels.firstWhere((l) => l.id == 'p1' && l.kind == LevelKind.sl), 1.09800);
    await t.pump();
    await t.ensureVisible(find.widgetWithText(FilledButton, 'Apply'));
    await t.tap(find.widgetWithText(FilledButton, 'Apply'));
    await _settle(t);
    expect(h.api.patches['/positions/p1'], {'slPrice': 1.098, 'tpPrice': null});
    await _unmount(t);
  });

  testWidgets('existing Stop Limit order: both lines drag, modify sends stop + limit', (t) async {
    final h = await _pumpChart(t, const Size(390, 844), seed: (api) {
      api.orders = [
        {'id': 'o7', 'accountId': 'A1', 'symbol': 'EURUSD', 'side': 'BUY', 'type': 'STOP_LIMIT', 'volume': 0.2, 'stopPrice': 1.1030, 'price': 1.1025},
      ];
    });
    await _settle(t);
    final mine = _chart(t).levels.where((l) => l.id == 'o7').map((l) => l.kind).toList();
    expect(mine, [LevelKind.pending, LevelKind.limit]);
    _chart(t).onLevelDragEnd!(_chart(t).levels.firstWhere((l) => l.id == 'o7' && l.kind == LevelKind.limit), 1.10270);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('panel-toggle')));
    await t.pumpAndSettle();
    expect(find.text('Buy Stop Limit'), findsWidgets); // header subtitle (+ the selected grid tile)
    await t.ensureVisible(find.text('Apply changes'));
    await t.tap(find.text('Apply changes'));
    await _settle(t);
    expect(h.api.patches['/orders/o7'], {'stopPrice': 1.103, 'price': 1.1027, 'slPrice': null, 'tpPrice': null});
    await _unmount(t);
  });
}
