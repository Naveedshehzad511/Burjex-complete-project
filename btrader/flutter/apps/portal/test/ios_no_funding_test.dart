import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/ib_screens.dart' show IbState, ibStateProvider;
import 'package:burjex_portal/state/crypto_policy.dart';
import 'package:burjex_portal/widgets/portal_drawer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// App Store guideline 3.2.2(viii): the iPhone / iPad app has no deposit or withdrawal; Android and the website keep them.

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

    test('every funding route leads Home', () {
      expect(hideFunding, isTrue);
      for (final r in ['/deposit', '/withdraw', '/wallet', '/transfer', '/ib/withdraw']) {
        expect(fundingRedirect(r), '/home', reason: r);
      }
      for (final r in ['/home', '/trade', '/chart', '/history', '/kyc', '/p/transactions', '/ib/dashboard']) {
        expect(fundingRedirect(r), isNull, reason: r);
      }
    });
  });

  testWidgets('iPhone / iPad: the menu has no deposit, withdrawal, wallet or transfer; the history stays', (t) async {
    await _openDrawer(t);
    expect(find.text('My Fund'), findsNothing);
    expect(find.text('My Wallet'), findsNothing);
    expect(find.text('Deposit'), findsNothing);
    expect(find.text('Withdraw'), findsNothing);
    expect(find.text('Internal Transfer'), findsNothing);
    expect(find.text('Transactions'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('Android (and the website) are unchanged', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('no route is redirected', () {
      expect(hideFunding, isFalse);
      for (final r in kFundingRoutes) {
        expect(fundingRedirect(r), isNull, reason: r);
      }
    });
  });

  testWidgets('Android: the menu still offers deposit, withdrawal, transfer and the wallet', (t) async {
    await _openDrawer(t);
    expect(find.text('My Wallet'), findsOneWidget);
    await _expand(t, 'My Fund');
    expect(find.text('Deposit'), findsOneWidget);
    expect(find.text('Withdraw'), findsOneWidget);
    expect(find.text('Internal Transfer'), findsOneWidget);
    expect(find.text('Transactions'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
