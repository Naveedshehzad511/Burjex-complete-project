import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A close the server has confirmed takes the row off the open list at once - even while a reload is in
/// flight - a failed close changes nothing, a partial close keeps the remainder, and a late OPEN update for
/// a closed trade never brings it back.
class _Api extends ApiClient {
  _Api() : super(AuthStore());
  Completer<void>? gate;
  int positionGets = 0;
  final volumes = <String, double>{'p1': 0.1, 'p2': 0.1, 'p3': 0.1};

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/accounts/me') return <dynamic>[];
    if (path != '/positions') return <dynamic>[];
    positionGets++;
    final snapshot = Map.of(volumes);
    if (gate != null) await gate!.future;
    return [
      for (final e in snapshot.entries)
        {'id': e.key, 'accountId': 'A1', 'side': 'BUY', 'volume': e.value, 'openPrice': 1.1, 'symbol': 'EURUSD', 'openedAt': DateTime.now().toIso8601String()}
    ];
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

Future<ProviderContainer> _box(_Api api) async {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    accountsProvider.overrideWith((_) async => const <Account>[]),
  ]);
  addTearDown(c.dispose);
  final sub = c.listen(accountPositionsProvider, (_, __) {}, fireImmediately: true);
  addTearDown(sub.close);
  await c.read(openPositionsProvider.future);
  return c;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 40));
List<String>? _ids(ProviderContainer c) => c.read(accountPositionsProvider).valueOrNull?.map((p) => p.id).toList();
double? _volume(ProviderContainer c, String id) =>
    c.read(accountPositionsProvider).valueOrNull?.where((p) => p.id == id).firstOrNull?.volume;

void _frame(ProviderContainer c, Map<String, dynamic> data) =>
    applyPositionFrame(c.read(_refProvider), data, events: TradeEventDetector(), announce: (_, __) {});

Map<String, dynamic> _closedFrame(String id, {double profit = 5}) =>
    {'id': id, 'accountId': 'A1', 'status': 'CLOSED', 'book': 'closed', 'closing': true, 'profit': profit};

Map<String, dynamic> _openFrame(String id, {double profit = 7, double volume = 0.1}) => {
      'id': id, 'accountId': 'A1', 'symbol': 'EURUSD', 'side': 'BUY', 'status': 'OPEN', 'book': 'open',
      'volume': volume, 'openPrice': 1.1, 'currentPrice': 1.1007, 'profit': profit, 'slPrice': null, 'tpPrice': null,
    };

Map<String, dynamic> _accepted(String id, double filled, {double balance = 10050}) => {
      'accepted': true, 'positionId': id, 'status': 'FILLED', 'fillPrice': 1.1005, 'filledVolume': filled,
      'account': {'accountId': 'A1', 'balance': balance, 'credit': 0, 'equity': balance, 'margin': 0, 'freeMargin': balance,
        'marginLevel': 0, 'floatingPL': 0, 'currency': 'USD', 'leverage': 100, 'ts': DateTime.now().millisecondsSinceEpoch},
    };

