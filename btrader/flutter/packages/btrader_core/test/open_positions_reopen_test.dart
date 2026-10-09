import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chart is left (no listeners), the 30 s reconcile tick fires, the chart is opened again while
/// /positions is slow. The trades it already had must be there at once (lines never vanish), the
/// server's answer replaces them, and nothing from another account is ever replayed.
class _Api extends ApiClient {
  _Api() : super(AuthStore());
  Completer<void>? gate;
  final byAccount = <String, List<String>>{'A1': ['p1', 'p2', 'p3'], 'A2': ['q1']};
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path != '/positions') return <dynamic>[];
    final acct = query!['accountId'] as String;
    final snapshot = [...?byAccount[acct]];
    if (gate != null) await gate!.future;
    return [
      for (final id in snapshot)
        {'id': id, 'accountId': acct, 'side': 'BUY', 'volume': 0.1, 'openPrice': 1.1, 'symbol': 'EURUSD', 'openedAt': DateTime.now().toIso8601String()}
    ];
  }
}

ProviderContainer _box(_Api api, StreamController<int> tick) {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    openPositionsTickProvider.overrideWith((_) => tick.stream),
  ]);
  addTearDown(c.dispose);
  addTearDown(tick.close);
  return c;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 40));
List<String>? _ids(ProviderContainer c) => c.read(openPositionsProvider).valueOrNull?.map((p) => p.id).toList();

void main() {
  test('reopening after a tick fired with nobody listening keeps the last trades, then takes the server list', () async {
    final api = _Api();
    final tick = StreamController<int>();
    final c = _box(api, tick);
    var sub = c.listen(openPositionsProvider, (_, __) {}, fireImmediately: true);
    await c.read(openPositionsProvider.future);
    sub.close();
    await _pump();
    tick.add(1);
    await _pump();

    api.gate = Completer<void>();
    api.byAccount['A1'] = ['p1', 'p2', 'p3', 'p4']; // a trade opened meanwhile
    final seen = <List<String>?>[];
    sub = c.listen(openPositionsProvider, (_, n) => seen.add(n.valueOrNull?.map((p) => p.id).toList()), fireImmediately: true);
    await _pump();
    expect(_ids(c), ['p1', 'p2', 'p3'], reason: 'the last known trades are on screen while the refetch is in flight');
    expect(seen.every((s) => s != null), isTrue, reason: 'never an empty / value-less state');

    api.gate!.complete();
    await _pump();
    expect(_ids(c), ['p1', 'p2', 'p3', 'p4'], reason: 'the server list replaces the remembered one');
    sub.close();
  });

  test('a trade the server closed while away is not replayed', () async {
    final api = _Api();
    final tick = StreamController<int>();
    final c = _box(api, tick);
    var sub = c.listen(openPositionsProvider, (_, __) {}, fireImmediately: true);
    await c.read(openPositionsProvider.future);
    sub.close();
    await _pump();
    tick.add(1);
    c.read(closedPositionIdsProvider.notifier).add('p2');
    await _pump();
    api.gate = Completer<void>();
    sub = c.listen(openPositionsProvider, (_, __) {}, fireImmediately: true);
    await _pump();
    expect(_ids(c), ['p1', 'p3']);
    api.gate!.complete();
    await _pump();
    expect(_ids(c), ['p1', 'p3']);
    sub.close();
  });

  test('switching account never shows the other account\'s trades as current', () async {
    final api = _Api();
    final tick = StreamController<int>();
    final active = StateProvider<String?>((_) => 'A1');
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      activeAccountIdProvider.overrideWith((ref) => ref.watch(active)),
      openPositionsTickProvider.overrideWith((_) => tick.stream),
    ]);
    addTearDown(c.dispose);
    addTearDown(tick.close);
    final seen = <List<String>?>[];
    final sub = c.listen(openPositionsProvider, (_, n) => seen.add(n.valueOrNull?.map((p) => p.id).toList()), fireImmediately: true);
    await c.read(openPositionsProvider.future);
    expect(_ids(c), ['p1', 'p2', 'p3']);

    api.gate = Completer<void>();
    seen.clear();
    c.read(active.notifier).state = 'A2';
    await _pump();
    // (the one synchronous notification Riverpod makes carries the old list, but it is replaced in the
    // same microtask, before any frame can paint it)
    expect(_ids(c), isEmpty, reason: 'A1 trades must not stand in for A2 while A2 loads');
    expect(seen.last, isEmpty);
    api.gate!.complete();
    await _pump();
    expect(_ids(c), ['q1']);

    // back to A1: its own remembered list may be replayed, never A2's
    api.gate = Completer<void>();
    c.read(active.notifier).state = 'A1';
    await _pump();
    expect(_ids(c), ['p1', 'p2', 'p3']);
    api.gate!.complete();
    await _pump();
    sub.close();
  });
}
