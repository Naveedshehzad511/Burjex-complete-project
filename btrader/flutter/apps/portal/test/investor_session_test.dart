import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/session/sessions.dart';
import 'package:burjex_portal/shell.dart';
import 'package:burjex_portal/widgets/manage_accounts.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User A owns account 1001. Account 2002 belongs to client B; "inv" is its
/// investor password (read-only), "trade" its trading password.
class _Gateway extends ApiClient {
  _Gateway() : super(AuthStore());
  final logins = <String>[];

  Map<String, dynamic> _tokens(String login, {required bool readonly}) => {
        'accessToken': 'at-$login',
        'refreshToken': 'rt-$login',
        'accountId': 'acc-$login',
        'login': login,
        'readonly': readonly,
        'holderName': login == '2002' ? 'Client B' : 'User A',
        'balance': 1000,
      };

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    final b = (body as Map?)?.cast<String, dynamic>() ?? const {};
    if (path == '/auth/account-login') {
      final login = '${b['login']}';
      logins.add(login);
      if (login == '1001' && b['password'] == 'pwA') return _tokens('1001', readonly: false);
      if (login == '2002' && b['password'] == 'inv') return _tokens('2002', readonly: true);
      throw DioException(
        requestOptions: RequestOptions(path: path),
        response: Response(requestOptions: RequestOptions(path: path), statusCode: 401, data: {'message': 'Invalid'}),
      );
    }
    if (path == '/auth/refresh') {
      final login = '${b['refreshToken']}'.replaceFirst('rt-', '');
      logins.add('refresh:$login');
      return _tokens(login, readonly: login == '2002');
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => <dynamic>[];
}

/// CRM: hands out account 1001's trading password to its owner.
Dio _crm() {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    if (o.path == '/accounts/1001/trading-session/') {
      return h.resolve(Response(requestOptions: o, statusCode: 200, data: {
        'data': {'password': 'pwA'}
      }));
    }
    return h.reject(DioException(requestOptions: o, response: Response(requestOptions: o, statusCode: 404)));
  }));
  return dio;
}

const _accountA = CrmAccount(
  login: '1001',
  type: 'Real (BTrader) — Standard',
  isDemo: false,
  balance: 500,
  equity: 500,
  leverage: 100,
  currency: 'USD',
  status: 'ACTIVE',
  tradingEnabled: true,
  depositEnabled: true,
  withdrawEnabled: true,
  platform: 'BTrader',
);

const _dash = CrmDashboard(real: CrmMetrics(), demo: CrmMetrics(), accounts: [_accountA], userName: 'User A', walletBalance: 0);

