import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/trade_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Close from the Trade tab: once the server confirms, the row is gone and the figures match on the same
/// frame - however slow the positions reload that follows is. A close the server refuses keeps the row.
class _FakeApi extends ApiClient {
  _FakeApi({required this.closeFails}) : super(AuthStore());
  final bool closeFails;
  bool closed = false;
  Completer<void>? positionsGate;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/accounts/me') {
      return [
        {'id': 'A1', 'login': '500001', 'type': 'LIVE', 'status': 'ACTIVE', 'currency': 'USD', 'leverage': 100, 'balance': 10000, 'equity': 10000, 'margin': 110, 'freeMargin': 9890, 'marginLevel': 0, 'floatingPL': 0}
      ];
    }
    if (path == '/positions') {
      final snapshot = closed;
      if (positionsGate != null) await positionsGate!.future;
      if (snapshot) return <dynamic>[];
      return [
        {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.1, 'openPrice': 1.1, 'profit': 50, 'symbol': {'symbol': 'EURUSD', 'digits': 5}, 'openedAt': DateTime.now().toIso8601String()}
      ];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    if (path == '/positions/p1/close') {
      if (closeFails) throw Exception('market closed');
      closed = true;
      return {
        'accepted': true, 'positionId': 'p1', 'status': 'FILLED', 'fillPrice': 1.105, 'filledVolume': 0.1,
        'account': {'accountId': 'A1', 'balance': 10050, 'credit': 0, 'equity': 10050, 'margin': 0, 'freeMargin': 10050,
          'marginLevel': 0, 'floatingPL': 0, 'currency': 'USD', 'leverage': 100, 'ts': DateTime.now().millisecondsSinceEpoch},
      };
    }
    return <String, dynamic>{};
  }
}

Future<(ProviderContainer, _FakeApi)> _open(WidgetTester t, {required bool closeFails}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi(closeFails: closeFails);
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => const <TradeSymbol>[]),
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const TradeScreen()),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(find.textContaining('buy 0.10'), findsOneWidget);
  return (c, api);
}

Future<void> _tapClose(WidgetTester t) async {
  await t.tap(find.textContaining('buy 0.10'));
  await t.pumpAndSettle();
  await t.tap(find.text('Close trade'));
}

String _row(WidgetTester t, String label) {
  final row = find.ancestor(of: find.text('$label:'), matching: find.byType(Row)).first;
  final texts = find.descendant(of: row, matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).toList();
  return texts.last ?? '';
}

void main() {
  testWidgets('a confirmed close removes the row at once, with matching figures, while the reload is slow', (t) async {
    final (_, api) = await _open(t, closeFails: false);
    api.positionsGate = Completer<void>(); // the reload after the close takes its time
    await _tapClose(t);
    await t.pump(); // the close answer
    await t.pump(const Duration(milliseconds: 16)); // one frame

    expect(find.textContaining('buy 0.10'), findsNothing, reason: 'the row must not wait for the reload');
    expect(find.text('No open positions.'), findsOneWidget);
    expect(_row(t, 'Balance'), mt5Money(10050));
    expect(_row(t, 'Equity'), mt5Money(10050), reason: 'the closed trade\'s P/L is not counted twice');
    expect(_row(t, 'Margin'), mt5Money(0));

    api.positionsGate!.complete();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('No open positions.'), findsOneWidget);
  });

  testWidgets('a close the server refuses keeps the row and says so', (t) async {
    final (c, _) = await _open(t, closeFails: true);
    await _tapClose(t);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('buy 0.10'), findsOneWidget);
    expect(find.text('Close failed'), findsOneWidget);
    expect(c.read(closedPositionIdsProvider), isEmpty);
    expect(_row(t, 'Balance'), mt5Money(10000));
    await t.pump(const Duration(seconds: 10)); // let the SnackBar go
    await t.pumpAndSettle();
  });
}
