import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'shell.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/verify_otp_screen.dart';
import 'screens/home_screen.dart';
import 'screens/quotes_screen.dart';
import 'screens/chart_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/history_screen.dart';
import 'screens/deposit_screen.dart';
import 'screens/withdraw_screen.dart';
import 'screens/transfer_screen.dart';
import 'screens/transactions_screen.dart';

const _authRoutes = {
  '/login',
  '/register',
  '/forgot-password',
  '/verify-otp',
};

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      if (auth.loading) return null;
      final onAuth = _authRoutes.contains(state.matchedLocation);
      if (!auth.authenticated) return onAuth ? null : '/login';
      if (onAuth) return '/home';
      return null;
    },
    routes: [
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
      ShellRoute(
        builder: (context, state, child) => PortalShell(state: state, child: child),
        routes: [
          GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
          GoRoute(path: '/quotes', builder: (_, __) => const QuotesScreen()),
          GoRoute(
            path: '/chart',
            builder: (_, state) => ChartScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(
            path: '/trade',
            builder: (_, state) => TradeScreen(symbol: state.uri.queryParameters['symbol']),
          ),
          GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
          GoRoute(path: '/deposit', builder: (_, __) => const DepositScreen()),
          GoRoute(path: '/withdraw', builder: (_, __) => const WithdrawScreen()),
          GoRoute(path: '/transfer', builder: (_, __) => const TransferScreen()),
          GoRoute(path: '/transactions', builder: (_, __) => const TransactionsScreen()),
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
