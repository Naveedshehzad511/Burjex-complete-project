import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:burjex_portal/widgets/pending_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SL / TP are toggles: unset -> click sets it, set -> click removes it. The state shown comes
/// from the API (an existing order / position starts active when the server has the level), the
/// change is saved at once for an existing order / position (only that field is sent), and a
/// backend refusal puts the previous state back.

const _q = Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0);

/// What a Dio error looks like to the app's `_errMessage`: `response.data['message']`.
class _Resp {
  _Resp(this.data);
  final dynamic data;
}

class _Refused implements Exception {
  _Refused(String m) : response = _Resp({'message': m});
  final _Resp response;
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(AuthStore());
  final patches = <(String, Map<String, dynamic>)>[];
  final posts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> positions = [];
  List<Map<String, dynamic>> orders = [];

  /// When set, the next PATCH is refused with this message.
  String? refuseNext;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/market/candles') {
      final tf = '${query?['tf']}';
      final step = Timeframe.values.firstWhere((t) => t.api == tf).seconds;
      final end = (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ step * step - step;
      return [
        for (var i = 199; i >= 0; i--) {'t': end - i * step, 'o': 1.1, 'h': 1.1004, 'l': 1.0996, 'c': 1.1, 'v': 1}
      ];
    }
    if (path == '/positions') return [...positions];
    if (path == '/orders') return [...orders];
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    posts.add(Map<String, dynamic>.from(body as Map));
    return {'accepted': true, 'orderId': 'o-new', 'status': 'PENDING'};
  }

  @override
  Future<dynamic> patch(String path, [dynamic body]) async {
    if (refuseNext != null) {
      final m = refuseNext;
      refuseNext = null;
      throw _Refused(m!);
    }
    final b = Map<String, dynamic>.from(body as Map);
    patches.add((path, b));
    // The server applies exactly what it was sent (absent = keep, null = clear).
    for (final r in [...orders, ...positions]) {
      if (path.endsWith('/${r['id']}')) {
        for (final k in b.keys) {
          r[k] = b[k];
        }
      }
    }
    return <String, dynamic>{'ok': true};
  }
}

TradeSymbol _sym() => TradeSymbol.fromJson({
      'id': 'EURUSD',
      'symbol': 'EURUSD',
      'description': 'Euro',
      'class': 'CRYPTO',
      'digits': 5,
      'minLot': 0.01,
      'maxLot': 100,
      'lotStep': 0.01,
    });

late ProviderContainer _c;

Future<_FakeApi> _pump(WidgetTester t, Size size, {void Function(_FakeApi)? seed}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi();
  seed?.call(api);
  _c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    feedSubscriptionProvider.overrideWith((_) {}),
    accountsProvider.overrideWith((_) async => const <Account>[]),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => [_sym()]),
  ]);
  _c.read(quotesProvider.notifier).set(_q);
  await t.pumpWidget(UncontrolledProviderScope(
    container: _c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
  ));
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return api;
}

Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  _c.dispose();
  await t.pump(const Duration(seconds: 6)); // toasts / timers
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

CandleChart _chart(WidgetTester t) => t.widget<CandleChart>(find.byType(CandleChart));
Iterable<ChartLevel> _levels(WidgetTester t, String id, LevelKind k) => _chart(t).levels.where((l) => l.id == id && l.kind == k);

/// Whether the collapsed bar's SL / TP circle shows as set (filled), read from its decoration.
bool _filled(WidgetTester t, String label) {
  final box = t.widget<Container>(find.descendant(of: find.byKey(ValueKey('circle-$label')), matching: find.byType(Container)).first);
  return (box.decoration as BoxDecoration).color != null;
}

