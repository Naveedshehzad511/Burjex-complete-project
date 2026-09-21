import 'package:burjex_portal/portal_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to the live 5-tab portal', () {
    expect(PortalConfig.url, 'https://portal.burjexprime.net');
    expect(PortalConfig.title, 'Burjex Prime');
    expect(PortalConfig.uri.host, 'portal.burjexprime.net');
  });
}
