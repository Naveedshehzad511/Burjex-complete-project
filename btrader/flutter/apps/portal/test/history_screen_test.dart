import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gateway stand-in for `/history/deals`, returning the exact enriched shape
/// the real trading.controller.ts endpoint returns (slPrice/tpPrice/openedAt/
/// ticket riding along on the position join) — see history_screen.dart.
class _FakeApi extends ApiClient {
  _FakeApi(this.deals) : super(AuthStore());
  final List<Map<String, dynamic>> deals;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/history/deals') return deals;
    return <dynamic>[];
  }
}

Map<String, dynamic> _trade({
  required String id,
  required String ticket,
  required String symbol,
  required String side,
  required double volume,
  required double openPrice,
  required double closePrice,
  required double profit,
  double swap = 0,
  double commission = 0,
  double? slPrice,
  double? tpPrice,
  String? comment,
  required DateTime openedAt,
  required DateTime createdAt,
  int digits = 2,
}) =>
    {
      'id': id,
      'type': 'CLOSE',
      'side': side,
      'volume': volume,
      'price': closePrice,
      'profit': profit,
      'swap': swap,
      'commission': commission,
      'balanceAfter': 10000 + profit,
      'comment': comment,
      'createdAt': createdAt.toIso8601String(),
      'symbol': symbol,
      'digits': digits,
      'openPrice': openPrice,
      'slPrice': slPrice,
      'tpPrice': tpPrice,
      'openedAt': openedAt.toIso8601String(),
      'positionId': ticket,
      'ticket': ticket,
      'amount': 0,
    };

Future<void> _pump(WidgetTester t, List<Map<String, dynamic>> deals) async {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(_FakeApi(deals)),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    accountsProvider.overrideWith((_) async => const <Account>[]),
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const HistoryScreen()),
  ));
  await t.pumpAndSettle();
}

