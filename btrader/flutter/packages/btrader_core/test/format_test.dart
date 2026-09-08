// Unit tests for the shared price/money formatting used across both apps.
// Pure functions, no network — these guard the display contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:btrader_core/btrader_core.dart';

void main() {
  group('money', () {
    test('formats with thousands separator and 2 decimals', () {
      expect(money(1234.5), '1,234.50');
      expect(money(0), '0.00');
      expect(money(-1234.5), '-1,234.50');
    });
  });

  group('price', () {
    test('respects the symbol digit count', () {
      expect(price(1.23456, 2), '1.23');
      expect(price(1.1, 5), '1.10000');
    });
  });

  group('pct', () {
    test('always carries an explicit sign', () {
      expect(pct(1.2), '+1.20%');
      expect(pct(0), '+0.00%');
      expect(pct(-3.4), '-3.40%');
    });
  });

  group('mt5Price', () {
    test('splits a 5-digit fractional-pip price into normal/big/sup', () {
      final f = mt5Price(1.10379, 5);
      expect(f.normal, '1.10');
      expect(f.big, '37');
      expect(f.sup, '9');
    });

    test('has no superscript for whole-pip (2-digit) prices', () {
      final f = mt5Price(1234.56, 2);
      expect(f.sup, '');
      expect(f.big, '56');
      expect(f.normal, '1234.');
    });
  });

  group('Branding.fallback', () {
    test('provides safe defaults when no tenant branding is fetched', () {
      expect(Branding.fallback.appName, 'B-Trader');
      expect(Branding.fallback.baseCurrency, 'USD');
    });
  });
}
