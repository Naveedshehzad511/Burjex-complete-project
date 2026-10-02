import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The client requirement: Buy/Sell stay usable while earlier orders are still being processed,
/// every click is its own request, and a trade shows up the moment the BACKEND confirms it.
///
/// The fake backend answers `POST /orders` only when the test says so (that is the configured
/// execution delay + queue in real life), and `GET /positions` only when the test opens a gate,
/// so what the UI shows in between can only have come from a backend confirmation.

const _q = Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0);

class _Order {
  _Order(this.body);
  final Map<String, dynamic> body;
  final done = Completer<Map<String, dynamic>>();
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(AuthStore());
  final orders = <_Order>[];
  final positionRows = <Map<String, dynamic>>[];
  int positionGets = 0;
  Completer<void>? positionsGate;

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
    if (path == '/positions') {
      positionGets++;
      if (positionsGate != null) await positionsGate!.future;
      return [...positionRows];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) {
    if (path == '/orders') {
      final o = _Order(Map<String, dynamic>.from(body as Map));
      orders.add(o);
      return o.done.future;
    }
    return Future.value(<String, dynamic>{});
  }
}

TradeSymbol _sym(String s) => TradeSymbol.fromJson({
      'id': s,
      'symbol': s,
      'description': s,
      'class': 'CRYPTO', // 24/7 session: never "market closed" in a test
      'digits': 5,
      'minLot': 0.01,
      'maxLot': 100,
      'lotStep': 0.01,
    });

Map<String, dynamic> _filled(int n) => {
      'accepted': true,
      'orderId': 'o$n',
      'positionId': 'p$n',
      'status': 'FILLED',
      'fillPrice': 1.1002 + n * 0.00001,
      'filledVolume': 0.1,
    };

Future<(_FakeApi, ProviderContainer)> _pump(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = _FakeApi();
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    marketSocketProvider.overrideWith((_) => null),
    feedSubscriptionProvider.overrideWith((_) {}),
    accountsProvider.overrideWith((_) async => const <Account>[]),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => [_sym('EURUSD')]),
  ]);
  c.read(quotesProvider.notifier).set(_q);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return (api, c);
}

Future<void> _unmount(WidgetTester t, ProviderContainer c) async {
  await t.pumpWidget(const SizedBox());
  c.dispose();
  await t.pump(const Duration(seconds: 1));
}

List<Position> _open(ProviderContainer c) => c.read(openPositionsProvider).valueOrNull ?? const <Position>[];

