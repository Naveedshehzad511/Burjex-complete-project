import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/trade_screen.dart';
import 'package:burjex_portal/state/bulk_close.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MT5 bulk operations on the Trade tab's "..." menu: Close all positions (unchanged), Close all profitable positions
/// and Close all losing positions. The Trade tab only decides WHICH options to offer (from each row's live P/L) and
/// sends the existing close-all request with a `scope`; the server runs the same close-all (group delay, checks).
class _FakeApi extends ApiClient {
  _FakeApi(this.positions) : super(AuthStore());
  List<Map<String, dynamic>> positions;
  final closeBodies = <Map<String, dynamic>>[];
  final closePaths = <String>[];
  Completer<Map<String, dynamic>>? closeGate; // when set, the close-all answer waits for it
  Map<String, dynamic> closeAnswer = {'closed': 1, 'skipped': 0, 'message': '1 position closed.'};

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/accounts/me') {
      return [
        {'id': 'A1', 'login': '500001', 'type': 'LIVE', 'status': 'ACTIVE', 'currency': 'USD', 'leverage': 100, 'balance': 10000, 'equity': 10000, 'margin': 0, 'freeMargin': 10000, 'marginLevel': 0, 'floatingPL': 0}
      ];
    }
    if (path == '/positions') return positions;
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    if (path.endsWith('/close-all') || path.endsWith('/close-scoped')) {
      closePaths.add(path);
      closeBodies.add(Map<String, dynamic>.from(body as Map));
      if (closeGate != null) return closeGate!.future;
      return closeAnswer;
    }
    return <String, dynamic>{};
  }
}

/// A BUY of 0.10 EURUSD opened at [open]; with the bid at 1.1000 it is +10.00 at 1.0990, -10.00 at 1.1010 and exactly
/// 0.00 at 1.1000 (0.1 lot x 100000 x the price difference).
Map<String, dynamic> _pos(String id, double open) => {
      'id': id,
      'accountId': 'A1',
      'side': 'BUY',
      'volume': 0.1,
      'openPrice': open,
      'symbol': {'symbol': 'EURUSD', 'digits': 5},
      'openedAt': DateTime.now().toIso8601String(),
    };

Future<({_FakeApi api, ProviderContainer c})> _open(WidgetTester t, List<Map<String, dynamic>> positions) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi(positions);
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => const <TradeSymbol>[]),
  ]);
  addTearDown(c.dispose);
  c.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.1000, ask: 1.1002, ts: 0));
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const TradeScreen()),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  return (api: api, c: c);
}

Future<void> _menu(WidgetTester t) async {
  await t.tap(find.byTooltip('Positions menu'));
  await t.pumpAndSettle();
}

final _all = find.text('Close all positions');
final _profit = find.text('Close all profitable positions');
final _loss = find.text('Close all losing positions');