ProviderContainer _container(_Gateway api) => ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      crmDioProvider.overrideWithValue(_crm()),
      crmDashboardProvider.overrideWith((_) async => _dash),
      marketSocketProvider.overrideWith((_) => null),
      quotesSeedProvider.overrideWith((_) async {}),
      feedSubscriptionProvider.overrideWith((_) {}),
      accountsProvider.overrideWith((_) async => const <Account>[]),
    ]);

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Trading session', () {
    test('A signs into B read-only, then Home → Trade switches back to A with full access', () async {
      final api = _Gateway();
      final c = _container(api);
      addTearDown(c.dispose);
      await c.read(crmDashboardProvider.future);
      final session = c.read(tradingSessionProvider.notifier);

      await session.openOwn('1001');
      expect(c.read(tradingSessionProvider).accountId, 'acc-1001');
      expect(c.read(tradingSessionProvider).readonly, isFalse);

      expect(await session.addManaged('2002', 'inv'), isNull);
      var s = c.read(tradingSessionProvider);
      expect([s.login, s.accountId, s.readonly, s.managed], ['2002', 'acc-2002', true, true]);
      expect(c.read(activeAccountIdProvider), 'acc-2002', reason: 'Quotes / Chart / Trade / History read B');
      await _flush();
      var last = await LastTrading.read();
      expect([last!.login, last.managed, last.owners], ['2002', true, ['1001']]);

      // Home → Trade on A's own card.
      final done = session.openOwn('1001');
      s = c.read(tradingSessionProvider);
      expect([s.login, s.loading, s.readonly], ['1001', true, false],
          reason: 'switching shows at once — Trade never keeps showing B read-only');
      await done;
      s = c.read(tradingSessionProvider);
      expect([s.login, s.accountId, s.readonly, s.managed, s.ready], ['1001', 'acc-1001', false, false, true]);
      await _flush();
      last = await LastTrading.read();
      expect([last!.login, last.managed], ['1001', false]);
    });

    test('a wrong investor password leaves the current account untouched', () async {
      final c = _container(_Gateway());
      addTearDown(c.dispose);
      await c.read(crmDashboardProvider.future);
      await c.read(tradingSessionProvider.notifier).openOwn('1001');
      expect(await c.read(tradingSessionProvider.notifier).addManaged('2002', 'nope'), isNotNull);
      expect(c.read(tradingSessionProvider).login, '1001');
      expect(c.read(tradingSessionProvider).readonly, isFalse);
    });

    test('sign-out forgets the remembered account', () async {
      await LastTrading.write('2002', managed: true, owners: ['1001']);
      final c = _container(_Gateway());
      addTearDown(c.dispose);
      c.read(tradingSessionProvider.notifier).reset();
      await _flush();
      expect(await LastTrading.read(), isNull);
    });

    test('remembered account belongs only to the user who had it', () {
      const last = LastTrading(login: '2002', managed: true, owners: ['1001', '1003']);
      expect(last.belongsTo(['1003']), isTrue);
      expect(last.belongsTo(['7777']), isFalse);
    });
  });

  group('Shell', () {
    Future<ProviderContainer> pumpShell(WidgetTester t, _Gateway api) async {
      final c = _container(api);
      final router = GoRouter(initialLocation: '/home', routes: [
        ShellRoute(
          builder: (_, state, child) => PortalShell(state: state, child: child),
          routes: [
            for (final p in ['home', 'quotes', 'chart', 'trade', 'history', 'new-order'])
              GoRoute(path: '/$p', builder: (_, __) => Text('page:$p')),
          ],
        ),
      ]);
      await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp.router(routerConfig: router)));
      for (var i = 0; i < 6; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump(const Duration(milliseconds: 50));
      }
      return c;
    }

    testWidgets('refresh keeps B read-only (no silent switch to the main account); Home stays', (t) async {
      final saved = ManagedAccount(
          login: '2002', accountId: 'acc-2002', holderName: 'Client B', balance: 1, readonly: true, isDemo: false, refreshToken: 'rt-2002');
      SharedPreferences.setMockInitialValues({'bx_managed_accounts_v1': '[${_json(saved)}]'});
      await LastTrading.write('2002', managed: true, owners: ['1001']);
      final api = _Gateway();
      final c = await pumpShell(t, api);
      final s = c.read(tradingSessionProvider);
      expect([s.login, s.readonly, s.managed], ['2002', true, true]);
      expect(api.logins, ['refresh:2002'], reason: 'reopened B from its saved session; never logged into the main account');
      // Home is still in the navigation and still reachable.
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('page:home'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('someone else’s remembered account is ignored — main account opens', (t) async {
      await LastTrading.write('2002', managed: true, owners: ['9999']);
      final api = _Gateway();
      final c = await pumpShell(t, api);
      expect(c.read(tradingSessionProvider).login, '1001');
      expect(api.logins, ['1001']);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('nothing remembered — main account opens', (t) async {
      final api = _Gateway();
      final c = await pumpShell(t, api);
      expect(c.read(tradingSessionProvider).login, '1001');
      expect(c.read(tradingSessionProvider).readonly, isFalse);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('Home notice and the "+" dialog', () {
    testWidgets('Home says which account the other tabs are on', (t) async {
      final c = _container(_Gateway());
      addTearDown(c.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ViewingOtherAccountNotice())),
      ));
      expect(find.byKey(const ValueKey('viewing-other-account')), findsNothing, reason: 'own account: no notice');
      await t.runAsync(() async {
        await c.read(crmDashboardProvider.future);
        await c.read(tradingSessionProvider.notifier).addManaged('2002', 'inv');
      });
      await t.pump();
      expect(find.textContaining('#2002 · Client B (Investor, read-only)'), findsOneWidget);
    });

    testWidgets('"+" lists my own accounts; one tap back to full access', (t) async {
      final c = _container(_Gateway());
      addTearDown(c.dispose);
      await t.runAsync(() async {
        await c.read(crmDashboardProvider.future);
        await c.read(tradingSessionProvider.notifier).addManaged('2002', 'inv');
      });
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: Builder(builder: (ctx) => TextButton(onPressed: () => showManageAccountDialog(ctx), child: const Text('open')))),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('My accounts'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('own-1001')));
      for (var i = 0; i < 6; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.pumpAndSettle();
      final s = c.read(tradingSessionProvider);
      expect([s.login, s.readonly, s.managed], ['1001', false, false]);
      expect(find.text('My accounts'), findsNothing, reason: 'dialog closes after switching');
    });
  });
}

String _json(ManagedAccount a) => '{"login":"${a.login}","accountId":"${a.accountId}","holderName":"${a.holderName}",'
    '"balance":${a.balance},"readonly":${a.readonly},"isDemo":${a.isDemo},"refreshToken":"${a.refreshToken}"}';