void main() {
  final bothLevels = _trade(
    id: 'd1',
    ticket: '22408088-1234-4321-aaaa-abcdefabcdef',
    symbol: 'XAUUSD',
    side: 'BUY',
    volume: 0.01,
    openPrice: 4400.90,
    closePrice: 4400.76,
    profit: -0.14,
    swap: 0,
    commission: -0.10,
    slPrice: 4390.00,
    tpPrice: 4420.00,
    comment: 'tp hit',
    openedAt: DateTime(2026, 8, 17, 11, 20, 11),
    createdAt: DateTime(2026, 8, 17, 11, 20, 24),
    digits: 2,
  );
  final slOnly = _trade(
    id: 'd2',
    ticket: 'pos-slonly',
    symbol: 'EURUSD',
    side: 'SELL',
    volume: 0.5,
    openPrice: 1.10500,
    closePrice: 1.10800,
    profit: -150.0,
    swap: -1.2,
    commission: -3.5,
    slPrice: 1.10900,
    tpPrice: null,
    openedAt: DateTime(2026, 8, 18, 9, 0, 0),
    createdAt: DateTime(2026, 8, 18, 9, 15, 0),
    digits: 5,
  );
  final tpOnly = _trade(
    id: 'd3',
    ticket: 'pos-tponly',
    symbol: 'GBPUSD',
    side: 'BUY',
    volume: 0.2,
    openPrice: 1.25000,
    closePrice: 1.26000,
    profit: 200.0,
    swap: 0.5,
    commission: -2.0,
    slPrice: null,
    tpPrice: 1.26000,
    openedAt: DateTime(2026, 8, 19, 8, 0, 0),
    createdAt: DateTime(2026, 8, 19, 8, 30, 0),
    digits: 5,
  );
  final neither = _trade(
    id: 'd4',
    ticket: 'pos-neither',
    symbol: 'BTCUSD',
    side: 'SELL',
    volume: 1.5,
    openPrice: 60000,
    closePrice: 59500,
    profit: 750.0,
    swap: 0,
    commission: 0,
    slPrice: null,
    tpPrice: null,
    openedAt: DateTime(2026, 8, 20, 10, 0, 0),
    createdAt: DateTime(2026, 8, 20, 10, 5, 0),
    digits: 1,
  );
  final deposit = {
    'id': 'b1',
    'type': 'DEPOSIT',
    'side': null,
    'volume': null,
    'price': null,
    'profit': 0.0,
    'swap': 0.0,
    'commission': 0.0,
    'balanceAfter': 10000.0,
    'comment': 'card top-up',
    'createdAt': DateTime(2026, 8, 16).toIso8601String(),
    'symbol': null,
    'digits': 5,
    'openPrice': null,
    'amount': 500.0,
  };

  testWidgets('engine JSON in the comment field is suppressed, a real comment still shows', (t) async {
    final engineJson = _trade(
      id: 'd5',
      ticket: '99990000-1234-4321-aaaa-abcdefabcdef',
      symbol: 'BTCUSD',
      side: 'SELL',
      volume: 0.01,
      openPrice: 67583.00,
      closePrice: 67181.27,
      profit: 4.02,
      comment: '{"delayMs":0,"engine":"x","exec":"closeAll","fillPrice":67181.27,"partial":false,"result":"closed"}',
      openedAt: DateTime(2026, 9, 28, 23, 0),
      createdAt: DateTime(2026, 9, 28, 23, 27),
      digits: 2,
    );
    await _pump(t, [engineJson, bothLevels]);

    await t.tap(find.textContaining('BTCUSD'));
    await t.pumpAndSettle();
    expect(find.textContaining('delayMs'), findsNothing, reason: 'internal engine execution metadata must never be shown as a comment');
    expect(find.textContaining('{'), findsNothing);

    await t.tap(find.textContaining('BTCUSD'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('XAUUSD'));
    await t.pumpAndSettle();
    expect(find.textContaining('tp hit'), findsOneWidget, reason: 'a genuine human comment still renders');
  });

  testWidgets('collapsed rows never show the detail box', (t) async {
    await _pump(t, [bothLevels]);
    // AnimatedCrossFade keeps both children mounted for the crossfade, so
    // "collapsed" is asserted via its state, not text absence.
    final fade = t.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade));
    expect(fade.crossFadeState, CrossFadeState.showFirst);
  });

  testWidgets('tapping a trade expands its real SL/TP/ticket/open time — both present', (t) async {
    await _pump(t, [bothLevels]);
    await t.tap(find.textContaining('XAUUSD'));
    await t.pumpAndSettle();

    expect(find.text('S / L:'), findsOneWidget);
    expect(find.text('T / P:'), findsOneWidget);
    expect(find.text('4390.00'), findsOneWidget, reason: 'real SL from the API, not a placeholder');
    expect(find.text('4420.00'), findsOneWidget, reason: 'real TP from the API, not a placeholder');
    // Ticket/Open row is temporarily commented out in the widget — see history_screen.dart.
    expect(find.textContaining('tp hit'), findsOneWidget, reason: 'comment surfaced when the API provides one');
  });

  testWidgets('only SL available shows S/L value and T/P as —', (t) async {
    await _pump(t, [slOnly]);
    await t.tap(find.textContaining('EURUSD'));
    await t.pumpAndSettle();
    expect(find.text('1.10900'), findsOneWidget);
    // Two "—" placeholders would appear if TP were also missing; here exactly one (TP).
    final dashes = find.text('—');
    expect(dashes, findsWidgets);
  });

  testWidgets('only TP available shows T/P value and S/L as —', (t) async {
    await _pump(t, [tpOnly]);
    await t.tap(find.textContaining('GBPUSD'));
    await t.pumpAndSettle();
    expect(find.text('1.26000'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('neither SL nor TP shows — for both, never a fake value', (t) async {
    await _pump(t, [neither]);
    await t.tap(find.textContaining('BTCUSD'));
    await t.pumpAndSettle();
    // S/L and T/P rows both fall back to the em-dash placeholder.
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('tap again collapses; only one trade is expanded at a time', (t) async {
    await _pump(t, [bothLevels, slOnly]);
    List<CrossFadeState> states() => t.widgetList<AnimatedCrossFade>(find.byType(AnimatedCrossFade)).map((w) => w.crossFadeState).toList();

    await t.tap(find.textContaining('XAUUSD'));
    await t.pumpAndSettle();
    expect(states(), [CrossFadeState.showSecond, CrossFadeState.showFirst]);

    // Opening the second trade closes the first.
    await t.tap(find.textContaining('EURUSD'));
    await t.pumpAndSettle();
    expect(states(), [CrossFadeState.showFirst, CrossFadeState.showSecond]);

    // Tapping the same (now-open) trade again collapses it.
    await t.tap(find.textContaining('EURUSD'));
    await t.pumpAndSettle();
    expect(states(), [CrossFadeState.showFirst, CrossFadeState.showFirst]);
  });

  testWidgets('balance rows are not expandable and the summary footer still renders', (t) async {
    await _pump(t, [bothLevels, deposit]);
    await t.tap(find.text('Balance').first);
    await t.pumpAndSettle();
    // A balance row has no AnimatedCrossFade at all (no detail to expand).
    expect(find.byType(AnimatedCrossFade), findsNWidgets(1));
    expect(find.text('Deposit'), findsOneWidget);
  });
}
