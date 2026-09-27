import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/state/pending_orders.dart';
import 'package:burjex_portal/widgets/pending_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves a scripted pending-order list instead of calling the gateway.
class _FakeApi extends ApiClient {
  _FakeApi(this.rows) : super(AuthStore());
  List<Map<String, dynamic>> rows;
  int calls = 0;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    calls++;
    return rows;
  }
}

Map<String, dynamic> _row(String id, {String type = 'BUY_LIMIT', double price = 100, double vol = 0.1, double? sl, double? tp}) => {
      'id': id,
      'symbol': {'symbol': 'BTCUSD', 'digits': 2},
      'side': type.startsWith('BUY') ? 'BUY' : 'SELL',
      'type': type,
      'volume': vol,
      'price': type.contains('STOP') ? null : price,
      'stopPrice': type.contains('STOP') ? price : null,
      'slPrice': sl,
      'tpPrice': tp,
    };

Map<String, dynamic> _evt(String id, String status, {String acct = 'A1', String type = 'BUY_LIMIT', double price = 100, double vol = 0.1, double? sl, double? tp}) => {
      'id': id,
      'accountId': acct,
      'symbol': 'BTCUSD',
      'side': type.startsWith('BUY') ? 'BUY' : 'SELL',
      'type': type,
      'status': status,
      'volume': vol,
      'price': type.contains('STOP') ? null : price,
      'stopPrice': type.contains('STOP') ? price : null,
      'slPrice': sl,
      'tpPrice': tp,
    };

