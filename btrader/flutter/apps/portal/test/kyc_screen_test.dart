import 'dart:convert';
import 'dart:typed_data';

import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/screens/kyc_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _status({Map<String, dynamic> extra = const {}}) => {
      'kyc_status': 'PENDING',
      'kyc_reject_reason': '',
      'identity_status_ui': 'Not Submitted',
      'address_status_ui': 'Not Submitted',
      'bank_status_ui': 'Not Submitted',
      'crypto_status_ui': 'Not Submitted',
      'identity_can_upload': true,
      'bank_can_submit': true,
      'crypto_can_submit': true,
      'identity_document_options': [
        {'id': 1, 'name': 'Passport'},
        {'id': 2, 'name': 'Driving License'},
        {'id': 3, 'name': 'National ID Card'},
      ],
      'crypto_network_options': [
        {'id': 1, 'label': 'USDT TRC20', 'code': 'USDT_TRC20'},
        {'id': 2, 'label': 'USDT ERC20', 'code': 'USDT_ERC20'},
        {'id': 3, 'label': 'USDT BEP20', 'code': 'USDT_BEP20'},
      ],
      'bank_field_settings': [
        {'field_key': 'account_name', 'label': 'Account Name', 'is_required': true},
        {'field_key': 'account_number', 'label': 'Account Number', 'is_required': true},
        {'field_key': 'iban', 'label': 'IBAN', 'is_required': false},
        {'field_key': 'swift_code', 'label': 'Swift Code', 'is_required': false},
        {'field_key': 'bank_name', 'label': 'Bank Name', 'is_required': true},
        {'field_key': 'country', 'label': 'Country', 'is_required': true},
      ],
      ...extra,
    };

