import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/widgets/pending_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// SL / TP of an OPEN position are judged from the live Bid / Ask and the position's direction, not
/// from its open price (so a Buy can lock in profit with an SL above its entry, and a losing Buy can
/// take profit below its entry). Pending-order SL / TP stay judged from the order's entry.
///
/// Nothing here is a fixed threshold: every case is built from a base price, so the same rules are
/// exercised at forex, gold, JPY and crypto scales.

/// The engine's rule for a position (apps/trading-core-rs/src/trigger.rs `validate_sl_tp`), written
/// out independently so the app can be checked against what the server really accepts.
bool engineAcceptsSl(bool buy, double bid, double ask, double sl) => buy ? sl < bid : sl > ask;
bool engineAcceptsTp(bool buy, double bid, double ask, double tp) => buy ? tp > ask : tp < bid;

Tick quote(double bid, double spread) => Tick(symbol: 'X', bid: bid, ask: bid + spread, ts: 0);

Map<String, String> check(ChartEdit e, Tick? q) => e.errors(q, minLot: 0.01, maxLot: 100, lotStep: 0.01);

ChartEdit position(String side, double entry, {double? sl, double? tp}) => ChartEdit.position(id: 'p1', side: side, entry: entry, sl: sl, tp: tp);

/// (base price, spread) at several scales.
const scales = <(double, double)>[(1.1, 0.0002), (150.0, 0.02), (3000.0, 0.5), (85000.0, 12.0)];