ProviderContainer _container(_FakeApi api) => ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      activeAccountIdProvider.overrideWith((_) => 'A1'),
    ]);

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  group('ChartEdit.errors', () {
    const q = Tick(symbol: 'BTCUSD', bid: 100.0, ask: 100.5, ts: 0);
    Map<String, String> check(ChartEdit e) => e.errors(q, minLot: 0.01, maxLot: 100, lotStep: 0.01);

    test('all four entry sides', () {
      expect(check(ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1, entry: 99)), isEmpty);
      expect(check(ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1, entry: 101))['entry'], isNotNull);
      expect(check(ChartEdit.draft(type: OrderType.buyStop, volume: 0.1, entry: 101)), isEmpty);
      expect(check(ChartEdit.draft(type: OrderType.buyStop, volume: 0.1, entry: 99))['entry'], isNotNull);
      expect(check(ChartEdit.draft(type: OrderType.sellLimit, volume: 0.1, entry: 101)), isEmpty);
      expect(check(ChartEdit.draft(type: OrderType.sellLimit, volume: 0.1, entry: 99))['entry'], isNotNull);
      expect(check(ChartEdit.draft(type: OrderType.sellStop, volume: 0.1, entry: 99)), isEmpty);
      expect(check(ChartEdit.draft(type: OrderType.sellStop, volume: 0.1, entry: 101))['entry'], isNotNull);
    });

    test('entry is required', () {
      expect(check(ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1))['entry'], isNotNull);
    });

    test('SL / TP must sit on the protective side of the entry', () {
      final buy = ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1, entry: 99)
        ..sl = 98
        ..tp = 101;
      expect(check(buy), isEmpty);
      buy.sl = 100; // above entry
      expect(check(buy)['sl'], isNotNull);
      buy.sl = 98;
      buy.tp = 98.5; // below entry
      expect(check(buy)['tp'], isNotNull);

      final sell = ChartEdit.draft(type: OrderType.sellLimit, volume: 0.1, entry: 101)
        ..sl = 102
        ..tp = 100;
      expect(check(sell), isEmpty);
      sell.sl = 100.5;
      expect(check(sell)['sl'], isNotNull);
      sell.sl = 102;
      sell.tp = 103;
      expect(check(sell)['tp'], isNotNull);
    });

    test('volume: required, min, max and lot step', () {
      ChartEdit d(double? v) => ChartEdit.draft(type: OrderType.buyLimit, volume: v, entry: 99);
      expect(check(d(null))['volume'], isNotNull);
      expect(check(d(0))['volume'], isNotNull);
      expect(check(d(0.005))['volume'], isNotNull); // below min
      expect(check(d(101))['volume'], isNotNull); // above max
      expect(check(d(0.015))['volume'], isNotNull); // off step
      expect(check(d(0.01)), isEmpty);
      expect(check(d(100)), isEmpty);
      expect(check(d(2.5)), isEmpty);
    });

    test('a position edit has no entry or volume rules', () {
      final p = ChartEdit.position(id: 'p1', side: 'BUY', entry: 100)
        ..sl = 99
        ..tp = 102;
      expect(check(p), isEmpty);
      p.sl = 101;
      expect(check(p)['sl'], isNotNull);
    });
  });

  group('PendingOrdersController', () {
    test('created / modified / filled / cancelled events update the list with no refetch', () async {
      final api = _FakeApi([]);
      final c = _container(api);
      addTearDown(c.dispose);
      c.read(pendingOrdersProvider);
      await _settle();
      expect(c.read(pendingOrdersProvider).value, isEmpty);
      final loads = api.calls;

      void push(Map<String, dynamic> o) {
        final prev = c.read(lastOrderEventProvider);
        c.read(lastOrderEventProvider.notifier).state = OrderEvent((prev?.seq ?? 0) + 1, o);
      }

      push(_evt('o1', 'PENDING', vol: 0.1, sl: 90, tp: 120));
      push(_evt('o2', 'PENDING', type: 'SELL_STOP', price: 80, vol: 0.2));
      var list = c.read(pendingOrdersProvider).value!;
      expect(list.map((o) => o.id), ['o1', 'o2']);
      expect(list[1].entry, 80); // a stop order's entry is its stopPrice
      expect(list[1].hasStopField, isTrue);

      push(_evt('o1', 'PENDING', price: 95, vol: 0.5, sl: null, tp: 121)); // moved, resized, SL cleared
      list = c.read(pendingOrdersProvider).value!;
      expect(list.firstWhere((o) => o.id == 'o1').entry, 95);
      expect(list.firstWhere((o) => o.id == 'o1').volume, 0.5);
      expect(list.firstWhere((o) => o.id == 'o1').sl, isNull);

      push(_evt('o1', 'FILLED')); // triggered → the pending line goes away
      expect(c.read(pendingOrdersProvider).value!.map((o) => o.id), ['o2']);
      push(_evt('o2', 'CANCELLED'));
      expect(c.read(pendingOrdersProvider).value, isEmpty);
      expect(api.calls, loads, reason: 'events must not need a REST refetch');
    });

    test('rejected and expired orders are removed', () async {
      final api = _FakeApi([_row('o1'), _row('o2')]);
      final c = _container(api);
      addTearDown(c.dispose);
      c.read(pendingOrdersProvider);
      await _settle();
      expect(c.read(pendingOrdersProvider).value!.length, 2);
      c.read(lastOrderEventProvider.notifier).state = OrderEvent(1, _evt('o1', 'REJECTED'));
      c.read(lastOrderEventProvider.notifier).state = OrderEvent(2, _evt('o2', 'EXPIRED'));
      expect(c.read(pendingOrdersProvider).value, isEmpty);
    });

    test("another account's orders are ignored", () async {
      final api = _FakeApi([]);
      final c = _container(api);
      addTearDown(c.dispose);
      c.read(pendingOrdersProvider);
      await _settle();
      c.read(lastOrderEventProvider.notifier).state = OrderEvent(1, _evt('x', 'PENDING', acct: 'OTHER'));
      expect(c.read(pendingOrdersProvider).value, isEmpty);
    });

    test('a socket reconnect reconciles with the server', () async {
      final api = _FakeApi([_row('o1')]);
      final c = _container(api);
      addTearDown(c.dispose);
      c.read(pendingOrdersProvider);
      await _settle();
      expect(c.read(pendingOrdersProvider).value!.map((o) => o.id), ['o1']);
      // While the socket was down the order filled and another was placed.
      api.rows = [_row('o9', type: 'SELL_LIMIT', price: 130)];
      c.read(socketEpochProvider.notifier).state++;
      await _settle();
      expect(c.read(pendingOrdersProvider).value!.map((o) => o.id), ['o9']);
      // A fill in the gap before the new socket is live is caught by the second pass.
      api.rows = [];
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(c.read(pendingOrdersProvider).value, isEmpty);
    });

    test('removeLocal drops a cancelled order immediately', () async {
      final api = _FakeApi([_row('o1'), _row('o2')]);
      final c = _container(api);
      addTearDown(c.dispose);
      c.read(pendingOrdersProvider);
      await _settle();
      c.read(pendingOrdersProvider.notifier).removeLocal('o1');
      expect(c.read(pendingOrdersProvider).value!.map((o) => o.id), ['o2']);
    });
  });

  group('PendingPanel', () {
    Future<void> pump(WidgetTester t, ChartEdit e, {List<String>? log, VoidCallback? onApply}) async {
      final theme = AppTheme.light(Branding.fallback);
      await t.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: PendingPanel(
              edit: e,
              symbolLabel: 'BTCUSD',
              digits: 2,
              quote: const Tick(symbol: 'BTCUSD', bid: 100.0, ask: 100.5, ts: 0),
              minLot: 0.01,
              maxLot: 100,
              lotStep: 0.01,
              busy: false,
              serverError: null,
              onChanged: () {},
              onPickType: (ty) => log?.add('type:${ty.api}'),
              onAddSl: () => log?.add('addsl'),
              onAddTp: () => log?.add('addtp'),
              onApply: onApply ?? () {},
              onClose: () {},
              onCancelOrder: () => log?.add('cancel'),
            ),
          ),
        ),
      ));
    }

    testWidgets('shows type, entry, SL, TP, volume and the Place button', (t) async {
      await pump(t, ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1, entry: 99));
      expect(find.text('New pending order · BTCUSD'), findsOneWidget);
      for (final l in ['Buy Limit', 'Sell Limit', 'Buy Stop', 'Sell Stop']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.text('99.00'), findsOneWidget); // entry
      expect(find.text('0.10'), findsOneWidget); // volume
      expect(find.text('Place Buy Limit 0.10'), findsOneWidget);
    });

    testWidgets('picking a type and the +/- volume controls work', (t) async {
      final log = <String>[];
      final e = ChartEdit.draft(type: OrderType.buyLimit, volume: 0.10, entry: 99);
      await pump(t, e, log: log);
      await t.tap(find.text('Sell Stop'));
      expect(log, ['type:SELL_STOP']);
      await t.tap(find.byIcon(Icons.add).first);
      await t.pump();
      expect(e.volume, closeTo(0.11, 1e-9));
      await t.tap(find.byIcon(Icons.remove).first);
      await t.tap(find.byIcon(Icons.remove).first);
      expect(e.volume, closeTo(0.09, 1e-9));
    });

    testWidgets('Place is disabled while a value is invalid', (t) async {
      var applied = 0;
      final e = ChartEdit.draft(type: OrderType.buyLimit, volume: 0.10, entry: 105); // above Ask
      await pump(t, e, onApply: () => applied++);
      expect(find.text('Must be below the Ask'), findsOneWidget);
      final btn = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Place Buy Limit 0.10'));
      expect(btn.onPressed, isNull, reason: 'Place must be disabled while the entry is invalid');
      expect(applied, 0);
    });

    testWidgets('valid values enable Place', (t) async {
      var applied = 0;
      await pump(t, ChartEdit.draft(type: OrderType.buyLimit, volume: 0.10, entry: 99), onApply: () => applied++);
      await t.tap(find.text('Place Buy Limit 0.10'));
      expect(applied, 1);
    });

    testWidgets('an existing order offers Apply changes and Cancel this order', (t) async {
      final log = <String>[];
      final e = ChartEdit.order(id: 'o1', orderType: 'BUY_LIMIT', side: 'BUY', entry: 99, sl: 95, tp: 110, volume: 0.2);
      await pump(t, e, log: log);
      expect(find.text('Apply changes'), findsOneWidget);
      await t.ensureVisible(find.text('Cancel this order'));
      await t.tap(find.text('Cancel this order'));
      expect(log, ['cancel']);
      expect(find.text('95.00'), findsOneWidget);
      expect(find.text('110.00'), findsOneWidget);
    });

    testWidgets('clearing SL removes it from the edit', (t) async {
      final e = ChartEdit.order(id: 'o1', orderType: 'BUY_LIMIT', side: 'BUY', entry: 99, sl: 95, tp: 110, volume: 0.2);
      await pump(t, e);
      await t.tap(find.byTooltip('Clear Stop loss'));
      await t.pump();
      expect(e.sl, isNull);
      expect(e.tp, 110);
    });
  });
}
