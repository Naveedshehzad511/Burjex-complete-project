import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'shell.dart';
import 'screens/login_screen.dart';
import 'screens/markets_screen.dart';
import 'screens/charts_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/portfolio_screen.dart';
import 'screens/history_screen.dart';
import 'screens/account_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/funding_screen.dart';

/// go_router with an auth redirect driven by AuthController state.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/markets',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      if (auth.loading) return null;
      final loggingIn = state.matchedLocation == '/login';
      if (!auth.authenticated) return loggingIn ? null : '/login';
      if (loggingIn) return '/markets';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      ShellRoute(
        builder: (context, state, child) => TraderShell(state: state, child: child),
        routes: [
          GoRoute(path: '/markets', builder: (_, __) => const MarketsScreen()),
          GoRoute(
            path: '/charts',
            builder: (_, state) => ChartsScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(
            path: '/trade',
            builder: (_, state) => TradeScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(path: '/portfolio', builder: (_, __) => const PortfolioScreen()),
          GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
          GoRoute(path: '/account', builder: (_, __) => const AccountScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(path: '/deposit', builder: (_, __) => const FundingScreen(type: 'deposit')),
          GoRoute(path: '/withdraw', builder: (_, __) => const FundingScreen(type: 'withdraw')),
        ],
      ),
    ],
  );
});

/// Bridges Riverpod auth state changes to go_router's refresh mechanism.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
  }
}
