import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:btrader_core/btrader_core.dart';

import 'package:forexten_mobile/config.dart';
import 'package:forexten_mobile/shell.dart';
import 'package:forexten_mobile/screens/login_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bottom nav matches live portal labels', () {
    expect(PortalTabs.labels, ['Home', 'Quotes', 'Chart', 'Trade', 'History']);
    expect(PortalTabs.labels.contains('Markets'), isFalse);
    expect(PortalTabs.labels.contains('Portfolio'), isFalse);
    expect(PortalTabs.labels.contains('Settings'), isFalse);
  });

  test('live portal hosts are the compiled defaults', () {
    PortalConfig.apply();
    expect(BtConfig.apiBase, 'https://portal.burjexprime.net');
    expect(BtConfig.wsUrl, 'wss://portal.burjexprime.net');
    expect(BtConfig.liveCrmHost, 'https://crm.burjexprime.net/api/v1');
    expect(BtConfig.tenant, isEmpty);
  });

  testWidgets('login is email/password only', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: LoginScreen())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Welcome to Burjex Prime'), findsOneWidget);
    expect(find.text('LOGIN'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
    expect(find.textContaining('Google'), findsNothing);
    expect(find.textContaining('Apple'), findsNothing);
  });
}