void main() {
  group('Chart BUY / SELL under rapid clicks', () {
    testWidgets('12 rapid BUY clicks: 12 independent requests, buttons never blocked', (t) async {
      final (api, c) = await _pump(t);
      expect(_open(c), isEmpty);

      for (var i = 0; i < 12; i++) {
        await t.tap(find.textContaining('BUY').first);
        // A real user's clicks are at least a frame apart: the UI re-renders in between.
        await t.pump(const Duration(milliseconds: 16));
      }

      // Every click went out on its own, while NONE of the earlier ones has been answered.
      expect(api.orders.length, 12);
      expect({for (final o in api.orders) o.body['clientOrderId']}.length, 12, reason: 'each click is a distinct order');
      expect(api.orders.every((o) => o.body['side'] == 'BUY' && o.body['type'] == 'MARKET'), isTrue);
      // The cards stay plain "BUY" / "SELL": no counter, no disabled state.
      expect(find.text('BUY'), findsOneWidget);
      expect(find.text('SELL'), findsOneWidget);
      // ...and SELL is usable too, straight away, with all 12 still in flight.
      await t.tap(find.textContaining('SELL').first);
      await t.pump();
      expect(api.orders.length, 13);
      expect(api.orders.last.body['side'], 'SELL');

      // Backend answers: the first trade is visible the moment IT is confirmed, not after the
      // whole batch. The positions endpoint is held shut so only confirmations can explain it.
      api.positionsGate = Completer<void>();
      for (var i = 0; i < 12; i++) {
        api.orders[i].done.complete(_filled(i));
        await t.pump();
        expect(_open(c).length, i + 1, reason: 'trade ${i + 1} must show as soon as it is confirmed');
      }
      expect({for (final p in _open(c)) p.id}.length, 12);
      expect(_open(c).every((p) => p.side == 'BUY' && p.volume == 0.1 && p.accountId == 'A1'), isTrue);

      // The server list catches up: same 12 (no duplicates, nothing lost) + the SELL.
      api.positionRows.addAll([
        for (var i = 0; i < 12; i++) {'id': 'p$i', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.1, 'openPrice': 1.1002, 'symbol': {'symbol': 'EURUSD', 'digits': 5}, 'openedAt': DateTime.now().toIso8601String()},
      ]);
      api.positionsGate!.complete();
      api.orders[12].done.complete(_filled(99));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pump(const Duration(milliseconds: 50));
      expect(_open(c).where((p) => p.side == 'BUY').length, 12);
      await _unmount(t, c);
    });

    testWidgets('a rejected order is shown as rejected, never as a trade', (t) async {
      final (api, c) = await _pump(t);
      await t.tap(find.textContaining('BUY').first);
      await t.pump();
      api.orders.single.done.complete({'accepted': false, 'status': 'REJECTED', 'reason': 'insufficient margin'});
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(_open(c), isEmpty);
      await _unmount(t, c);
      await t.pump(const Duration(seconds: 5)); // let the toast's own timer finish
    });

    testWidgets('a failed request does not leave the button stuck', (t) async {
      final (api, c) = await _pump(t);
      await t.tap(find.textContaining('BUY').first);
      await t.pump();
      api.orders.single.done.completeError(Exception('boom'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(find.textContaining('BUY').first);
      await t.pump();
      expect(api.orders.length, 2, reason: 'the next click goes straight out');
      await _unmount(t, c);
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('confirmed positions', () {
    test('only an engine "opened" push becomes a position', () {
      final opened = {
        'opened': true,
        'id': 'p1',
        'accountId': 'A1',
        'symbol': 'EURUSD',
        'digits': 5,
        'side': 'buy',
        'volume': 0.5,
        'openPrice': 1.1,
        'slPrice': 1.09,
        'openedAt': '2026-10-01T10:00:00Z',
      };
      final p = Position.tryFromOpenedEvent(opened)!;
      expect((p.id, p.side, p.volume, p.openPrice, p.slPrice, p.symbol, p.digits), ('p1', 'BUY', 0.5, 1.1, 1.09, 'EURUSD', 5));
      // Live P/L snapshots, id-only pings and incomplete rows never create a position.
      expect(Position.tryFromOpenedEvent({...opened, 'opened': null}), isNull);
      expect(Position.tryFromOpenedEvent({'id': 'p1', 'stale': true}), isNull);
      expect(Position.tryFromOpenedEvent({...opened, 'openPrice': null}), isNull);
    });

    test('addConfirmedFill adds nothing unless the backend returned a filled position', () {
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(_FakeApi()),
        activeAccountIdProvider.overrideWith((_) => 'A1'),
        openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
      ]);
      addTearDown(c.dispose);
      final n = c.read(openPositionsProvider.notifier);
      bool add(Map<String, dynamic> r) =>
          n.addConfirmedFill(r, accountId: 'A1', symbol: 'EURUSD', digits: 5, side: 'BUY', volume: 0.1);
      expect(add({'accepted': false, 'reason': 'x'}), isFalse);
      expect(add({'accepted': true, 'orderId': 'o1'}), isFalse, reason: 'no position id: nothing to show');
      expect(add({'accepted': true, 'positionId': 'p1'}), isFalse, reason: 'no fill price from the backend');
      expect(add(_filled(1)), isTrue);
    });
  });

  group('SingleFlight (coalesced refresh)', () {
    test('a burst runs once now and at most once more, with no timer', () async {
      var runs = 0;
      final gate = Completer<void>();
      final sf = SingleFlight(() async {
        runs++;
        if (runs == 1) await gate.future;
      });
      for (var i = 0; i < 12; i++) {
        sf.request();
      }
      await Future<void>.delayed(Duration.zero);
      expect(runs, 1, reason: 'the first request starts immediately');
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runs, 2, reason: '11 requests during the run collapse into one trailing run');
      sf.request();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runs, 3, reason: 'idle again: the next request runs immediately');
    });

    test('a failing run never wedges later requests', () async {
      var runs = 0;
      final sf = SingleFlight(() async {
        runs++;
        throw StateError('network');
      });
      sf.request();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      sf.request();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runs, 2);
    });
  });
}
