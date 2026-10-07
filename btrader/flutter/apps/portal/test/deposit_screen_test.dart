import 'dart:convert';
import 'dart:typed_data';

import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/screens/deposit_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _gw(int id, String name, String profile, {Map<String, dynamic> extra = const {}}) => {
      'id': id,
      'name': name,
      'profile': profile,
      'payment_method': profile == 'CRYPTO' ? 'CRYPTO' : 'BANK',
      'currency': 'USD',
      'min_amount': '10.00',
      'processing_time': 'Instant',
      'charges': '',
      'instructions': '',
      'require_payment_proof': false,
      'can_use': true,
      'exchange_rate': '1',
      'display_badge': '',
      'icon': '',
      ...extra,
    };

/// A CRM stand-in answering `/deposits/methods/`, `/wallet/` and the two deposit POSTs.
class _FakeCrm implements HttpClientAdapter {
  _FakeCrm(this.gateways);
  List<Map<String, dynamic>> gateways;
  final posts = <String>[];
  Map<String, dynamic>? lastJson;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    Map<String, dynamic> ok(Object d, [String m = 'ok']) => {'success': true, 'message': m, 'data': d};
    Map<String, dynamic> out;
    if (o.method == 'GET' && o.path.endsWith('/deposits/methods/')) {
      out = ok({
        'allowed': true,
        'gateways': gateways,
        'trading_accounts': [
          {'login_id': '100662', 'balance': '3.00'},
          {'login_id': '100648', 'balance': '4.52'},
        ],
        'crypto_networks': [
          {'network': 'TRC20', 'label': 'USDT TRC20'},
          {'network': 'ERC20', 'label': 'USDT ERC20'},
          {'network': 'BEP20', 'label': 'USDT BEP20'},
        ],
      });
    } else if (o.method == 'GET' && o.path.endsWith('/wallet/')) {
      out = ok({'available_balance': '4.20'});
    } else if (o.path.endsWith('/deposits/crypto/')) {
      posts.add('crypto');
      lastJson = (o.data as Map).cast<String, dynamic>();
      out = ok({
        'payment_id': 'p1',
        'address': 'TDUpeS3xLWRUu3Pbhn8H7cB',
        'network': 'TRC20',
        'amount': '50.00',
        'currency': 'USDT',
        'checkout_url': 'https://pay.example/checkout/p1',
      });
    } else {
      posts.add('manual');
      out = ok({'status': 'PENDING'}, 'Deposit request submitted successfully.');
    }
    return ResponseBody.fromString(jsonEncode(out), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

final launched = <Uri>[];

Future<_FakeCrm> _pump(WidgetTester t, List<Map<String, dynamic>> gateways) async {
  launched.clear();
  depositLauncher = (u) async {
    launched.add(u);
    return true;
  };
  t.view
    ..physicalSize = const Size(420, 2200)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fake = _FakeCrm(gateways);
  final dio = Dio(BaseOptions(baseUrl: 'http://crm.test'))..httpClientAdapter = fake;
  await t.pumpWidget(ProviderScope(
    overrides: [crmDioProvider.overrideWithValue(dio)],
    child: const MaterialApp(home: DepositScreen()),
  ));
  await t.pumpAndSettle();
  return fake;
}

final _bank = _gw(1, 'UBL', 'MANUAL', extra: {
  'bank_name': 'UBL Bank limited',
  'account_name': 'Naveed Commission shop',
  'account_number': '353668216',
  'iban': 'PK38UNIL0109000353668216',
  'processing_time': '1-5 Hours',
  'currency': 'PKR',
  'exchange_rate': '281',
  'min_amount': '10.00',
});
final _upi = _gw(2, 'SmilePayz UPI', 'MANUAL', extra: {'processing_time': 'Instant'});
final _usdt = _gw(3, 'USDT', 'MATCH2PAY', extra: {
  'currency': 'USDT',
  'min_amount': '0.00',
  'networks': [
    {'network': 'TRC20', 'label': 'USDT TRC20'},
    {'network': 'ERC20', 'label': 'USDT ERC20'},
    {'network': 'BEP20', 'label': 'USDT BEP20'},
  ],
});
final _btc = _gw(7, 'Bitcoin', 'MATCH2PAY', extra: {
  'currency': 'BTC',
  'networks': [
    {'network': 'BTC', 'label': 'Bitcoin'},
  ],
});
final _wallet = _gw(4, 'TRX Wallet', 'CRYPTO', extra: {'currency': 'USDT', 'network': 'TRC20', 'wallet_address': 'TXyz123wallet'});

void main() {
  group('DepositMethod rules', () {
    test('a slip is needed for manual methods, never for a provider, and for crypto only if the admin says so', () {
      DepositMethod m(Map<String, dynamic> j) => DepositMethod.fromJson(j);
      expect(m(_bank).needsProof, isTrue);
      expect(m(_usdt).needsProof, isFalse);
      expect(m(_wallet).needsProof, isFalse);
      expect(m({..._wallet, 'require_payment_proof': true}).needsProof, isTrue);
      expect(m({..._usdt, 'require_payment_proof': true}).needsProof, isFalse); // provider pages take no slip
    });

    test('the local amount follows the rate, and only where there is something to convert', () {
      DepositMethod m(Map<String, dynamic> j) => DepositMethod.fromJson(j);
      expect(m(_bank).localAmount(20), 5620);
      expect(m({..._bank, 'currency': 'USD'}).localAmount(20), isNull);
      expect(m({..._bank, 'exchange_rate': '1'}).localAmount(20), isNull);
      expect(m({..._bank, 'exchange_rate': '0'}).localAmount(20), isNull);
      expect(m(_usdt).localAmount(20), isNull);
    });
  });

  testWidgets('every method the admin configured is a card; one under maintenance cannot be chosen', (t) async {
    await _pump(t, [_bank, _usdt, _gw(9, 'Old Bank', 'MANUAL', extra: {'can_use': false})]);
    expect(find.byKey(const ValueKey('deposit-method-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('deposit-method-3')), findsOneWidget);
    expect(find.text('Under maintenance'), findsOneWidget);
    expect(find.text('Min: 10.00 PKR'), findsOneWidget);
    expect(find.text('Processing: 1-5 Hours'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('deposit-method-9')));
    await t.pumpAndSettle();
    expect(find.text('Old Bank'), findsOneWidget); // still just its card, not selected
  });

  testWidgets('a bank method shows exactly the details the admin entered, the accounts, and the slip', (t) async {
    await _pump(t, [_bank, _usdt]);
    expect(find.text('Bank Details'), findsOneWidget);
    expect(find.textContaining('UBL Bank limited'), findsOneWidget);
    expect(find.textContaining('Naveed Commission shop'), findsOneWidget);
    expect(find.textContaining('353668216'), findsWidgets);
    expect(find.textContaining('PK38UNIL0109000353668216'), findsOneWidget);
    expect(find.text('My Wallet — 4.20 USD'), findsOneWidget);
    expect(find.text('Upload slip *'), findsOneWidget);
    expect(find.text('Deposit Now'), findsOneWidget);
  });

  testWidgets('changing the details in the CRM changes the screen (nothing is hard-coded)', (t) async {
    await _pump(t, [
      {..._bank, 'bank_name': 'HBL Test Bank', 'account_name': 'Someone Else', 'account_number': '99887766'},
    ]);
    expect(find.textContaining('HBL Test Bank'), findsOneWidget);
    expect(find.textContaining('Someone Else'), findsOneWidget);
    expect(find.textContaining('UBL Bank limited'), findsNothing);
  });

  testWidgets('the amount shows what the client will send in the method currency', (t) async {
    await _pump(t, [_bank]);
    await t.enterText(find.widgetWithText(TextField, 'Amount (USD) *'), '20');
    await t.pump();
    expect(find.textContaining('5,620.00 PKR'), findsOneWidget);
    expect(find.textContaining('Rate: 1 USD = 281.00 PKR'), findsOneWidget);
  });

  testWidgets('a manual deposit cannot be sent without the slip', (t) async {
    final fake = await _pump(t, [_bank]);
    await t.enterText(find.widgetWithText(TextField, 'Amount (USD) *'), '20');
    await t.tap(find.text('Deposit Now'));
    await t.pumpAndSettle();
    expect(find.text('Upload your payment slip for this method.'), findsOneWidget);
    expect(fake.posts, isEmpty);
  });

  testWidgets('a provider (crypto) method has no slip, picks a network and creates the payment', (t) async {
    final fake = await _pump(t, [_usdt, _bank]);
    expect(find.text('Upload slip *'), findsNothing);
    expect(find.text('Transaction ID'), findsNothing);
    expect(find.text('Notes'), findsNothing);
    expect(find.text('Select Method *'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Amount *'), '50');
    await t.tap(find.text('Submit'));
    await t.pumpAndSettle();
    expect(fake.posts, ['crypto']);
    expect(fake.lastJson!['crypto_network'], 'TRC20');
    expect(fake.lastJson!['trading_account'], 'wallet');
    expect(fake.lastJson!['gateway'], 3);
    expect(find.text('Send cryptocurrency'), findsOneWidget);
    expect(find.textContaining('TDUpeS3xLWRUu3Pbhn8H7cB'), findsOneWidget);
    expect(find.text('Open payment page'), findsOneWidget);
    // Straight on to the payment gateway, like the website.
    expect(launched.map((u) => u.toString()), ['https://pay.example/checkout/p1']);
  });

  testWidgets('every network the CRM offers for the method can be chosen and is what gets sent', (t) async {
    for (final net in ['ERC20', 'BEP20', 'TRC20']) {
      final fake = await _pump(t, [_usdt]);
      await t.tap(find.text('USDT TRC20'));
      await t.pumpAndSettle();
      expect(find.text('USDT ERC20'), findsOneWidget);
      expect(find.text('USDT BEP20'), findsOneWidget);
      await t.tap(find.text('USDT $net').last);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Amount *'), '25');
      await t.tap(find.text('Submit'));
      await t.pumpAndSettle();
      expect(fake.lastJson!['crypto_network'], net);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a method with its own networks (Bitcoin) shows only those', (t) async {
    await _pump(t, [_btc, _usdt]);
    expect(find.text('Bitcoin'), findsWidgets);
    await t.tap(find.text('Bitcoin').last);
    await t.pumpAndSettle();
    await t.tap(find.byType(DropdownButtonFormField<String>).last);
    await t.pumpAndSettle();
    expect(find.text('USDT ERC20'), findsNothing);
  });

  testWidgets('method cards in a row are the same height', (t) async {
    await _pump(t, [_bank, _upi, _usdt, _gw(9, 'Old Bank', 'MANUAL', extra: {'can_use': false})]);
    double h(int id) => t.getSize(find.byKey(ValueKey('deposit-method-$id'))).height;
    expect(h(1), h(2)); // UBL (no badge) beside SmilePayz (badge)
    expect(h(3), h(9)); // USDT beside the maintenance card
  });

  testWidgets('a fixed crypto wallet shows its address and asks for a slip only if the admin requires one', (t) async {
    await _pump(t, [_wallet]);
    expect(find.text('Crypto payment details'), findsOneWidget);
    expect(find.textContaining('TXyz123wallet'), findsOneWidget);
    expect(find.text('Upload slip *'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await _pump(t, [
      {..._wallet, 'require_payment_proof': true},
    ]);
    expect(find.text('Upload slip *'), findsOneWidget);
  });

  testWidgets('the selected method follows the tap and the form follows the method', (t) async {
    await _pump(t, [_bank, _usdt]);
    expect(find.text('Bank Details'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('deposit-method-3')));
    await t.pumpAndSettle();
    expect(find.text('Bank Details'), findsNothing);
    expect(find.text('Upload slip *'), findsNothing);
    expect(find.text('Select Method *'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('deposit-method-1')));
    await t.pumpAndSettle();
    expect(find.text('Bank Details'), findsOneWidget);
  });

  testWidgets('the account list offers the wallet and every live account with its balance', (t) async {
    await _pump(t, [_bank]);
    await t.tap(find.text('My Wallet — 4.20 USD'));
    await t.pumpAndSettle();
    expect(find.text('100662 — Balance 3.00'), findsOneWidget);
    expect(find.text('100648 — Balance 4.52'), findsOneWidget);
  });
}
