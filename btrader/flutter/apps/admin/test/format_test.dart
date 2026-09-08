// Deterministic, network-free check that the shared formatting the admin UI
// relies on behaves as expected. A full-app render is intentionally avoided
// because the app boots live data providers (API/WebSocket).

import 'package:flutter_test/flutter_test.dart';
import 'package:btrader_core/btrader_core.dart';

void main() {
  test('money formatting used across admin screens', () {
    expect(money(1234.5), '1,234.50');
    expect(money(-50), '-50.00');
  });

  test('pct formatting carries an explicit sign', () {
    expect(pct(2.5), '+2.50%');
    expect(pct(-1), '-1.00%');
  });
}
