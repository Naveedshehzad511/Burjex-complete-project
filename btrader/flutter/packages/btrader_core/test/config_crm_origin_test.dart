import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local, LAN and quick-tunnel hosts use their own origin for the CRM', () {
    for (final h in ['localhost', '127.0.0.1', '192.168.0.100', '10.0.2.2', '172.20.1.5', 'relying-adams-sporting-leading.trycloudflare.com', 'ABC.TryCloudflare.com']) {
      expect(BtConfig.usesSameOriginCrm(h), isTrue, reason: h);
    }
  });

  test('production and look-alike hosts keep the production CRM', () {
    for (final h in ['portal.burjexprime.net', 'crm.burjexprime.net', 'evil.com', 'trycloudflare.com.evil.com', 'nottrycloudflare.com', '172.32.0.1']) {
      expect(BtConfig.usesSameOriginCrm(h), isFalse, reason: h);
    }
  });
}