/// Every pending type, with a valid entry / SL / TP for the fixed quote (bid 1.10000 / ask 1.10020).
final _types = <String, Map<String, dynamic>>{
  'BUY_LIMIT': {'side': 'BUY', 'price': 1.0950, 'sl': 1.0900, 'tp': 1.1000},
  'SELL_LIMIT': {'side': 'SELL', 'price': 1.1050, 'sl': 1.1100, 'tp': 1.1000},
  'BUY_STOP': {'side': 'BUY', 'stopPrice': 1.1050, 'sl': 1.1000, 'tp': 1.1100},
  'SELL_STOP': {'side': 'SELL', 'stopPrice': 1.0950, 'sl': 1.1000, 'tp': 1.0900},
  'BUY_STOP_LIMIT': {'type': 'STOP_LIMIT', 'side': 'BUY', 'stopPrice': 1.1050, 'price': 1.1040, 'sl': 1.1000, 'tp': 1.1100},
  'SELL_STOP_LIMIT': {'type': 'STOP_LIMIT', 'side': 'SELL', 'stopPrice': 1.0950, 'price': 1.0960, 'sl': 1.1000, 'tp': 1.0900},
};

Map<String, dynamic> _order(String name, {bool withSl = true, bool withTp = true}) {
  final t = _types[name]!;
  return {
    'id': 'o-$name',
    'accountId': 'A1',
    'symbol': 'EURUSD',
    'side': t['side'],
    'type': t['type'] ?? name,
    'volume': 0.2,
    if (t['price'] != null) 'price': t['price'],
    if (t['stopPrice'] != null) 'stopPrice': t['stopPrice'],
    'slPrice': withSl ? t['sl'] : null,
    'tpPrice': withTp ? t['tp'] : null,
  };
}

Future<void> _openOrder(WidgetTester t, String id) async {
  final lvl = _chart(t).levels.firstWhere((l) => l.id == id && l.kind == LevelKind.pending);
  _chart(t).onLevelTap!(lvl);
  await t.pump();
  expect(find.byKey(const ValueKey('circle-SL')), findsOneWidget);
}

