import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// History is opened, left, a trade is placed and CLOSED while History is not on screen, then History
/// is opened again. The rows it already has must be on screen at once (no full-screen loader), the
/// refetch runs behind them, and the newly closed trade appears without a manual refresh. A loader is
/// only for a genuine first load.
class _Api extends ApiClient {
  _Api() : super(AuthStore());
  Completer<void>? gate;
  int calls = 0;
  final deals = <Map<String, dynamic>>[_deal('d1', 5)];

  static Map<String, dynamic> _deal(String id, num profit) => {
        'id': id, 'type': 'CLOSE', 'side': 'BUY', 'volume': 0.1, 'price': 1.1, 'profit': profit, 'swap': 0, 'commission': 0,
        'balanceAfter': 10000, 'createdAt': DateTime.now().toIso8601String(), 'symbol': 'EURUSD', 'digits': 5,
        'openPrice': 1.09, 'positionId': 'p-$id', 'ticket': 'p-$id', 'amount': profit,
      };

  void closeTrade(String id, num profit) => deals.insert(0, _deal(id, profit));

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/history/deals') {
      calls++;
      final snapshot = [...deals]; // what the server holds when the request is made
      if (gate != null) await gate!.future;
      return snapshot;
    }
    return <dynamic>[];
  }
}

Future<ProviderContainer> _mount(WidgetTester t, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  t.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: home),
    );

bool _spinner(WidgetTester t) => find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets('reopening History after a trade closed elsewhere: rows at once, no loader, new trade appears', (t) async {
    final api = _Api();
    final c = await _mount(t, api);

    // 1. History opened once: its rows load.
    await t.pumpWidget(_app(c, const HistoryScreen()));
    await _settle(t);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final firstCalls = api.calls;

    // 2. The user leaves History, places a trade and closes it (the socket bumps the trade-event
    //    counter - once for the fill, once for the close). The server's refetch is slow.
    await t.pumpWidget(_app(c, const Scaffold(body: Text('Trade tab'))));
    api.closeTrade('d2', 12);
    api.gate = Completer<void>();
    c.read(tradeEventEpochProvider.notifier).state++;
    c.read(tradeEventEpochProvider.notifier).state++;
    await _settle(t);

    // 3. History is opened again straight away, while the refetch is still in flight.
    await t.pumpWidget(_app(c, const HistoryScreen()));
    var spinnerFrames = 0;
    var rowsVisible = 0;
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 16));
      if (_spinner(t)) spinnerFrames++;
      if (find.textContaining('EURUSD').evaluate().isNotEmpty) rowsVisible++;
    }
    expect(spinnerFrames, 0, reason: 'a full-screen loader showed on $spinnerFrames frames although history was already loaded');
    expect(rowsVisible, 12, reason: 'the existing rows must be on screen from the first frame');

    // 4. The refetch lands: the newly closed trade shows up, still without a loader.
    api.gate!.complete();
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 30));
      if (_spinner(t)) spinnerFrames++;
    }
    expect(spinnerFrames, 0);
    expect(find.text('12.00'), findsWidgets, reason: 'the trade closed meanwhile appears without a manual refresh');
    expect(api.calls, greaterThan(firstCalls), reason: 'it was refetched in the background');
  });

  testWidgets('a genuine first load (nothing loaded yet) still shows a loader', (t) async {
    final api = _Api()..gate = Completer<void>();
    final c = await _mount(t, api);
    await t.pumpWidget(_app(c, const HistoryScreen()));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.gate!.complete();
    await _settle(t);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('EURUSD'), findsWidgets);
  });

  testWidgets('a real error is still shown (not hidden behind the old rows forever)', (t) async {
    final api = _Api();
    final c = await _mount(t, api);
    await t.pumpWidget(_app(c, const HistoryScreen()));
    await _settle(t);
    expect(find.textContaining('EURUSD'), findsWidgets);
    // history was loaded; now the next fetch fails
    final failing = Completer<void>();
    api.gate = failing;
    await t.pumpWidget(_app(c, const Scaffold(body: Text('Trade tab'))));
    c.read(tradeEventEpochProvider.notifier).state++;
    await _settle(t);
    await t.pumpWidget(_app(c, const HistoryScreen()));
    failing.completeError(Exception('boom'));
    await _settle(t);
    expect(find.textContaining('boom'), findsOneWidget, reason: 'a genuine failure is shown, not hidden');
  });
}
