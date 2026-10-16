import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/screens/home_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The administrator decides on KYC while the client sits on Home: the notice follows within one refresh beat
/// (the same 12 s one that keeps the deposit / balance figures current), with no restart and no navigation.
class _Adapter implements HttpClientAdapter {
  String kyc = 'PENDING';
  int meCalls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? body, Future<void>? cancel) async {
    if (o.path.contains('/me/')) {
      meCalls++;
      return ResponseBody.fromString(
          jsonEncode({'data': {'user': {'email': 'a@b.c', 'display_name': 'A', 'kyc_status': kyc, 'wallet_balance': 0}}}), 200,
          headers: {Headers.contentTypeHeader: ['application/json']});
    }
    return ResponseBody.fromString('{}', 404, headers: {Headers.contentTypeHeader: ['application/json']});
  }
}

class _Api extends ApiClient {
  _Api() : super(AuthStore());
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => <dynamic>[];
}

const _pending = 'KYC is pending — complete it to unlock withdrawals.';
const _rejected = 'KYC was rejected — resubmit your documents to unlock withdrawals.';

Future<(ProviderContainer, _Adapter)> _mount(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({kCrmTokenKey: 'crm-token'});
  t.view
    ..physicalSize = const Size(420, 1600)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final ad = _Adapter();
  final dio = Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = ad;
  final c = ProviderContainer(overrides: [
    crmDioProvider.overrideWithValue(dio),
    apiClientProvider.overrideWithValue(_Api()),
    marketSocketProvider.overrideWith((_) => null),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => const <TradeSymbol>[]),
    accountsProvider.overrideWith((_) async => const <Account>[]),
    crmDashboardProvider.overrideWith((_) async => const CrmDashboard(
        real: CrmMetrics(), demo: CrmMetrics(), accounts: [], userName: 'u', walletBalance: 0)),
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(theme: AppTheme.light(Branding.fallback), home: const HomeScreen())));
  for (var i = 0; i < 10; i++) {
    await _pump(t, 60);
  }
  return (c, ad);
}

/// The test font is wider than the real one, so the Home card header reports a layout overflow; not under test.
Future<void> _pump(WidgetTester t, int ms) async {
  await t.pump(Duration(milliseconds: ms));
  t.takeException();
}

Future<void> _beat(WidgetTester t) async {
  await _pump(t, 12000);
  for (var i = 0; i < 5; i++) {
    await _pump(t, 60);
  }
}

void main() {
  testWidgets('an approval made while Home is open removes the pending notice on the next refresh', (t) async {
    final (_, ad) = await _mount(t);
    expect(find.text(_pending), findsOneWidget);

    ad.kyc = 'APPROVED'; // the administrator approves
    await _beat(t);
    expect(find.text(_pending), findsNothing, reason: 'no restart or navigation needed');

    // Approved: the profile is no longer re-read on every beat.
    final calls = ad.meCalls;
    await _beat(t);
    await _beat(t);
    expect(ad.meCalls, calls);
  });

  testWidgets('a rejection made while Home is open shows the rejected guidance', (t) async {
    final (_, ad) = await _mount(t);
    expect(find.text(_pending), findsOneWidget);
    ad.kyc = 'REJECTED';
    await _beat(t);
    expect(find.text(_rejected), findsOneWidget);
    expect(find.text(_pending), findsNothing);
  });

  testWidgets('still pending: the notice stays as it is', (t) async {
    final (_, _) = await _mount(t);
    await _beat(t);
    expect(find.text(_pending), findsOneWidget);
  });
}
