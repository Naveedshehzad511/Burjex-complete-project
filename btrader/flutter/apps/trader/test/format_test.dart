// Deterministic, network-free check that the shared formatting the trader UI
// relies on behaves as expected. A full-app render is intentionally avoided
// because the app boots live data providers (API/WebSocket).

import 'package:flutter_test/flutter_test.dart';
import 'package:btrader_core/btrader_core.dart';

void main() {
  test('MT5 big-figure price split for a 5-digit symbol', () {
    final f = mt5Price(1.10379, 5);
    expect(f.normal, '1.10');
    expect(f.big, '37');
    expect(f.sup, '9');
  });

  test('money formatting used on the portfolio screen', () {
    expect(money(1234.5), '1,234.50');
    expect(money(-50), '-50.00');
  });
}
