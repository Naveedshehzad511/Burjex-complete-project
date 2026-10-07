import 'dart:convert';
import 'dart:typed_data';

import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/widgets/account_actions.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A CRM stand-in: records every request and answers like the real endpoints.
class _FakeCrm implements HttpClientAdapter {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  int leverageNow = 500;
  bool badCode = false;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    calls.add('${o.method} ${o.path}');
    final data = o.data is Map ? (o.data as Map).cast<String, dynamic>() : <String, dynamic>{};
    bodies.add(data);
    Map<String, dynamic> ok(Map<String, dynamic> d, [String m = 'ok']) => {'success': true, 'message': m, 'data': d};
    var status = 200;
    Map<String, dynamic> out;
    if (o.path.endsWith('/leverage/') && o.method == 'GET') {
      out = ok({'current_leverage': leverageNow, 'max_allowed': 1000, 'options': [100, 200, 500, 1000], 'trading_enabled': true});
    } else if (o.path.endsWith('/leverage/')) {
      leverageNow = data['leverage'] as int;
      out = ok({'leverage': leverageNow}, 'Leverage updated successfully.');
    } else if (data['action'] == 'request_otp') {
      out = ok({'otp_requested': true}, 'OTP sent to your email.');
    } else if (badCode) {
      status = 400;
      out = {'success': false, 'message': 'Invalid OTP.'};
    } else {
      out = ok({}, 'Password changed successfully.');
    }
    return ResponseBody.fromString(jsonEncode(out), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

CrmAccount _account({bool trading = true}) => CrmAccount.fromJson({
      'login_id': '500002',
      'account_type': 'Real (BTrader) — Standard1',
      'is_demo': false,
      'balance': 6612.5,
      'equity': 6612.5,
      'leverage': 500,
      'trading_enabled': trading,
    });

Future<_FakeCrm> _pump(WidgetTester t, CrmAccount a) async {
  final fake = _FakeCrm();
  final dio = Dio(BaseOptions(baseUrl: 'http://crm.test'))..httpClientAdapter = fake;
  await t.pumpWidget(ProviderScope(
    overrides: [crmDioProvider.overrideWithValue(dio)],
    child: MaterialApp(home: Scaffold(body: Center(child: AccountMenuButton(account: a)))),
  ));
  return fake;
}

Future<void> _open(WidgetTester t, String item) async {
  await t.tap(find.byIcon(Icons.more_vert));
  await t.pumpAndSettle();
  await t.tap(find.text(item));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the 3-dot menu offers trading password, investor password and leverage', (t) async {
    await _pump(t, _account());
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.text('Change trading password'), findsOneWidget);
    expect(find.text('Change investor password'), findsOneWidget);
    expect(find.text('Change leverage'), findsOneWidget);
  });

  testWidgets('leverage: loads the allowed options and saves the chosen one', (t) async {
    final fake = await _pump(t, _account());
    await _open(t, 'Change leverage');
    expect(fake.calls, ['GET /accounts/500002/leverage/']);
    await t.tap(find.byType(DropdownButtonFormField<int>));
    await t.pumpAndSettle();
    await t.tap(find.text('1:1000').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Update'));
    await t.pumpAndSettle();
    expect(fake.calls.last, 'POST /accounts/500002/leverage/');
    expect(fake.bodies.last, {'leverage': 1000});
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('leverage is not offered while trading is disabled', (t) async {
    await _pump(t, _account(trading: false));
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    final item = t.widget<PopupMenuItem<AccountAction>>(find.widgetWithText(PopupMenuItem<AccountAction>, 'Change leverage'));
    expect(item.enabled, isFalse);
  });

  for (final mode in ['trading', 'investor']) {
    testWidgets('$mode password: request a code, then change it with the code', (t) async {
      final fake = await _pump(t, _account());
      await _open(t, 'Change $mode password');
      await t.enterText(find.widgetWithText(TextField, 'New $mode password'), 'NewPass123');
      await t.enterText(find.widgetWithText(TextField, 'Confirm new password'), 'NewPass123');
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(fake.calls.last, 'POST /accounts/500002/credential/$mode/');
      expect(fake.bodies.last['action'], 'request_otp');
      // Step two: the code field appears, the passwords are locked.
      expect(find.text('Verification code'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'Verification code'), '123456');
      await t.tap(find.text('Change password'));
      await t.pumpAndSettle();
      expect(fake.bodies.last, {
        'action': 'verify_otp',
        'otp_code': '123456',
        'new_password': 'NewPass123',
        'confirm_password': 'NewPass123',
      });
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('password: a mismatch or a short password never reaches the server', (t) async {
    final fake = await _pump(t, _account());
    await _open(t, 'Change trading password');
    await t.enterText(find.widgetWithText(TextField, 'New trading password'), 'NewPass123');
    await t.enterText(find.widgetWithText(TextField, 'Confirm new password'), 'Different1');
    await t.tap(find.text('Send code'));
    await t.pumpAndSettle();
    expect(find.text('Password confirmation does not match.'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'New trading password'), 'abc');
    await t.enterText(find.widgetWithText(TextField, 'Confirm new password'), 'abc');
    await t.tap(find.text('Send code'));
    await t.pumpAndSettle();
    expect(find.text('Password must be at least 6 characters.'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets('password: a wrong code shows the server message and keeps the dialog open', (t) async {
    final fake = await _pump(t, _account());
    await _open(t, 'Change investor password');
    await t.enterText(find.widgetWithText(TextField, 'New investor password'), 'NewPass123');
    await t.enterText(find.widgetWithText(TextField, 'Confirm new password'), 'NewPass123');
    await t.tap(find.text('Send code'));
    await t.pumpAndSettle();
    fake.badCode = true;
    await t.enterText(find.widgetWithText(TextField, 'Verification code'), '000000');
    await t.tap(find.text('Change password'));
    await t.pumpAndSettle();
    expect(find.text('Invalid OTP.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
