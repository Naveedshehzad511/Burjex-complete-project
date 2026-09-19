import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

Position _p(String id, {String status = 'OPEN', double? sl, double? tp}) => Position(
      id: id,
      accountId: 'a1',
      side: 'BUY',
      status: status,
      volume: 0.1,
      openPrice: 1.1,
      slPrice: sl,
      tpPrice: tp,
      profit: 0,
      swap: 0,
      symbol: 'EURUSD',
      digits: 5,
      openedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('BUY/SELL SL/TP chart overlay', () {
    test('BUY and SELL rows keep SL/TP lines while OPEN or CLOSE_PENDING', () {
      final buy = _p('buy', sl: 1.09, tp: 1.12);
      final sell = _p('sell', sl: 1.13, tp: 1.08);
      final pending = _p('pend', status: 'CLOSE_PENDING', sl: 1.09, tp: 1.12);
      final overlay = overlayPositions([buy, sell, pending], {});
      expect(overlay.map((p) => p.id).toList(), ['buy', 'sell', 'pend']);
      expect(overlay.every((p) => p.slPrice != null && p.tpPrice != null), isTrue);
    });
  });

  group('execution wait does not remove chart yet', () {
    test('CLOSE_PENDING is not a close event', () {
      expect(
        positionEventIsClosed({'id': 'p1', 'status': 'CLOSE_PENDING', 'execDelayMs': 150}),
        isFalse,
      );
    });
  });

  group('duplicate close / stale OPEN', () {
    test('second CLOSED is still a close', () {
      expect(positionEventIsClosed({'id': 'p1', 'status': 'CLOSED', 'event': 'position_closed'}), isTrue);
      expect(positionEventIsClosed({'id': 'p1', 'status': 'CLOSED', 'reason': 'SL_HIT'}), isTrue);
      expect(positionEventIsClosed({'id': 'p1', 'status': 'CLOSED', 'reason': 'TP_HIT'}), isTrue);
    });
    test('stale OPEN cannot resurrect a closed id', () {
      expect(staleOpenBlocked('p1', {'id': 'p1', 'status': 'OPEN'}, {'p1'}), isTrue);
      expect(staleOpenBlocked('p1', {'id': 'p1', 'status': 'OPEN'}, {'p2'}), isFalse);
    });
  });

  group('reconnect snapshot', () {
    test('drops ids the server no longer has open', () {
      final localGone = _p('gone', sl: 1.0, tp: 2.0);
      final keep = _p('keep', sl: 1.0, tp: 2.0);
      final out = reconcileOpenSnapshot([keep, localGone], {'gone'});
      expect(out.map((p) => p.id).toList(), ['keep']);
    });
    test('empty snapshot clears the overlay', () {
      expect(reconcileOpenSnapshot(const [], {}), isEmpty);
    });
  });

  group('chart removal on position_closed', () {
    test('CLOSED event removes marker, SL line and TP line', () {
      final open = [_p('p1', sl: 1.09, tp: 1.12), _p('p2', sl: 1.1, tp: 1.2)];
      expect(overlayPositions(open, {}).length, 2);
      final after = overlayPositions(open, {'p1'});
      expect(after.map((p) => p.id).toList(), ['p2']);
      expect(after.single.slPrice, 1.1);
      expect(after.single.tpPrice, 1.2);
    });
    test('upsert of CLOSED-filtered id does not come back', () {
      final cur = [_p('p1', sl: 1.09, tp: 1.12)];
      final out = upsertLivePosition(cur, _p('p1', sl: 1.09, tp: 1.12), {'p1'});
      expect(out, isEmpty);
    });
  });
}