void main() {
  group('which options the menu offers (from the live P/L of the open positions)', () {
    testWidgets('only profitable positions: Close all + Close all profitable', (t) async {
      await _open(t, [_pos('a', 1.0990), _pos('b', 1.0980)]);
      await _menu(t);
      expect(_all, findsOneWidget);
      expect(_profit, findsOneWidget);
      expect(_loss, findsNothing);
    });

    testWidgets('only losing positions: Close all + Close all losing', (t) async {
      await _open(t, [_pos('a', 1.1010), _pos('b', 1.1020)]);
      await _menu(t);
      expect(_all, findsOneWidget);
      expect(_loss, findsOneWidget);
      expect(_profit, findsNothing);
    });

    testWidgets('both kinds: all three options', (t) async {
      await _open(t, [_pos('a', 1.0990), _pos('b', 1.1010)]);
      await _menu(t);
      expect(_all, findsOneWidget);
      expect(_profit, findsOneWidget);
      expect(_loss, findsOneWidget);
    });

    testWidgets('a position at exactly 0.00 is neither profitable nor losing', (t) async {
      await _open(t, [_pos('z', 1.1000)]);
      await _menu(t);
      expect(_all, findsOneWidget);
      expect(_profit, findsNothing);
      expect(_loss, findsNothing);
    });

    testWidgets('zero beside a profitable one: only Close all + profitable', (t) async {
      await _open(t, [_pos('z', 1.1000), _pos('a', 1.0990)]);
      await _menu(t);
      expect(_profit, findsOneWidget);
      expect(_loss, findsNothing);
    });

    testWidgets('no open positions: no menu at all, so no profitable / losing option either', (t) async {
      await _open(t, const []);
      expect(find.byTooltip('Positions menu'), findsNothing);
      expect(_profit, findsNothing);
      expect(_loss, findsNothing);
    });

    testWidgets('the options follow the live P/L: when the price moves, a category appears or goes away', (t) async {
      final h = await _open(t, [_pos('a', 1.0990)]); // +10 at bid 1.1000
      await _menu(t);
      expect(_profit, findsOneWidget);
      expect(_loss, findsNothing);
      await t.tapAt(const Offset(5, 5)); // dismiss
      await t.pumpAndSettle();
      h.c.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.0980, ask: 1.0982, ts: 1)); // now -10
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await _menu(t);
      expect(_loss, findsOneWidget);
      expect(_profit, findsNothing);
    });
  });

  group('what each option sends', () {
    testWidgets('Close all positions sends the same empty body as before', (t) async {
      final h = await _open(t, [_pos('a', 1.0990), _pos('b', 1.1010)]);
      await _menu(t);
      await t.tap(_all);
      await t.pumpAndSettle();
      expect(h.api.closeBodies, [<String, dynamic>{}]);
      expect(h.api.closePaths, ['/accounts/A1/close-all'], reason: 'the original route, untouched');
    });

    testWidgets('Close all profitable positions sends scope profitable, once', (t) async {
      final h = await _open(t, [_pos('a', 1.0990), _pos('b', 1.1010)]);
      await _menu(t);
      await t.tap(_profit);
      await t.pumpAndSettle();
      expect(h.api.closeBodies, [
        {'scope': 'profitable'}
      ]);
      expect(h.api.closePaths, ['/accounts/A1/close-scoped'], reason: 'its own route: an older server answers 404 and closes nothing');
    });

    testWidgets('Close all losing positions sends scope losing, once', (t) async {
      final h = await _open(t, [_pos('a', 1.0990), _pos('b', 1.1010)]);
      await _menu(t);
      await t.tap(_loss);
      await t.pumpAndSettle();
      expect(h.api.closeBodies, [
        {'scope': 'losing'}
      ]);
    });

    testWidgets('a second bulk close while the first is running is ignored (nothing is closed twice)', (t) async {
      final h = await _open(t, [_pos('a', 1.0990), _pos('b', 1.1010)]);
      h.api.closeGate = Completer<Map<String, dynamic>>(); // the group delay: the answer takes a while
      await _menu(t);
      await t.tap(_profit);
      await t.pump();
      await _menu(t);
      await t.tap(_loss); // while the first is still running
      await t.pump();
      expect(h.api.closeBodies, [
        {'scope': 'profitable'}
      ], reason: 'one request only');
      h.api.closeGate!.complete({'closed': 1, 'skipped': 0, 'message': '1 position closed.'});
      await t.pumpAndSettle();
      // Finished: the next bulk close goes through again.
      h.api.closeGate = null;
      await _menu(t);
      await t.tap(_loss);
      await t.pumpAndSettle();
      expect(h.api.closeBodies.length, 2);
      expect(h.api.closeBodies.last, {'scope': 'losing'});
    });

    testWidgets('the server found nothing in the category (the P/L moved): the message is shown and nothing else happens', (t) async {
      final h = await _open(t, [_pos('a', 1.0990)]);
      h.api.closeAnswer = {'closed': 0, 'skipped': 0, 'message': 'No profitable positions to close.', 'scope': 'profitable'};
      await _menu(t);
      await t.tap(_profit);
      await t.pumpAndSettle();
      expect(find.text('No profitable positions to close.'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('skipped positions are reported exactly as Close all reports them', (t) async {
      final h = await _open(t, [_pos('a', 1.0990), _pos('b', 1.0980)]);
      h.api.closeAnswer = {'closed': 1, 'skipped': 1, 'message': '1 position closed, 1 skipped because they could not be closed.'};
      await _menu(t);
      await t.tap(_profit);
      await t.pumpAndSettle();
      expect(find.textContaining('1 skipped'), findsOneWidget);
    });
  });

  group('bulk_close helpers', () {
    test('profit and loss are judged on the cents shown', () {
      expect([isProfit(0.01), isProfit(0.004), isProfit(0), isProfit(-1)], [true, false, false, false]);
      expect([isLoss(-0.01), isLoss(-0.004), isLoss(0), isLoss(1)], [true, false, false, false]);
      expect(inBulkScope(BulkClose.all, 0), isTrue);
      expect(inBulkScope(BulkClose.profitable, 0), isFalse);
      expect(inBulkScope(BulkClose.losing, 0), isFalse);
    });

    test('the menu options for every mix', () {
      expect(bulkCloseOptions([5, 3]), (profitable: true, losing: false));
      expect(bulkCloseOptions([-5, -3]), (profitable: false, losing: true));
      expect(bulkCloseOptions([5, -3, 0]), (profitable: true, losing: true));
      expect(bulkCloseOptions([0, 0.004]), (profitable: false, losing: false));
      expect(bulkCloseOptions(const []), (profitable: false, losing: false));
    });

    test('the request bodies', () {
      expect(BulkClose.all.body, isEmpty, reason: 'the original Close All sends nothing new');
      expect(BulkClose.all.path('A9'), '/accounts/A9/close-all');
      expect(BulkClose.profitable.path('A9'), '/accounts/A9/close-scoped');
      expect(BulkClose.losing.path('A9'), '/accounts/A9/close-scoped');
      expect(BulkClose.profitable.body, {'scope': 'profitable'});
      expect(BulkClose.losing.body, {'scope': 'losing'});
    });
  });
}
