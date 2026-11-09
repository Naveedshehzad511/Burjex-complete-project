import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

Deal _d(String type, {double profit = 0, double swap = 0, double commission = 0, double amount = 0, double after = 0}) =>
    Deal.fromJson({
      'id': '$type$profit$amount$commission',
      'type': type,
      'profit': profit,
      'swap': swap,
      'commission': commission,
      'amount': amount,
      'balanceAfter': after,
      'createdAt': '2026-11-10T00:00:00Z',
    });

void main() {
  test('History summary: deposits, withdrawals, profit, swap, commission and balance, nothing twice', () {
    final t = historyTotals([
      // newest first, as /history/deals returns them
      _d('CLOSE', profit: -12.9, swap: -0.5, after: 1036.6),
      _d('OPEN', commission: -2, after: 1050),
      _d('WITHDRAWAL', amount: -10, after: 1052),
      _d('PARTIAL_CLOSE', profit: 20, swap: 1, commission: -1, after: 1062),
      _d('BONUS', amount: 40, after: 1042),
      _d('DEPOSIT', amount: 1000, after: 1002),
    ]);
    expect(t.deposit, 1040);
    expect(t.withdrawal, -10);
    expect(t.profit, closeTo(7.1, 1e-9));
    expect(t.swap, closeTo(0.5, 1e-9));
    expect(t.commission, -3); // the OPEN deal's plus the close that still carried one
    expect(t.balance, 1036.6); // the newest deal's balance after it
  });

  test('no deals: all zero', () {
    final t = historyTotals(const []);
    expect([t.deposit, t.withdrawal, t.profit, t.swap, t.commission, t.balance], everyElement(0));
  });
}