class _FakeCrm implements HttpClientAdapter {
  _FakeCrm(this.status);
  Map<String, dynamic> status;
  final posts = <Map<String, dynamic>>[];
  int statusCalls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    Map<String, dynamic> out;
    if (o.path.endsWith('/kyc/status/')) {
      statusCalls++;
      out = {'success': true, 'data': status};
    } else if (o.path.endsWith('/kyc/upload/')) {
      posts.add(o.data is Map ? (o.data as Map).cast<String, dynamic>() : {'_form': true});
      out = {'success': true, 'message': 'Saved.', 'data': status};
    } else {
      out = {'success': true, 'data': {}};
    }
    return ResponseBody.fromString(jsonEncode(out), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

Future<_FakeCrm> _pump(WidgetTester t, Map<String, dynamic> status) async {
  t.view
    ..physicalSize = const Size(420, 1600)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fake = _FakeCrm(status);
  final dio = Dio(BaseOptions(baseUrl: 'http://crm.test'))..httpClientAdapter = fake;
  await t.pumpWidget(ProviderScope(
    overrides: [crmDioProvider.overrideWithValue(dio)],
    child: const MaterialApp(home: KycScreen()),
  ));
  await t.pumpAndSettle();
  return fake;
}

void main() {
  group('what the CRM offers', () {
    test('document types and networks come from the CRM, with the website lists as the fallback', () {
      expect(kycIdentityTypes(_status()), ['Passport', 'Driving License', 'National ID Card']);
      expect(kycCryptoNetworks(_status()), ['USDT TRC20', 'USDT ERC20', 'USDT BEP20']);
      expect(kycIdentityTypes({}), ['National ID', 'Passport', 'Driving License']);
      expect(kycCryptoNetworks({}), contains('USDT TRC20'));
    });

    test('a passport is one page, every other document needs a back', () {
      expect(kycBackRequired('Passport'), isFalse);
      expect(kycBackRequired('passport'), isFalse);
      expect(kycBackRequired('Driving License'), isTrue);
      expect(kycBackRequired('National ID Card'), isTrue);
    });

    test('bank fields follow the admin settings: labels, required flags, and only what is enabled', () {
      final f = {for (final x in kycBankFields(_status())) x.key: x};
      expect(f.keys, ['account_name', 'bank_name', 'account_number', 'iban', 'swift_code', 'bank_country']);
      expect(f['account_name']!.label, 'Account Name');
      expect(f['iban']!.required, isFalse);
      expect(f['bank_country']!.required, isTrue);
      final trimmed = kycBankFields({
        'bank_field_settings': [
          {'field_key': 'account_name', 'label': 'Holder', 'is_required': true},
          {'field_key': 'bank_name', 'label': 'Bank', 'is_required': true},
          {'field_key': 'iban', 'label': 'IBAN', 'is_required': false},
        ],
      });
      expect(trimmed.map((x) => x.key), ['account_name', 'bank_name', 'iban']);
      expect(kycBankFields({}).map((x) => x.key), ['account_name', 'bank_name', 'account_number', 'iban', 'swift_code', 'bank_country']);
    });
  });

  testWidgets('the screen shows identity, bank and crypto - and no address', (t) async {
    await _pump(t, _status());
    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Bank account'), findsOneWidget);
    expect(find.text('Crypto wallet'), findsOneWidget);
    expect(find.text('Address'), findsNothing);
    expect(find.text('Upload documents'), findsOneWidget);
    expect(find.text('Add bank account'), findsOneWidget);
    expect(find.text('Add crypto wallet'), findsOneWidget);
  });

  testWidgets('a submitted identity under review offers no upload', (t) async {
    await _pump(t, _status(extra: {
      'identity_status_ui': 'Pending',
      'identity_can_upload': false,
      'identity_latest': {'document_type': 'Passport'},
    }));
    expect(find.text('Upload documents'), findsNothing);
    expect(find.text('Your documents are under review.'), findsOneWidget);
    expect(find.text('Document: Passport'), findsOneWidget);
  });

  testWidgets('identity: type list from the CRM, front and back asked for, nothing sent without them', (t) async {
    final fake = await _pump(t, _status());
    await t.tap(find.text('Upload documents'));
    await t.pumpAndSettle();
    expect(find.text('Upload document (Front) *'), findsOneWidget);
    // Passport is the default and is a single page.
    expect(find.text('Upload document (Back, if any)'), findsOneWidget);
    await t.tap(find.text('Passport'));
    await t.pumpAndSettle();
    expect(find.text('Driving License'), findsOneWidget);
    expect(find.text('National ID Card'), findsOneWidget);
    await t.tap(find.text('Driving License').last);
    await t.pumpAndSettle();
    expect(find.text('Upload document (Back) *'), findsOneWidget);
    await t.tap(find.text('Submit'));
    await t.pumpAndSettle();
    expect(find.text('Upload the front of your document.'), findsOneWidget);
    expect(fake.posts, isEmpty);
  });

  testWidgets('bank: every field the admin enabled is asked for, and the required ones are enforced', (t) async {
    final fake = await _pump(t, _status());
    await t.tap(find.text('Add bank account'));
    await t.pumpAndSettle();
    for (final l in ['Account Name *', 'Bank Name *', 'Account Number *', 'IBAN', 'Swift Code', 'Country *']) {
      expect(find.widgetWithText(TextField, l), findsOneWidget, reason: l);
    }
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Account Name is required.'), findsOneWidget);
    expect(fake.posts, isEmpty);
    await t.enterText(find.widgetWithText(TextField, 'Account Name *'), 'Naveed');
    await t.enterText(find.widgetWithText(TextField, 'Bank Name *'), 'UBL');
    await t.enterText(find.widgetWithText(TextField, 'Country *'), 'Pakistan');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Enter an account number or an IBAN.'), findsOneWidget);
    expect(fake.posts, isEmpty);
  });

  testWidgets('bank: a complete form is sent with the names the CRM expects', (t) async {
    final fake = await _pump(t, _status());
    await t.tap(find.text('Add bank account'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Account Name *'), 'Naveed');
    await t.enterText(find.widgetWithText(TextField, 'Bank Name *'), 'UBL');
    await t.enterText(find.widgetWithText(TextField, 'Account Number *'), '353668216');
    await t.enterText(find.widgetWithText(TextField, 'IBAN'), 'PK38UNIL0109000353668216');
    await t.enterText(find.widgetWithText(TextField, 'Country *'), 'Pakistan');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(fake.posts, hasLength(1));
    expect(fake.posts.single, {
      'action': 'submit_bank',
      'account_name': 'Naveed',
      'bank_name': 'UBL',
      'account_number': '353668216',
      'iban': 'PK38UNIL0109000353668216',
      'swift_code': '',
      'bank_country': 'Pakistan',
    });
    expect(find.text('Saved.'), findsOneWidget); // the CRM's own message, then the list refreshes
    expect(fake.statusCalls, greaterThan(1));
  });

  testWidgets('crypto: pick a network, enter the address, save', (t) async {
    final fake = await _pump(t, _status());
    await t.tap(find.text('Add crypto wallet'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Enter your wallet address.'), findsOneWidget);
    expect(fake.posts, isEmpty);
    await t.tap(find.text('USDT TRC20'));
    await t.pumpAndSettle();
    expect(find.text('USDT ERC20'), findsOneWidget);
    expect(find.text('USDT BEP20'), findsOneWidget);
    await t.tap(find.text('USDT BEP20').last);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Wallet Address *'), '0xAbC123');
    await t.enterText(find.widgetWithText(TextField, 'Wallet Name (optional label)'), 'My wallet');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(fake.posts.single, {
      'action': 'submit_crypto',
      'crypto_network': 'USDT BEP20',
      'wallet_address': '0xAbC123',
      'wallet_name': 'My wallet',
    });
  });

  testWidgets('a saved bank and wallet are shown, and another can be added while slots remain', (t) async {
    await _pump(t, _status(extra: {
      'bank_status_ui': 'Approved',
      'bank_latest': {'bank_name': 'UBL', 'account_name': 'Naveed', 'account_number': '353668216'},
      'crypto_status_ui': 'Approved',
      'crypto_latest': {'network': 'USDT TRC20', 'wallet_address': 'TXyz'},
    }));
    expect(find.text('UBL'), findsOneWidget);
    expect(find.text('353668216'), findsOneWidget);
    expect(find.text('TXyz'), findsOneWidget);
    expect(find.text('Add another'), findsNWidgets(2));
  });
}
