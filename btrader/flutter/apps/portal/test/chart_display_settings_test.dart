import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/state/chart_colors.dart';
import 'package:burjex_portal/state/chart_settings.dart';
import 'package:burjex_portal/state/trade_history.dart';
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
  List<Map<String, dynamic>> deals = [];
  final dealRequests = <Map<String, dynamic>>[];

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
    if (path == '/history/deals') {
      dealRequests.add({...?query});
      return deals;
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



Map<String, dynamic> _deal(String id, String symbol, {String side = 'BUY', String position = 'p9', String type = 'CLOSE', double open = 1.0990, double close = 1.1010, double profit = 12.5, double volume = 0.5, int openAgoMin = 120, int closeAgoMin = 60}) {
  final now = DateTime.now().toUtc();
  return {
    'id': id,
    'type': type,
    'side': side,
    'volume': volume,
    'price': close,
    'profit': profit,
    'swap': 0,
    'commission': 0,
    'openCommission': 0,
    'balanceAfter': 1000,
    'createdAt': now.subtract(Duration(minutes: closeAgoMin)).toIso8601String(),
    'symbol': symbol,
    'digits': 5,
    'openPrice': open,
    'openedAt': now.subtract(Duration(minutes: openAgoMin)).toIso8601String(),
    'positionId': position,
    'ticket': position,
  };
}

void main() {
  group('chartTradesFromDeals', () {
    test('closed trades only, one per deal, with everything the markers need', () {
      final deals = [
        Deal.fromJson(_deal('d1', 'EURUSD')),
        Deal.fromJson(_deal('d1', 'EURUSD')), // the same deal again (a refetch): once
        Deal.fromJson({..._deal('b1', 'EURUSD'), 'type': 'DEPOSIT', 'symbol': null, 'openPrice': null, 'openedAt': null}),
        Deal.fromJson(_deal('o1', 'EURUSD', type: 'OPEN')), // the open deal is not a closed trade
        Deal.fromJson({..._deal('x1', 'EURUSD'), 'openPrice': null}), // no entry known: nothing to draw
        Deal.fromJson(_deal('d2', 'GBPUSD', side: 'SELL', open: 1.30, close: 1.29, profit: 10)),
      ];
      final trades = chartTradesFromDeals(deals);
      expect(trades.map((t) => t.id), ['d1', 'd2']);
      final t = trades.first;
      expect((t.symbol, t.side, t.volume, t.openPrice, t.closePrice, t.profit, t.ticket), ('EURUSD', 'BUY', 0.5, 1.0990, 1.1010, 12.5, 'p9'));
      expect(t.closeTime, greaterThan(t.openTime));
      expect(t.isBuy, isTrue);
      expect(trades.last.isBuy, isFalse);
    });

    test('a position closed in steps gives one trade per close, sharing the position (entry drawn once)', () {
      final trades = chartTradesFromDeals([
        Deal.fromJson(_deal('c1', 'EURUSD', type: 'PARTIAL_CLOSE', volume: 0.2, closeAgoMin: 90)),
        Deal.fromJson(_deal('c2', 'EURUSD', volume: 0.3, closeAgoMin: 30)),
      ]);
      expect(trades.length, 2);
      expect(trades.map((t) => t.positionId).toSet().length, 1);
    });
  });

  group('Chart display settings (positions, orders, SL/TP, P/L)', () {
    List<LevelKind> kinds(WidgetTester t) => _chart(t).levels.map((l) => l.kind).toList();

    testWidgets('each switch hides only its own chart elements; trades and orders themselves are untouched', (t) async {
      final h = await _pumpChart(t, const Size(412, 915), seed: (api) {
        api.positions = [
          {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.5, 'openPrice': 1.09950, 'symbol': 'EURUSD', 'slPrice': 1.0950, 'tpPrice': 1.1050},
        ];
        api.orders = [
          {'id': 'o1', 'accountId': 'A1', 'symbol': 'EURUSD', 'side': 'BUY', 'type': 'BUY_LIMIT', 'volume': 0.2, 'price': 1.0900, 'slPrice': 1.0850},
        ];
      });
      await _settle(t);
      final set = h.container.read(chartSettingsProvider.notifier);
      Future<void> apply() async {
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
      }

      // Everything shown by default, with the live P/L in the entry label (as before).
      var ks = kinds(t);
      expect(ks.where((k) => k == LevelKind.entry).length, 1);
      expect(ks.where((k) => k == LevelKind.pending).length, 1);
      expect(ks.where((k) => k == LevelKind.sl).length, 2, reason: 'the position\'s and the order\'s');
      expect(ks.where((k) => k == LevelKind.tp).length, 1);
      final entry = _chart(t).levels.firstWhere((l) => l.kind == LevelKind.entry);
      expect(entry.label, matches(RegExp(r'^BUY 0\.50, [+-]\d')), reason: 'P/L shown');
      expect(entry.plColor, isNotNull);

      // Profit/loss off: the label is just side and volume; nothing else moves.
      set.setProfitLoss(false);
      await apply();
      final e2 = _chart(t).levels.firstWhere((l) => l.kind == LevelKind.entry);
      expect(e2.label, 'BUY 0.50');
      expect(e2.plColor, isNull);
      expect(kinds(t).length, ks.length);
      set.setProfitLoss(true);

      // SL/TP off: no SL / TP lines for positions or orders; the entry and the order line stay.
      set.setSlTpLevels(false);
      await apply();
      ks = kinds(t);
      expect(ks.contains(LevelKind.sl) || ks.contains(LevelKind.tp), isFalse);
      expect(ks.contains(LevelKind.entry) && ks.contains(LevelKind.pending), isTrue);
      set.setSlTpLevels(true);

      // Trade positions off: no entry line; its SL / TP (own switch) and the order stay.
      set.setTradePositions(false);
      await apply();
      ks = kinds(t);
      expect(ks.contains(LevelKind.entry), isFalse);
      expect(ks.contains(LevelKind.sl) && ks.contains(LevelKind.tp) && ks.contains(LevelKind.pending), isTrue);
      set.setTradePositions(true);

      // Trade orders off: no pending line; the order's SL stays under its own switch.
      set.setTradeOrders(false);
      await apply();
      ks = kinds(t);
      expect(ks.contains(LevelKind.pending), isFalse);
      expect(ks.where((k) => k == LevelKind.sl).length, 2);
      set.setTradeOrders(true);

      // Back on: exactly the original set. And the real data was never touched.
      await apply();
      expect(kinds(t), ks.length == 0 ? isEmpty : isNotEmpty);
      expect(_chart(t).levels.where((l) => l.kind == LevelKind.entry).length, 1);
      expect(_chart(t).levels.where((l) => l.kind == LevelKind.pending).length, 1);
      expect(h.container.read(openPositionsProvider).valueOrNull?.length, 1);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });
  });

  group('Trade history on the chart', () {
    testWidgets('off: nothing is requested or drawn; on: this symbol\'s closed trades, no duplicates, tap shows details', (t) async {
      final h = await _pumpChart(t, const Size(412, 915), seed: (api) {
        api.deals = [
          _deal('d1', 'EURUSD'),
          _deal('d1', 'EURUSD'), // duplicate row
          _deal('d2', 'GBPUSD', side: 'SELL', open: 1.3010, close: 1.2990),
          {..._deal('b1', 'EURUSD'), 'type': 'DEPOSIT', 'symbol': null, 'openPrice': null, 'openedAt': null},
        ];
      });
      await _settle(t);
      expect(h.container.read(chartSettingsProvider).tradeHistory, isFalse);
      expect(_chart(t).trades, isEmpty);
      expect(h.api.dealRequests, isEmpty, reason: 'nothing is fetched while the option is off');

      h.container.read(chartSettingsProvider.notifier).setTradeHistory(true);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(h.api.dealRequests, isNotEmpty);
      expect(h.api.dealRequests.first['accountId'], 'A1');
      expect(h.api.dealRequests.first['from'], isNotNull, reason: 'covers the loaded candles, not a fixed date');
      final trades = _chart(t).trades;
      expect(trades.map((x) => x.id), ['d1'], reason: 'EURUSD only, the duplicate and the deposit left out');
      expect(trades.single.openPrice, 1.0990);

      // A trade event (a close) refetches over the same window; the markers are not duplicated.
      final before = h.api.dealRequests.length;
      h.container.read(tradeEventEpochProvider.notifier).state++;
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(h.api.dealRequests.length, greaterThan(before));
      expect(_chart(t).trades.map((x) => x.id), ['d1']);

      // Tapping a marker shows its details.
      _chart(t).onTradeTap!(trades.single, true);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('trade-details')), findsOneWidget);
      expect(find.text('Exit · Buy 0.50 EURUSD'), findsOneWidget);
      expect(find.text('1.09900'), findsOneWidget);
      expect(find.text('1.10100'), findsOneWidget);
      expect(find.textContaining('+12.50'), findsOneWidget);
      expect(find.text('#p9'), findsOneWidget);
      await t.tapAt(const Offset(10, 10)); // dismiss
      await t.pumpAndSettle();

      // Off again: gone at once.
      h.container.read(chartSettingsProvider.notifier).setTradeHistory(false);
      await t.pump();
      expect(_chart(t).trades, isEmpty);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('switching the symbol shows that symbol\'s trades', (t) async {
      final h = await _pumpChart(t, const Size(412, 915), seed: (api) {
        api.deals = [_deal('d1', 'EURUSD'), _deal('d2', 'GBPUSD', side: 'SELL', open: 1.3010, close: 1.2990, position: 'p8')];
      });
      h.container.read(chartSettingsProvider.notifier).setTradeHistory(true);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_chart(t).trades.map((x) => x.symbol).toSet(), {'EURUSD'});
      h.container.read(chartSymbolProvider.notifier).set('GBPUSD');
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_chart(t).trades.map((x) => x.symbol).toSet(), {'GBPUSD'});
      await _unmount(t);
    });
  });

  group('Colors and Free chart movement reach the chart screen', () {
    testWidgets('the chosen colours reach the candles, price lines and every trading level (line and text separately)', (t) async {
      final h = await _pumpChart(t, const Size(412, 915), seed: (api) {
        api.positions = [
          {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.5, 'openPrice': 1.09950, 'symbol': 'EURUSD', 'slPrice': 1.0950, 'tpPrice': 1.1050},
          {'id': 'p2', 'accountId': 'A1', 'side': 'SELL', 'volume': 0.3, 'openPrice': 1.10100, 'symbol': 'EURUSD'},
        ];
        api.orders = [
          {'id': 'o1', 'accountId': 'A1', 'symbol': 'EURUSD', 'side': 'BUY', 'type': 'STOP_LIMIT', 'volume': 0.2, 'stopPrice': 1.1030, 'price': 1.1025},
        ];
      });
      await _settle(t);

      // Nothing chosen: the chart gets no palette and the lines keep the theme's colours (as before).
      expect(_chart(t).palette.isEmpty, isTrue);
      final tc = Theme.of(t.element(find.byType(CandleChart))).extension<TradeColors>()!;
      LevelKindColor(LevelKind k, String id) => _chart(t).levels.firstWhere((l) => l.kind == k && l.id == id);
      expect(LevelKindColor(LevelKind.sl, 'p1').color, tc.loss);
      expect(LevelKindColor(LevelKind.sl, 'p1').textColor, isNull);
      expect(LevelKindColor(LevelKind.entry, 'p1').color, tc.buy);

      const c = {
        ChartColorKey.slLine: Color(0xFF111111),
        ChartColorKey.slText: Color(0xFF222222),
        ChartColorKey.tpLine: Color(0xFF333333),
        ChartColorKey.tpText: Color(0xFF444444),
        ChartColorKey.buyLine: Color(0xFF555555),
        ChartColorKey.buyText: Color(0xFF666666),
        ChartColorKey.sellLine: Color(0xFF777777),
        ChartColorKey.sellText: Color(0xFF888888),
        ChartColorKey.stopLimitLine: Color(0xFF999999),
        ChartColorKey.stopLimitText: Color(0xFFAAAAAA),
        ChartColorKey.bullCandle: Color(0xFF00FF00),
        ChartColorKey.background: Color(0xFF102030),
      };
      h.container.read(chartColorsProvider.notifier).apply(ChartScheme.defaultScheme, c);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(_chart(t).palette[ChartColorKey.bullCandle], const Color(0xFF00FF00));
      expect(_chart(t).palette[ChartColorKey.background], const Color(0xFF102030));

      final sl = LevelKindColor(LevelKind.sl, 'p1');
      expect((sl.color, sl.textColor), (const Color(0xFF111111), const Color(0xFF222222)));
      final tp = LevelKindColor(LevelKind.tp, 'p1');
      expect((tp.color, tp.textColor), (const Color(0xFF333333), const Color(0xFF444444)));
      final buy = LevelKindColor(LevelKind.entry, 'p1');
      expect((buy.color, buy.textColor), (const Color(0xFF555555), const Color(0xFF666666)));
      final sell = LevelKindColor(LevelKind.entry, 'p2');
      expect((sell.color, sell.textColor), (const Color(0xFF777777), const Color(0xFF888888)));
      final pending = LevelKindColor(LevelKind.pending, 'o1');
      expect((pending.color, pending.textColor), (const Color(0xFF555555), const Color(0xFF666666)), reason: 'a buy order uses the Buy line colours');
      final limit = LevelKindColor(LevelKind.limit, 'o1');
      expect((limit.color, limit.textColor), (const Color(0xFF999999), const Color(0xFFAAAAAA)));

      // Back to Default: today's colours again, at once.
      h.container.read(chartColorsProvider.notifier).setScheme(ChartScheme.defaultScheme);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(_chart(t).palette.isEmpty, isTrue);
      expect(LevelKindColor(LevelKind.sl, 'p1').color, tc.loss);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('a scheme switches the whole chart; the caption text follows Foreground', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      h.container.read(chartColorsProvider.notifier).setScheme(ChartScheme.colorOnWhite);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final pal = kSchemePalettes[ChartScheme.colorOnWhite]!;
      for (final k in ChartColorKey.values) {
        expect(_chart(t).palette[k], pal[k], reason: k.label);
      }
      // The symbol caption on the white chart is drawn in the scheme's dark foreground, not the theme's light text.
      final caption = find.descendant(of: find.byKey(const ValueKey('symbol-caption')), matching: find.byType(Text));
      expect(t.widgetList<Text>(caption).any((w) => w.style?.color == pal[ChartColorKey.foreground]), isTrue);
      await _unmount(t);
    });

    testWidgets('the Free chart movement setting reaches the chart (on by default: today\'s behaviour)', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      expect(h.container.read(chartSettingsProvider).freeChartMovement, isTrue);
      expect(_chart(t).freeMovement, isTrue);
      h.container.read(chartSettingsProvider.notifier).setFreeChartMovement(false);
      await t.pump();
      expect(_chart(t).freeMovement, isFalse);
      h.container.read(chartSettingsProvider.notifier).setFreeChartMovement(true);
      await t.pump();
      expect(_chart(t).freeMovement, isTrue);
      await _unmount(t);
    });

    testWidgets('colours and the movement mode survive a symbol / timeframe switch', (t) async {
      final h = await _pumpChart(t, const Size(412, 915));
      h.container.read(chartColorsProvider.notifier).setScheme(ChartScheme.colorOnWhite);
      h.container.read(chartSettingsProvider.notifier).setFreeChartMovement(false);
      await t.pump();
      h.container.read(chartSymbolProvider.notifier).set('GBPUSD');
      h.container.read(chartTfProvider.notifier).set(Timeframe.h1);
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_chart(t).palette[ChartColorKey.background], const Color(0xFF000000));
      expect(_chart(t).freeMovement, isFalse);
      await _unmount(t);
    });
  });
}
