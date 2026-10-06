import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/charts_screen.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opening a new trade while other trades are already on the chart must never look like a page
/// refresh: no loader, the chart widget is not rebuilt from scratch (it would lose its scroll /
/// zoom), the existing trade lines never blink out, and the new trade appears as soon as the
/// backend confirms it.
const _q = Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0);

Map<String, dynamic> _row(int i) => {
      'id': 'p$i',
      'accountId': 'A1',
      'side': i.isEven ? 'BUY' : 'SELL',
      'volume': 0.1,
      'openPrice': 1.0995 + i * 0.0001,
      'symbol': {'symbol': 'EURUSD', 'digits': 5},
      'openedAt': DateTime.now().subtract(Duration(minutes: i + 1)).toIso8601String(),
    };

class _FakeApi extends ApiClient {
  _FakeApi(int open) : super(AuthStore()) {
    rows.addAll([for (var i = 0; i < open; i++) _row(i)]);
  }
  final rows = <Map<String, dynamic>>[];
  Completer<void>? positionsGate;
  Completer<Map<String, dynamic>>? order;
  var positionGets = 0;
  var candleGets = 0;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/market/candles') {
      candleGets++;
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
      return [...rows];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) {
    if (path == '/orders') {
      order = Completer<Map<String, dynamic>>();
      return order!.future;
    }
    return Future.value(<String, dynamic>{});
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

void main() {
  // The server's positions list can lag the fill by a moment (the row is committed a little after
  // the order response). A refetch that lands in that window must not make the trade vanish.
  for (final open in [1, 8]) {
    testWidgets('server list lagging behind the fill ($open open): the new trade does not blink out', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = _FakeApi(open);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        marketSocketProvider.overrideWith((_) => null),
        feedSubscriptionProvider.overrideWith((_) {}),
        accountsProvider.overrideWith((_) async => const <Account>[]),
        activeAccountIdProvider.overrideWith((_) => 'A1'),
        openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
        symbolsProvider.overrideWith((_) async => [_sym()]),
      ]);
      c.read(quotesProvider.notifier).set(_q);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.tap(find.textContaining('BUY').first);
      await t.pump();
      final newId = 'p${open + 100}';
      api.order!.complete({'accepted': true, 'orderId': 'o1', 'positionId': newId, 'status': 'FILLED', 'fillPrice': 1.1002, 'filledVolume': 0.1});
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      bool shown() => c.read(openPositionsProvider).valueOrNull?.any((p) => p.id == newId) ?? false;
      expect(shown(), isTrue);

      // Refetches keep returning the OLD list (no new row yet) for a while, then catch up.
      var gone = 0;
      for (var i = 0; i < 12; i++) {
        c.read(positionsRefreshProvider).request();
        await t.pump(const Duration(milliseconds: 40));
        await t.pump(const Duration(milliseconds: 40));
        if (!shown()) gone++;
      }
      api.rows.add(_row(open + 100)..['id'] = newId);
      for (var i = 0; i < 6; i++) {
        c.read(positionsRefreshProvider).request();
        await t.pump(const Duration(milliseconds: 40));
      }
      expect(gone, 0, reason: 'the confirmed trade disappeared from the chart on $gone refetches before the server list caught up');
      expect(shown(), isTrue);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    });
  }

  for (final open in [0, 1, 8, 25]) {
    testWidgets('opening a trade with $open already open never looks like a refresh', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = _FakeApi(open);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        marketSocketProvider.overrideWith((_) => null),
        feedSubscriptionProvider.overrideWith((_) {}),
        accountsProvider.overrideWith((_) async => const <Account>[]),
        activeAccountIdProvider.overrideWith((_) => 'A1'),
        openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
        symbolsProvider.overrideWith((_) async => [_sym()]),
      ]);
      c.read(quotesProvider.notifier).set(_q);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const ChartsScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }

      int levelsNow() => t.widget<CandleChart>(find.byType(CandleChart)).levels.length;
      final chartState = t.state(find.byType(CandleChart));
      final linesBefore = levelsNow();
      expect(linesBefore, greaterThanOrEqualTo(open), reason: 'the open trades are drawn');

      var spinnerFrames = 0, recreated = 0, dipFrames = 0, minLines = linesBefore;
      Future<void> frame([int ms = 16]) async {
        await t.pump(Duration(milliseconds: ms));
        if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) spinnerFrames++;
        if (find.byType(CandleChart).evaluate().isEmpty) {
          recreated++;
          return;
        }
        if (!identical(t.state(find.byType(CandleChart)), chartState)) recreated++;
        final n = levelsNow();
        if (n < minLines) minLines = n;
        if (n < linesBefore) dipFrames++;
      }

      // BUY, exactly what a click does (the order is in flight until the backend answers).
      await t.tap(find.textContaining('BUY').first);
      for (var i = 0; i < 6; i++) {
        await frame();
      }

      // The backend confirms the fill; the positions list is still being fetched.
      api.positionsGate = Completer<void>();
      final newId = 'p${open + 100}';
      api.order!.complete({'accepted': true, 'orderId': 'o1', 'positionId': newId, 'status': 'FILLED', 'fillPrice': 1.1002, 'filledVolume': 0.1});
      for (var i = 0; i < 4; i++) {
        await frame();
      }
      expect(c.read(openPositionsProvider).valueOrNull?.any((p) => p.id == newId), isTrue, reason: 'the confirmed trade shows without waiting for the refetch');

      // What the socket does around a fill: refetch positions + accounts (coalesced), order event.
      for (var i = 0; i < 6; i++) {
        c.read(positionsRefreshProvider).request();
        c.read(accountsRefreshProvider).request();
        await frame();
      }
      for (var i = 0; i < 10; i++) {
        await frame(30);
      }
      // The server list finally includes the new trade.
      api.rows.add(_row(open + 100)..['id'] = newId);
      api.positionsGate!.complete();
      for (var i = 0; i < 14; i++) {
        await frame(30);
      }

      expect(spinnerFrames, 0, reason: 'a loader was shown on $spinnerFrames frames');
      expect(recreated, 0, reason: 'the chart was rebuilt from scratch on $recreated frames (scroll / zoom would reset)');
      expect(dipFrames, 0, reason: 'existing trade lines dropped to $minLines (from $linesBefore) on $dipFrames frames');
      expect(levelsNow(), greaterThan(linesBefore), reason: 'the new trade is on the chart');
      expect({for (final p in c.read(openPositionsProvider).valueOrNull ?? const <Position>[]) p.id}.length, open + 1);

      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    });
  }
}
