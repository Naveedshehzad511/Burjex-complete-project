import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/verify_email_screen.dart';
import 'screens/markets_screen.dart';
import 'screens/charts_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/portfolio_screen.dart';
import 'screens/history_screen.dart';
import 'screens/account_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/funding_screen.dart';

const _authRoutes = {'/', '/login', '/register', '/forgot-password', '/reset-password', '/verify-email'};

/// go_router with an auth redirect driven by AuthController state.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      if (auth.loading) return null;
      final onAuth = _authRoutes.contains(state.matchedLocation);
      if (!auth.authenticated) return onAuth ? null : '/';
      if (state.matchedLocation == '/reset-password' || state.matchedLocation == '/verify-email') {
        return null;
      }
      if (onAuth) return '/markets';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const OnboardingScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (_, state) => RegisterScreen(
          initialIbId: state.uri.queryParameters['ref'] ?? state.uri.queryParameters['ib'] ?? '',
        ),
      ),
      GoRoute(path: '/forgot-password', builder: (_, __) => const ForgotPasswordScreen()),
      GoRoute(
        path: '/reset-password',
        builder: (_, state) => ResetPasswordScreen(
          uid: state.uri.queryParameters['uid'] ?? '',
          token: state.uri.queryParameters['token'] ?? '',
        ),
      ),
      GoRoute(
        path: '/verify-email',
        builder: (_, state) => VerifyEmailScreen(token: state.uri.queryParameters['token'] ?? ''),
      ),
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
