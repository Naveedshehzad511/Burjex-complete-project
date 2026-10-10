import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the socket tells us actually happened to a position - each event once.
void main() {
  Map<String, dynamic> live(String id, {double? sl, double? tp, bool withLevels = true}) => {
        'id': id,
        'status': 'OPEN',
        'profit': 1.0,
        if (withLevels) 'slPrice': sl,
        if (withLevels) 'tpPrice': tp,
      };

  TradeEventKind? feed(TradeEventDetector d, Map<String, dynamic> data, {String? id, bool closed = false, bool alreadyClosed = false}) =>
      d.onPosition(data, id: id ?? '${data['id']}', closed: closed, alreadyClosed: alreadyClosed);

  test('opened fires once per position, however many times the push repeats', () {
    final d = TradeEventDetector();
    final open = {'id': 'p1', 'opened': true, 'slPrice': 1.0, 'tpPrice': 2.0};
    expect(feed(d, open), TradeEventKind.opened);
    expect(feed(d, open), isNull);
  });

  test('closed fires once per position (the engine sends a closing frame and a closed frame)', () {
    final d = TradeEventDetector();
    final closing = {'id': 'p1', 'status': 'CLOSED', 'book': 'closed'};
    expect(feed(d, closing, closed: true, alreadyClosed: false), TradeEventKind.closed);
    expect(feed(d, closing, closed: true, alreadyClosed: true), isNull);
  });

  test('a position seen for the first time only sets the baseline: nothing fires on app start', () {
    final d = TradeEventDetector();
    expect(feed(d, live('p1', sl: 1.0, tp: 2.0)), isNull);
    expect(feed(d, live('p1', sl: 1.0, tp: 2.0)), isNull);
  });

  test('modified fires when SL or TP changes, set / moved / removed, and not otherwise', () {
    final d = TradeEventDetector();
    feed(d, live('p1', sl: null, tp: null));
    expect(feed(d, live('p1', sl: 1.5, tp: null)), TradeEventKind.modified, reason: 'SL set');
    expect(feed(d, live('p1', sl: 1.5, tp: null)), isNull, reason: 'unchanged');
    expect(feed(d, live('p1', sl: 1.5, tp: 2.5)), TradeEventKind.modified, reason: 'TP set');
    expect(feed(d, live('p1', sl: 1.6, tp: 2.5)), TradeEventKind.modified, reason: 'SL moved');
    expect(feed(d, live('p1', sl: null, tp: 2.5)), TradeEventKind.modified, reason: 'SL removed');
  });

  test('the opened push is the baseline: its own live frames do not look like a modification', () {
    final d = TradeEventDetector();
    feed(d, {'id': 'p1', 'opened': true, 'slPrice': 1.0, 'tpPrice': 2.0});
    expect(feed(d, live('p1', sl: 1.0, tp: 2.0)), isNull);
    expect(feed(d, live('p1', sl: 1.2, tp: 2.0)), TradeEventKind.modified);
  });

  test('frames without levels, and stale pings, never fire', () {
    final d = TradeEventDetector();
    feed(d, live('p1', sl: 1.0, tp: 2.0));
    expect(feed(d, live('p1', withLevels: false)), isNull);
    expect(feed(d, {'id': 'p1', 'stale': true}), isNull);
    expect(feed(d, live('p1', sl: 1.0, tp: 2.0)), isNull);
  });

  test('numbers sent as text or with float noise are the same level', () {
    final d = TradeEventDetector();
    feed(d, {'id': 'p1', 'slPrice': '1.10000', 'tpPrice': null});
    expect(feed(d, {'id': 'p1', 'slPrice': 1.1, 'tpPrice': null}), isNull);
  });

  test('a closed position forgets its levels, and positions are tracked independently', () {
    final d = TradeEventDetector();
    feed(d, live('a', sl: 1.0, tp: 2.0));
    feed(d, live('b', sl: 5.0, tp: 6.0));
    expect(feed(d, live('a', sl: 1.1, tp: 2.0)), TradeEventKind.modified);
    expect(feed(d, live('b', sl: 5.0, tp: 6.0)), isNull);
    feed(d, {'id': 'a', 'status': 'CLOSED'}, closed: true);
    expect(feed(d, live('a', sl: 9.0, tp: 9.0)), isNull, reason: 'back to baseline after a close');
  });
}