void main() {
  group('open position - Buy', () {
    for (final (base, spread) in scales) {
      final entry = base;
      final bid = base * 1.12; // price moved up a lot: the position is well in profit
      final q = quote(bid, spread);
      final step = base * 0.01;

      test('SL below the Bid is valid - normal, below the entry (scale $base)', () {
        expect(check(position('BUY', entry, sl: entry - step), q).containsKey('sl'), isFalse);
      });

      test('SL ABOVE the entry but below the Bid is valid - locks in profit (scale $base)', () {
        final sl = entry + (bid - entry) * 0.5;
        expect(sl > entry && sl < bid, isTrue);
        expect(check(position('BUY', entry, sl: sl), q).containsKey('sl'), isFalse);
      });

      test('SL at or above the Bid is invalid (scale $base)', () {
        expect(check(position('BUY', entry, sl: bid), q)['sl'], 'Must be below the Bid');
        expect(check(position('BUY', entry, sl: bid + step), q)['sl'], 'Must be below the Bid');
      });

      test('TP above the Ask is valid (scale $base)', () {
        expect(check(position('BUY', entry, tp: q.ask + step), q).containsKey('tp'), isFalse);
      });

      test('TP at or below the Ask is invalid, even when it is above the entry (scale $base)', () {
        final tp = entry + (bid - entry) * 0.5; // above the entry, below the market
        expect(check(position('BUY', entry, tp: tp), q)['tp'], 'Must be above the Ask');
        expect(check(position('BUY', entry, tp: q.ask), q)['tp'], 'Must be above the Ask');
      });
    }

    test('a Buy that is IN LOSS may take profit below its entry, above the Ask', () {
      const entry = 2000.0;
      final q = quote(1800.0, 0.5); // price fell below the entry
      final tp = 1850.0; // below the entry, above the market
      expect(check(position('BUY', entry, tp: tp), q).containsKey('tp'), isFalse);
      // ...and an SL below the market (also below the entry) is valid
      expect(check(position('BUY', entry, sl: 1700.0), q).containsKey('sl'), isFalse);
      // an SL between the market and the entry is on the wrong side of the market
      expect(check(position('BUY', entry, sl: 1900.0), q)['sl'], 'Must be below the Bid');
    });
  });

  group('open position - Sell', () {
    for (final (base, spread) in scales) {
      final entry = base;
      final bid = base * 0.88; // price fell a lot: the Sell is well in profit
      final q = quote(bid, spread);
      final step = base * 0.01;

      test('SL above the Ask is valid - normal, above the entry (scale $base)', () {
        expect(check(position('SELL', entry, sl: entry + step), q).containsKey('sl'), isFalse);
      });

      test('SL BELOW the entry but above the Ask is valid - locks in profit (scale $base)', () {
        final sl = q.ask + (entry - q.ask) * 0.5;
        expect(sl < entry && sl > q.ask, isTrue);
        expect(check(position('SELL', entry, sl: sl), q).containsKey('sl'), isFalse);
      });

      test('SL at or below the Ask is invalid (scale $base)', () {
        expect(check(position('SELL', entry, sl: q.ask), q)['sl'], 'Must be above the Ask');
        expect(check(position('SELL', entry, sl: q.ask - step), q)['sl'], 'Must be above the Ask');
      });

      test('TP below the Bid is valid (scale $base)', () {
        expect(check(position('SELL', entry, tp: bid - step), q).containsKey('tp'), isFalse);
      });

      test('TP at or above the Bid is invalid, even when it is below the entry (scale $base)', () {
        final tp = bid + (entry - bid) * 0.5; // below the entry, above the market
        expect(check(position('SELL', entry, tp: tp), q)['tp'], 'Must be below the Bid');
        expect(check(position('SELL', entry, tp: bid), q)['tp'], 'Must be below the Bid');
      });
    }

    test('a Sell that is IN LOSS may take profit above its entry, below the Bid', () {
      const entry = 2000.0;
      final q = quote(2200.0, 0.5); // price rose above the entry
      expect(check(position('SELL', entry, tp: 2150.0), q).containsKey('tp'), isFalse);
      expect(check(position('SELL', entry, sl: 2300.0), q).containsKey('sl'), isFalse);
      expect(check(position('SELL', entry, sl: 2100.0), q)['sl'], 'Must be above the Ask');
    });
  });

  group('the app never accepts what the engine rejects', () {
    test('1,000 random positions / quotes / levels: UI verdict == engine verdict', () {
      final rnd = math.Random(42);
      var checked = 0;
      for (var i = 0; i < 1000; i++) {
        final base = 1 + rnd.nextDouble() * 90000;
        final buy = rnd.nextBool();
        final entry = base * (0.8 + rnd.nextDouble() * 0.4);
        final bid = base;
        final spread = base * (0.00005 + rnd.nextDouble() * 0.001);
        final ask = bid + spread;
        final level = base * (0.7 + rnd.nextDouble() * 0.6);
        final q = Tick(symbol: 'X', bid: bid, ask: ask, ts: 0);
        final slErr = check(position(buy ? 'BUY' : 'SELL', entry, sl: level), q).containsKey('sl');
        final tpErr = check(position(buy ? 'BUY' : 'SELL', entry, tp: level), q).containsKey('tp');
        expect(!slErr, engineAcceptsSl(buy, bid, ask, level), reason: 'SL buy=$buy entry=$entry bid=$bid ask=$ask level=$level');
        expect(!tpErr, engineAcceptsTp(buy, bid, ask, level), reason: 'TP buy=$buy entry=$entry bid=$bid ask=$ask level=$level');
        checked += 2;
      }
      expect(checked, 2000);
    });
  });

  group('no quote / unusable quote', () {
    test('without a quote only the price itself is validated; the server decides the rest', () {
      for (final side in ['BUY', 'SELL']) {
        expect(check(position(side, 100, sl: 50, tp: 150), null), isEmpty);
        expect(check(position(side, 100, sl: 150, tp: 50), null), isEmpty);
        expect(check(position(side, 100, sl: -1), null)['sl'], 'Invalid price');
        expect(check(position(side, 100, tp: 0), null)['tp'], 'Invalid price');
      }
    });

    test('a quote with no real Bid / Ask counts as no quote', () {
      final dead = Tick(symbol: 'X', bid: 0, ask: 0, ts: 0);
      expect(check(position('BUY', 100, sl: 150, tp: 50), dead), isEmpty);
    });

    test('no SL / TP at all is always fine', () {
      expect(check(position('BUY', 100), quote(110, 0.1)), isEmpty);
      expect(check(position('SELL', 100), null), isEmpty);
    });
  });

  group('pending orders are unchanged - SL / TP judged from the order entry, never from the market', () {
    // Wildly different quotes must not change a pending order's SL / TP verdict.
    final quotes = <Tick?>[null, quote(1.0, 0.0002), quote(50.0, 0.0002), quote(5.0, 0.0002)];

    ChartEdit order(String type, String side, double entry, {double? sl, double? tp}) =>
        ChartEdit.order(id: 'o1', orderType: type, side: side, entry: entry, sl: sl, tp: tp, volume: 0.1);

    test('Buy Limit: SL below the entry, TP above the entry', () {
      for (final q in quotes) {
        expect(check(order('BUY_LIMIT', 'BUY', 1.05, sl: 1.04, tp: 1.06), q).containsKey('sl'), isFalse);
        expect(check(order('BUY_LIMIT', 'BUY', 1.05, sl: 1.04, tp: 1.06), q).containsKey('tp'), isFalse);
        expect(check(order('BUY_LIMIT', 'BUY', 1.05, sl: 1.06), q)['sl'], 'Must be below the entry');
        expect(check(order('BUY_LIMIT', 'BUY', 1.05, tp: 1.04), q)['tp'], 'Must be above the entry');
      }
    });

    test('Sell Stop: SL above the entry, TP below the entry', () {
      for (final q in quotes) {
        expect(check(order('SELL_STOP', 'SELL', 0.95, sl: 0.96, tp: 0.94), q).containsKey('sl'), isFalse);
        expect(check(order('SELL_STOP', 'SELL', 0.95, sl: 0.94), q)['sl'], 'Must be above the entry');
        expect(check(order('SELL_STOP', 'SELL', 0.95, tp: 0.96), q)['tp'], 'Must be below the entry');
      }
    });

    test('Buy Stop Limit is judged from its limit price', () {
      ChartEdit sl(double? slv, double? tpv) => ChartEdit.order(
          id: 'o1', orderType: 'STOP_LIMIT', side: 'BUY', entry: 1.10, limit: 1.09, sl: slv, tp: tpv, volume: 0.1);
      expect(check(sl(1.085, 1.095), null).containsKey('sl'), isFalse);
      expect(check(sl(1.095, null), null)['sl'], 'Must be below the limit');
      expect(check(sl(null, 1.085), null)['tp'], 'Must be above the limit');
    });

    test('a draft pending order behaves the same (entry based)', () {
      final d = ChartEdit.draft(type: OrderType.buyLimit, volume: 0.1, entry: 1.05)..sl = 1.06;
      expect(check(d, quote(1.2, 0.0002))['sl'], 'Must be below the entry');
    });
  });
}