void main() {
  test('a close confirmed while a reload is in flight takes the row off at once', () async {
    final api = _Api();
    final c = await _box(api);
    expect(_ids(c), ['p1', 'p2', 'p3']);

    api.gate = Completer<void>(); // a slow reload (30 s reconcile, a fill elsewhere) is running
    c.invalidate(openPositionsProvider);
    await _pump();
    expect(c.read(openPositionsProvider).isLoading, isTrue);

    _frame(c, _closedFrame('p2'));
    expect(_ids(c), ['p1', 'p3'], reason: 'the row must not wait for the reload to land');

    api.volumes.remove('p2');
    api.gate!.complete();
    await _pump();
    expect(_ids(c), ['p1', 'p3']);
  });

  test('the close answer removes the row and applies the account; the push that follows reloads nothing more', () async {
    final api = _Api();
    final c = await _box(api);
    final epoch0 = c.read(tradeEventEpochProvider);
    api.gate = Completer<void>(); // the server is slow to list positions

    final ok = c.read(positionClosesProvider).applyCloseResponse(_accepted('p2', 0.1), id: 'p2', openVolume: 0.1);
    expect(ok, isTrue);
    expect(_ids(c), ['p1', 'p3'], reason: 'gone on the confirmation, not after the reload');
    expect(c.read(liveAccountProvider)['A1']?.balance, 10050, reason: 'balance moves with the row');

    await _pump();
    final gets = api.positionGets;
    _frame(c, _closedFrame('p2')); // the engine's push for the same close
    await _pump();
    expect(api.positionGets, gets, reason: 'the second confirmation of one close must not reload again');
    expect(c.read(tradeEventEpochProvider), epoch0 + 1, reason: 'History reloads once per close');

    api.volumes.remove('p2');
    api.gate!.complete();
    await _pump();
    expect(_ids(c), ['p1', 'p3']);
  });

  test('a failed or unconfirmed close leaves everything as it was', () async {
    final api = _Api();
    final c = await _box(api);
    final gets = api.positionGets;
    final closes = c.read(positionClosesProvider);
    expect(closes.applyCloseResponse(null, id: 'p2', openVolume: 0.1), isFalse); // request threw
    expect(closes.applyCloseResponse({'accepted': false, 'reason': 'NO_PRICE'}, id: 'p2', openVolume: 0.1), isFalse);
    expect(closes.applyCloseResponse('oops', id: 'p2', openVolume: 0.1), isFalse);
    await _pump();
    expect(_ids(c), ['p1', 'p2', 'p3']);
    expect(c.read(closedPositionIdsProvider), isEmpty);
    expect(c.read(liveAccountProvider)['A1'], isNull);
    expect(api.positionGets, gets);
  });

  test('a stale OPEN update after the close cannot bring the trade or its P/L back', () async {
    final api = _Api();
    final c = await _box(api);
    _frame(c, _openFrame('p2')); // live P/L while open
    expect(c.read(livePositionProvider)['p2'], 7);

    _frame(c, _closedFrame('p2'));
    await _pump();
    final gets = api.positionGets;
    _frame(c, _openFrame('p2', profit: 9)); // the live loop's late snapshot
    await _pump();
    expect(_ids(c), isNot(contains('p2')));
    expect(c.read(livePositionProvider).containsKey('p2'), isFalse);
    expect(api.positionGets, gets, reason: 'not treated as a new trade either');
  });

  test('a partial close keeps the remainder, with the volume that is left', () async {
    final api = _Api();
    final c = await _box(api);
    final epoch0 = c.read(tradeEventEpochProvider);
    api.gate = Completer<void>();

    final ok = c
        .read(positionClosesProvider)
        .applyCloseResponse(_accepted('p1', 0.04), id: 'p1', openVolume: 0.1, requestedVolume: 0.04);
    expect(ok, isTrue);
    expect(_ids(c), ['p1', 'p2', 'p3']);
    expect(_volume(c, 'p1'), closeTo(0.06, 1e-9));
    expect(c.read(closedPositionIdsProvider), isNot(contains('p1')));

    await _pump();
    final gets = api.positionGets;
    // The engine's push for the same partial close: OPEN, the size left and that size's P/L.
    _frame(c, {..._openFrame('p1', profit: 3.2, volume: 0.06), 'partial': true, 'closedVolume': 0.04}..remove('slPrice')..remove('tpPrice'));
    await _pump();
    expect(api.positionGets, gets, reason: 'the push for the same partial close reconciles nothing twice');
    expect(c.read(tradeEventEpochProvider), epoch0 + 1);
    expect(c.read(livePositionNotifierProvider).vol['p1'], 0.06);
    expect(c.read(livePositionProvider)['p1'], 3.2);

    api.volumes['p1'] = 0.06;
    api.gate!.complete();
    await _pump();
    expect(_volume(c, 'p1'), closeTo(0.06, 1e-9));
  });

  test('a partial-close push alone (another device) also shows the remainder', () async {
    final api = _Api();
    final c = await _box(api);
    _frame(c, {..._openFrame('p3', profit: 1, volume: 0.03), 'partial': true});
    expect(_ids(c), ['p1', 'p2', 'p3']);
    expect(_volume(c, 'p3'), closeTo(0.03, 1e-9));
  });

  test('close all: every confirmed close leaves at once, even mid-reload', () async {
    final api = _Api();
    final c = await _box(api);
    api.gate = Completer<void>();
    c.invalidate(openPositionsProvider);
    await _pump();
    for (final id in ['p1', 'p2', 'p3']) {
      _frame(c, _closedFrame(id));
    }
    expect(_ids(c), isEmpty);
    api.volumes.clear();
    api.gate!.complete();
    await _pump();
    expect(_ids(c), isEmpty);
  });

  test('SL / TP: the claim frame keeps the trade, the confirmed close removes it and reloads History', () async {
    final api = _Api();
    final c = await _box(api);
    final epoch0 = c.read(tradeEventEpochProvider);
    _frame(c, {..._openFrame('p1'), 'closing': true, 'execClaimKind': 'sl'});
    await _pump();
    expect(_ids(c), contains('p1'));
    _frame(c, {..._closedFrame('p1', profit: -12), 'reason': 'SL_HIT'});
    expect(_ids(c), ['p2', 'p3']);
    await _pump();
    expect(c.read(tradeEventEpochProvider), epoch0 + 1);
  });
}
