import 'dart:convert';
import 'dart:typed_data';

import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/screens/ib_screens.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeCrm implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final data = o.path.endsWith('/ib/dashboard/')
        ? {
            'month_name': 'October 2026',
            'ib_profile': {'referral_link': 'https://x/register?ref=A', 'link_clicks': 3},
            'team_deposits': '4900',
            'team_withdrawals': '400',
            'team_net': '4500',
            'total_clients': 3,
          }
        : {'available': false};
    return ResponseBody.fromString(jsonEncode({'success': true, 'data': data}), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

void main() {
  testWidgets('the team deposit / withdrawal figures open their detailed lists (the menu no longer does)', (t) async {
    t.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'http://crm.test'))..httpClientAdapter = _FakeCrm();
    final opened = <String>[];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const IbDashboardScreen()),
      GoRoute(path: '/ib/team-deposits', builder: (_, __) { opened.add('deposits'); return const Scaffold(body: Text('deposits page')); }),
      GoRoute(path: '/ib/team-withdrawals', builder: (_, __) { opened.add('withdrawals'); return const Scaffold(body: Text('withdrawals page')); }),
    ]);
    await t.pumpWidget(ProviderScope(overrides: [crmDioProvider.overrideWithValue(dio)], child: MaterialApp.router(routerConfig: router)));
    await t.pumpAndSettle();
    expect(find.text('Team deposits'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ib-stat-/ib/team-deposits')));
    await t.pumpAndSettle();
    expect(opened, ['deposits']);
    router.pop();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ib-stat-/ib/team-withdrawals')));
    await t.pumpAndSettle();
    expect(opened, ['deposits', 'withdrawals']);
  });
}
