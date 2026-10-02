import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/history_screen.dart';
import 'package:burjex_portal/screens/trade_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Close all" on the Trade tab: the trades close, and the refresh that follows must never put
/// a loader on the Positions list (the old rows stay until the new list replaces them).
class _FakeApi extends ApiClient {
  _FakeApi() : super(AuthStore());
  bool closed = false;
  Completer<void>? historyGate;
  final closeAll = Completer<void>();
  Completer<void>? positionsGate;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/accounts/me') {
      return [
        {'id': 'A1', 'login': '500001', 'type': 'LIVE', 'status': 'ACTIVE', 'currency': 'USD', 'leverage': 100, 'balance': 10000, 'equity': 10000, 'margin': 0, 'freeMargin': 10000, 'marginLevel': 0, 'floatingPL': 0}
      ];
    }
    if (path == '/positions') {
      final snapshot = closed;
      if (snapshot && positionsGate != null) await positionsGate!.future;
      if (snapshot) return <dynamic>[];
      return [
        for (var i = 0; i < 20; i++)
          {'id': 'p$i', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.1, 'openPrice': 1.1, 'symbol': {'symbol': 'EURUSD', 'digits': 5}, 'openedAt': DateTime.now().toIso8601String()}
      ];
    }
    if (path == '/history/deals') {
      if (historyGate != null) await historyGate!.future;
      return [
        {'id': 'd1', 'type': 'CLOSE', 'side': 'BUY', 'volume': 0.1, 'price': 1.1, 'profit': 5, 'swap': 0, 'commission': 0, 'balanceAfter': 10005, 'createdAt': DateTime.now().toIso8601String(), 'symbol': 'EURUSD', 'digits': 5, 'openPrice': 1.09, 'positionId': 'p1', 'ticket': 'p1', 'amount': 5}
      ];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    if (path.endsWith('/close-all')) {
      await closeAll.future;
      closed = true;
    }
    return <String, dynamic>{};
  }
}

void main() {
  testWidgets('Close all never shows a loader on the positions list', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = _FakeApi();
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
    expect(find.textContaining('buy 0.10'), findsWidgets);

    var spinnerFrames = 0;
    Future<void> frame([int ms = 16]) async {
      await t.pump(Duration(milliseconds: ms));
      if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) spinnerFrames++;
    }

    await t.tap(find.byTooltip('Positions menu'));
    await t.pumpAndSettle();
    await t.tap(find.text('Close all positions'));
    for (var i = 0; i < 5; i++) {
      await frame();
    }
    // The server has closed them (the WS "closed" push for each id arrives around now).
    api.positionsGate = Completer<void>();
    api.closeAll.complete();
    for (var i = 0; i < 20; i++) {
      // What the socket's "closed" push does (live.dart): mark closed, then refresh, coalesced.
      c.read(closedPositionIdsProvider.notifier).add('p$i');
      c.read(positionsRefreshProvider).request();
      c.read(accountsRefreshProvider).request();
      await frame();
    }
    for (var i = 0; i < 10; i++) {
      await frame(30);
    }
    api.positionsGate!.complete();
    for (var i = 0; i < 10; i++) {
      await frame(30);
    }
    expect(spinnerFrames, 0, reason: 'a loader was shown on $spinnerFrames frames');
    expect(find.text('No open positions.'), findsOneWidget);
  });

  testWidgets('History keeps its rows while it refetches after each close (no loader)', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = _FakeApi();
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      marketSocketProvider.overrideWith((_) => null),
    ]);
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const HistoryScreen()),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Close-all: the socket reports each closed trade, History refetches (slowly) every time.
    api.historyGate = Completer<void>();
    var spinnerFrames = 0;
    for (var i = 0; i < 20; i++) {
      c.read(tradeEventEpochProvider.notifier).state++;
      await t.pump(const Duration(milliseconds: 16));
      if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) spinnerFrames++;
    }
    api.historyGate!.complete();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 30));
      if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) spinnerFrames++;
    }
    expect(spinnerFrames, 0, reason: 'History showed a loader on $spinnerFrames frames');
  });
}