void main() {
  for (final size in const [Size(390, 844), Size(820, 1180), Size(1366, 768)]) {
    group('SL / TP toggle on existing pending orders ${size.width.toInt()}x${size.height.toInt()}', () {
      for (final name in _types.keys) {
        testWidgets('$name: starts from the API, removes then sets SL and TP', (t) async {
          final api = await _pump(t, size, seed: (a) => a.orders = [_order(name)]);
          final id = 'o-$name';
          await _settle(t);
          // Both levels exist on the server -> both lines are on the chart and both buttons active.
          expect(_levels(t, id, LevelKind.sl), hasLength(1));
          expect(_levels(t, id, LevelKind.tp), hasLength(1));
          await _openOrder(t, id);
          expect(_filled(t, 'SL'), isTrue);
          expect(_filled(t, 'TP'), isTrue);

          // SL: click -> removed (server told, line and button follow at once)...
          await t.tap(find.byKey(const ValueKey('circle-SL')));
          await _settle(t);
          expect(api.patches.last.$1, '/orders/$id');
          expect(api.patches.last.$2, {'slPrice': null}, reason: 'only SL is sent');
          expect(_levels(t, id, LevelKind.sl), isEmpty);
          expect(_filled(t, 'SL'), isFalse);
          expect(_filled(t, 'TP'), isTrue, reason: 'TP untouched');
          // ...click again -> set again (a dynamic level next to the order, sent to the server).
          await t.tap(find.byKey(const ValueKey('circle-SL')));
          await _settle(t);
          final setSl = api.patches.last;
          expect(setSl.$1, '/orders/$id');
          expect(setSl.$2.keys, ['slPrice']);
          expect(setSl.$2['slPrice'], isA<double>());
          expect(_levels(t, id, LevelKind.sl), hasLength(1));
          expect(_levels(t, id, LevelKind.sl).single.price, setSl.$2['slPrice']);
          expect(_filled(t, 'SL'), isTrue);

          // TP: same, independently.
          await t.tap(find.byKey(const ValueKey('circle-TP')));
          await _settle(t);
          expect(api.patches.last.$1, '/orders/$id');
          expect(api.patches.last.$2, {'tpPrice': null});
          expect(_levels(t, id, LevelKind.tp), isEmpty);
          expect(_filled(t, 'TP'), isFalse);
          await t.tap(find.byKey(const ValueKey('circle-TP')));
          await _settle(t);
          expect(api.patches.last.$2.keys, ['tpPrice']);
          expect(api.patches.last.$2['tpPrice'], isA<double>());
          expect(_levels(t, id, LevelKind.tp), hasLength(1));
          expect(_filled(t, 'TP'), isTrue);
          // The order itself (price / stop / type) was never touched by any toggle.
          final srv = api.orders.single;
          expect(srv['type'], _types[name]!['type'] ?? name);
          expect(srv['price'], _types[name]!['price']);
          expect(srv['stopPrice'], _types[name]!['stopPrice']);
          await _unmount(t);
        });
      }

      testWidgets('an order with no SL / TP on the server starts inactive and sets them', (t) async {
        final api = await _pump(t, size, seed: (a) => a.orders = [_order('BUY_LIMIT', withSl: false, withTp: false)]);
        await _settle(t);
        expect(_levels(t, 'o-BUY_LIMIT', LevelKind.sl), isEmpty);
        await _openOrder(t, 'o-BUY_LIMIT');
        expect(_filled(t, 'SL'), isFalse);
        expect(_filled(t, 'TP'), isFalse);
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await _settle(t);
        expect(api.patches.single.$2.keys, ['slPrice']);
        expect(_filled(t, 'SL'), isTrue);
        expect(_filled(t, 'TP'), isFalse);
        await _unmount(t);
      });

      testWidgets('a refused removal keeps SL, shows the reason, and the next click works', (t) async {
        final api = await _pump(t, size, seed: (a) => a.orders = [_order('SELL_STOP')]);
        await _settle(t);
        await _openOrder(t, 'o-SELL_STOP');
        api.refuseNext = 'stop loss too close to market';
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await _settle(t);
        expect(api.patches, isEmpty);
        expect(_filled(t, 'SL'), isTrue, reason: 'the server still has the SL, so the button must show it');
        expect(_levels(t, 'o-SELL_STOP', LevelKind.sl), hasLength(1));
        expect(find.text('stop loss too close to market'), findsOneWidget, reason: 'the backend reason is shown');
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await _settle(t);
        expect(api.patches.single.$2, {'slPrice': null});
        expect(_filled(t, 'SL'), isFalse);
        await _unmount(t);
      });

      testWidgets('a refused set leaves TP unset', (t) async {
        final api = await _pump(t, size, seed: (a) => a.orders = [_order('BUY_STOP', withTp: false)]);
        await _settle(t);
        await _openOrder(t, 'o-BUY_STOP');
        api.refuseNext = 'rejected';
        await t.tap(find.byKey(const ValueKey('circle-TP')));
        await _settle(t);
        expect(_filled(t, 'TP'), isFalse);
        expect(_levels(t, 'o-BUY_STOP', LevelKind.tp), isEmpty);
        expect(api.orders.single['tpPrice'], isNull);
        expect(find.text('rejected'), findsOneWidget, reason: 'the backend reason is shown');
        await _unmount(t);
      });

      testWidgets('open position: removes and sets SL / TP through /positions', (t) async {
        final api = await _pump(t, size, seed: (a) {
          a.positions = [
            {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.5, 'openPrice': 1.0995, 'slPrice': 1.0900, 'tpPrice': 1.1100, 'symbol': {'symbol': 'EURUSD', 'digits': 5}, 'openedAt': DateTime.now().toIso8601String()},
          ];
        });
        await _settle(t);
        _chart(t).onLevelTap!(_chart(t).levels.firstWhere((l) => l.id == 'p1' && l.kind == LevelKind.entry));
        await t.pump();
        expect(_filled(t, 'SL'), isTrue);
        expect(_filled(t, 'TP'), isTrue);
        await t.tap(find.byKey(const ValueKey('circle-TP')));
        await _settle(t);
        expect(api.patches.last.$1, '/positions/p1');
        expect(api.patches.last.$2, {'tpPrice': null});
        expect(_levels(t, 'p1', LevelKind.tp), isEmpty);
        expect(_levels(t, 'p1', LevelKind.sl), hasLength(1), reason: 'SL untouched');
        await t.tap(find.byKey(const ValueKey('circle-TP')));
        await _settle(t);
        expect(api.patches.last.$2['tpPrice'], isA<double>());
        expect(_levels(t, 'p1', LevelKind.tp), hasLength(1));
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await _settle(t);
        expect(api.patches.last.$1, '/positions/p1');
        expect(api.patches.last.$2, {'slPrice': null});
        expect(_filled(t, 'SL'), isFalse);
        await _unmount(t);
      });
    });
  }

  group('SL / TP toggle while placing a new pending order', () {
    for (final mode in OrderMode.values.where((m) => !m.isMarket)) {
      testWidgets('${mode.label}: set / remove locally, nothing sent until Place', (t) async {
        final api = await _pump(t, const Size(390, 844));
        await t.tap(find.byTooltip('New order'));
        await t.pump();
        await t.ensureVisible(find.text(mode.label));
        await t.tap(find.text(mode.label));
        await t.pumpAndSettle();
        expect(_filled(t, 'SL'), isFalse);
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await t.pump();
        expect(_levels(t, 'draft', LevelKind.sl), hasLength(1));
        expect(_filled(t, 'SL'), isTrue);
        await t.tap(find.byKey(const ValueKey('circle-TP')));
        await t.pump();
        expect(_filled(t, 'TP'), isTrue);
        await t.tap(find.byKey(const ValueKey('circle-SL')));
        await t.pump();
        expect(_levels(t, 'draft', LevelKind.sl), isEmpty);
        expect(_filled(t, 'SL'), isFalse);
        await t.tap(find.byKey(const ValueKey('circle-TP')));
        await t.pump();
        expect(_levels(t, 'draft', LevelKind.tp), isEmpty);
        expect(api.patches, isEmpty);
        expect(api.posts, isEmpty, reason: 'toggling never places an order');
        await _unmount(t);
      });
    }

    testWidgets('a removed SL is not sent with the order; a kept one is', (t) async {
      final api = await _pump(t, const Size(390, 844));
      await t.tap(find.byTooltip('New order'));
      await t.pump();
      await t.ensureVisible(find.text('Buy Limit'));
      await t.tap(find.text('Buy Limit'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('circle-SL')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('circle-TP')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('circle-SL'))); // remove SL again
      await t.pump();
      final place = find.textContaining('Place Buy Limit');
      await t.ensureVisible(place);
      await t.tap(place);
      await _settle(t);
      expect(api.posts, hasLength(1));
      expect(api.posts.single.containsKey('slPrice'), isFalse);
      expect(api.posts.single['tpPrice'], isA<double>());
      await _unmount(t);
    });
  });

  group('panel contract', () {
    testWidgets('the circles reflect the edit and call add / remove once each', (t) async {
      final log = <String>[];
      final e = ChartEdit.order(id: 'o1', orderType: 'BUY_LIMIT', side: 'BUY', entry: 99, sl: 95, volume: 0.2);
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.light(Branding.fallback),
        home: Scaffold(
          body: PendingPanel(
            edit: e,
            symbolLabel: 'X',
            digits: 2,
            quote: const Tick(symbol: 'X', bid: 100, ask: 100.5, ts: 0),
            minLot: 0.01,
            maxLot: 100,
            lotStep: 0.01,
            busy: false,
            serverError: null,
            expanded: false,
            onChanged: () {},
            onPickType: (_) {},
            onAddSl: () => log.add('addsl'),
            onAddTp: () => log.add('addtp'),
            onRemoveSl: () => log.add('removesl'),
            onRemoveTp: () => log.add('removetp'),
            onApply: () {},
            onClose: () {},
            onCancelOrder: () {},
          ),
        ),
      ));
      await t.tap(find.byKey(const ValueKey('circle-SL'))); // set -> remove
      await t.tap(find.byKey(const ValueKey('circle-TP'))); // unset -> add
      expect(log, ['removesl', 'addtp']);
    });
  });
}
