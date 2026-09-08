import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'shell.dart';
import 'screens/login_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/market_watch_screen.dart';
import 'screens/clients_screen.dart';
import 'screens/trading_screen.dart';
import 'screens/accounts_screen.dart';
import 'screens/demo_accounts_screen.dart';
import 'screens/account_detail_screen.dart';
import 'screens/dealing_screen.dart';
import 'screens/liquidity_screen.dart';
import 'screens/symbols_screen.dart';
import 'screens/financial_screen.dart';
import 'screens/risk_screen.dart';
import 'screens/audit_screen.dart';
import 'screens/tenants_screen.dart';
import 'screens/hq_screen.dart';
import 'screens/integrations_screen.dart';
import 'screens/groups_screen.dart';
import 'screens/journal_screen.dart';

final adminRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      if (auth.loading) return null;
      final loggingIn = state.matchedLocation == '/login';
      if (!auth.authenticated) return loggingIn ? null : '/login';
      if (loggingIn) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const AdminLoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AdminShell(state: state, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const OverviewScreen()),
          GoRoute(path: '/market', builder: (_, __) => const MarketWatchScreen()),
          GoRoute(path: '/clients', builder: (_, __) => const ClientsScreen()),
          GoRoute(path: '/trading', builder: (_, __) => const TradingScreen()),
          GoRoute(path: '/accounts', builder: (_, __) => const AccountsScreen()),
          GoRoute(path: '/demo-accounts', builder: (_, __) => const DemoAccountsScreen()),
          GoRoute(path: '/account/:id', builder: (_, state) => AccountDetailScreen(accountId: state.pathParameters['id']!)),
          GoRoute(
            path: '/journal',
            builder: (_, state) => JournalScreen(
              accountId: state.uri.queryParameters['account'] ?? '',
              login: state.uri.queryParameters['login'],
            ),
          ),
          GoRoute(path: '/dealing', builder: (_, __) => const DealingScreen()),
          GoRoute(path: '/liquidity', builder: (_, __) => const LiquidityScreen()),
          GoRoute(path: '/symbols', builder: (_, __) => const SymbolsScreen()),
          GoRoute(path: '/groups', builder: (_, __) => const GroupsScreen()),
          GoRoute(
            path: '/financial',
            builder: (_, state) => FinancialScreen(initialAccountId: state.uri.queryParameters['account']),
          ),
          GoRoute(path: '/risk', builder: (_, __) => const RiskScreen()),
          GoRoute(path: '/audit', builder: (_, __) => const AuditScreen()),
          GoRoute(path: '/tenants', builder: (_, __) => const TenantsScreen()),
          GoRoute(path: '/hq', builder: (_, __) => const HqScreen()),
          GoRoute(path: '/integrations', builder: (_, __) => const IntegrationsScreen()),
        ],
      ),
    ],
  );
});

class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
  }
}
