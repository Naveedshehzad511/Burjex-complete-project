import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:burjex_portal/widgets/pending_panel.dart';
import 'dart:io';

import 'package:burjex_portal/services/sound_service.dart';
import 'package:burjex_portal/widgets/radial_chart_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// (fake api reused)
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
  debugDefaultTargetPlatformOverride = null; // must be unset before the framework's end-of-test checks
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


/// Success sound = the "modified" pulse; failure = the error pulse. Counted through the haptic bridge.
final _pulses = <List<int>>[];
int get _modified => _pulses.where((p) => p.length == 2 && p[1] == 40).length;
int get _errors => _pulses.where((p) => p.length == 4).length;

Map<String, dynamic> _pos({double? sl}) => {
      'id': 'p1', 'accountId': 'A1', 'symbol': 'EURUSD', 'side': 'BUY', 'status': 'OPEN', 'volume': 0.1,
      'openPrice': 1.0990, 'slPrice': sl, 'tpPrice': null, 'profit': 0, 'swap': 0, 'openedAt': DateTime.now().toIso8601String(),
    };

Future<void> _openOrder(WidgetTester t, String id) async {
  final lvl = _chart(t).levels.firstWhere((l) => l.id == id && l.kind == LevelKind.pending);
  _chart(t).onLevelTap!(lvl);
  await t.pump();
  expect(find.byKey(const ValueKey('circle-SL')), findsOneWidget);
}

Future<void> _openPos(WidgetTester t) async {
  final lvl = _chart(t).levels.firstWhere((l) => l.id == 'p1' && l.kind == LevelKind.entry);
  _chart(t).onLevelTap!(lvl);
  await t.pump();
  expect(find.byType(PendingPanel), findsOneWidget);
}

Future<void> _tapEmptyChart(WidgetTester t) async {
  final r = t.getRect(find.byType(CandleChart));
  await t.tapAt(Offset(r.left + 60, r.top + r.height * 0.3));
  await t.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (c) async => null);
  m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async => Directory.systemTemp.path);

  setUp(() {
    _pulses.clear();
    SoundService.instance.resetForTest();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    m.setMockMethodCallHandler(SoundService.haptics, (call) async {
      _pulses.add([for (final n in (call.arguments as Map)['pattern'] as List) n as int]);
      return true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    m.setMockMethodCallHandler(SoundService.haptics, null);
  });

  const size = Size(390, 844);

  testWidgets('opening the card and toggling SL on it makes no success sound; Apply plays it once', (t) async {
    final api = await _pump(t, size, seed: (a) => a.positions = [_pos()]);
    await _settle(t);
    await _openPos(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(_pulses, isEmpty, reason: 'opening the SL / TP card is silent');

    await t.tap(find.byKey(const ValueKey('circle-SL')));
    await _settle(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(api.patches, isNotEmpty, reason: 'the existing save-on-toggle is unchanged');
    expect(_modified, 0, reason: 'toggling SL on the open card is not "applied"');

    await t.tap(find.text('Apply'));
    await _settle(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(_modified, 1, reason: 'Apply plays the existing sound exactly once');
    expect(_errors, 0);
    await _unmount(t);
  });

  testWidgets('a refused Apply plays no success sound', (t) async {
    final api = await _pump(t, size, seed: (a) => a.positions = [_pos(sl: 1.0900)]);
    await _settle(t);
    await _openPos(t);
    api.refuseNext = 'Invalid stops';
    await t.tap(find.text('Apply'));
    await _settle(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(_modified, 0);
    expect(_errors, 1, reason: 'the existing error sound, not the success one');
    await _unmount(t);
  });

  testWidgets('tapping empty chart closes a position card without saving, and the round menu opens', (t) async {
    final api = await _pump(t, size, seed: (a) => a.positions = [_pos(sl: 1.0900)]);
    await _settle(t);
    await _openPos(t);
    await _tapEmptyChart(t);
    expect(find.byType(PendingPanel), findsNothing, reason: 'the card closes at once');
    expect(find.byType(RadialChartMenu), findsOneWidget, reason: 'the round menu appears without pressing Apply');
    expect(api.patches, isEmpty, reason: 'dismissing sends nothing');
    expect(_pulses, isEmpty);
    await _unmount(t);
  });

  testWidgets('same for a pending-order card; tapping a line keeps the card; Apply still saves', (t) async {
    final api = await _pump(t, size, seed: (a) => a.orders = [_order('BUY_LIMIT')]);
    await _settle(t);
    await _openOrder(t, 'o-BUY_LIMIT');
    // a tap that lands on a line is a line tap, not a dismissal
    final lvl = _chart(t).levels.firstWhere((l) => l.id == 'o-BUY_LIMIT' && l.kind == LevelKind.pending);
    _chart(t).onLevelTap!(lvl);
    await t.pump();
    expect(find.byType(PendingPanel), findsOneWidget);

    await t.tap(find.text('Apply changes'));
    await _settle(t);
    expect(api.patches.any((p) => p.$1 == '/orders/o-BUY_LIMIT'), isTrue, reason: 'Apply still saves');
    await _unmount(t);

    final api2 = await _pump(t, size, seed: (a) => a.orders = [_order('BUY_LIMIT')]);
    await _settle(t);
    await _openOrder(t, 'o-BUY_LIMIT');
    await _tapEmptyChart(t);
    expect(find.byType(PendingPanel), findsNothing);
    expect(find.byType(RadialChartMenu), findsOneWidget);
    expect(api2.patches, isEmpty);
    await _unmount(t);
  });
}
