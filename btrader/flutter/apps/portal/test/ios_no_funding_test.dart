import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/ib_screens.dart' show IbState, ibStateProvider;
import 'package:burjex_portal/state/crypto_policy.dart';
import 'package:burjex_portal/widgets/portal_drawer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// App Store guideline 3.2.2(viii): the iPhone / iPad app has no deposit or withdrawal, nor their history or reports;
/// Android and the website keep them.

final _key = GlobalKey<ScaffoldState>();

Future<void> _openDrawer(WidgetTester t) async {
  t.view.physicalSize = const Size(390, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [ibStateProvider.overrideWith((ref) async => IbState.approved)],
    child: MaterialApp(
      theme: AppTheme.light(Branding.fallback),
      home: Scaffold(key: _key, drawer: const PortalDrawer(), body: const SizedBox()),
    ),
  ));
  _key.currentState!.openDrawer();
  await t.pumpAndSettle();
}

Future<void> _expand(WidgetTester t, String group) async {
  await t.tap(find.text(group));
  await t.pumpAndSettle();
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('iPhone / iPad', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('every funding route and funding report leads Home', () {
      expect(hideFunding, isTrue);
      for (final r in [...kFundingRoutes, ...kFundingHistoryRoutes]) {
        expect(fundingRedirect(r), '/home', reason: r);
      }
      for (final r in ['/home', '/trade', '/chart', '/history', '/kyc', '/ib/dashboard', '/p/report-deals', '/p/report-summary']) {
        expect(fundingRedirect(r), isNull, reason: r);
      }
    });

    test('deposit / withdrawal / transfer fields are left out of the reports', () {
      for (final k in ['total_deposits', 'total_withdrawals', 'deposit', 'Withdraw', 'transfers', 'payout_method', 'wallet_balance']) {
        expect(isFundingField(k), isTrue, reason: k);
      }
      for (final k in ['net_profit', 'total_orders', 'total_volume', 'balance', 'equity', 'accounts_count']) {
        expect(isFundingField(k), isFalse, reason: k);
      }
    });
  });

  testWidgets('iPhone / iPad: the menu has no deposit, withdrawal, wallet, transfer or their history', (t) async {
    await _openDrawer(t);
    expect(find.text('My Fund'), findsNothing);
    expect(find.text('My Wallet'), findsNothing);
    expect(find.text('Deposit'), findsNothing);
    expect(find.text('Withdraw'), findsNothing);
    expect(find.text('Internal Transfer'), findsNothing);
    expect(find.text('Transactions'), findsNothing);
    await _expand(t, 'My Data');
    expect(find.text('Deposit Report'), findsNothing);
    expect(find.text('Withdraw Report'), findsNothing);
    expect(find.text('Internal Transfers'), findsNothing);
    expect(find.text('Deal Report'), findsOneWidget);
    expect(find.text('Summary Report'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('Android (and the website) are unchanged', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('no route is redirected and no report field is left out', () {
      expect(hideFunding, isFalse);
      for (final r in [...kFundingRoutes, ...kFundingHistoryRoutes]) {
        expect(fundingRedirect(r), isNull, reason: r);
      }
      expect(isFundingField('total_deposits'), isFalse);
    });
  });

  testWidgets('Android: the menu still offers deposit, withdrawal, transfer, the wallet and their reports', (t) async {
    await _openDrawer(t);
    expect(find.text('My Wallet'), findsOneWidget);
    await _expand(t, 'My Fund');
    expect(find.text('Deposit'), findsOneWidget);
    expect(find.text('Withdraw'), findsOneWidget);
    expect(find.text('Internal Transfer'), findsOneWidget);
    expect(find.text('Transactions'), findsOneWidget);
    await _expand(t, 'My Data');
    expect(find.text('Deposit Report'), findsOneWidget);
    expect(find.text('Withdraw Report'), findsOneWidget);
    expect(find.text('Internal Transfers'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
