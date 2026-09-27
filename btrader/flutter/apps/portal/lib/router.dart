import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'crm/crm.dart';
import 'screens/account_pages.dart';
import 'screens/crm_pages.dart';
import 'screens/charts_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/funding_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/markets_screen.dart';
import 'screens/new_order_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/register_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/verify_email_screen.dart';
import 'screens/verify_otp_screen.dart';
import 'shell.dart';

const _authRoutes = {
  '/',
  '/login',
  '/register',
  '/forgot-password',
  '/reset-password',
  '/verify-email',
  '/verify-otp',
};

/// go_router with an auth redirect driven by the CRM session.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(crmSessionProvider);
      if (auth.loading) return null;
      final loc = state.matchedLocation;
      final onAuth = _authRoutes.contains(loc);
      if (!auth.authenticated) return onAuth ? null : '/login';
      if (loc == '/reset-password' || loc == '/verify-email') return null;
      if (onAuth) return '/home';
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
        path: '/verify-otp',
        builder: (_, state) => VerifyOtpScreen(email: state.uri.queryParameters['email'] ?? ''),
      ),
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
      // Full-screen pages (back arrow, no bottom bar).
      GoRoute(path: '/deposit', builder: (_, __) => const FundingScreen(type: 'deposit')),
      GoRoute(path: '/withdraw', builder: (_, __) => const FundingScreen(type: 'withdraw')),
      GoRoute(path: '/open-account', builder: (_, state) => OpenAccountScreen(demo: state.uri.queryParameters['type'] == 'demo')),
      GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      GoRoute(path: '/kyc', builder: (_, __) => const KycScreen()),
      GoRoute(path: '/wallet', builder: (_, __) => const WalletScreen()),
      GoRoute(path: '/transfer', builder: (_, __) => const InternalTransferScreen()),
      GoRoute(path: '/p/:key', builder: (_, state) => CrmDataScreen(pageKey: state.pathParameters['key'] ?? '')),
      GoRoute(path: '/soon/:title', builder: (_, state) => ComingSoonScreen(title: state.pathParameters['title'] ?? '')),
      ShellRoute(
        builder: (context, state, child) => PortalShell(state: state, child: child),
        routes: [
          GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
          GoRoute(path: '/quotes', builder: (_, __) => const MarketsScreen()),
          GoRoute(
            path: '/chart',
            builder: (_, state) => ChartsScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(
            path: '/trade',
            builder: (_, state) => TradeScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(
            path: '/new-order',
            builder: (_, state) => NewOrderScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
        ],
      ),
    ],
  );
});

class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(crmSessionProvider, (_, __) => notifyListeners());
  }
}
