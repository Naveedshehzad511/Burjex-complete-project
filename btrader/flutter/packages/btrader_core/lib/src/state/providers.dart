import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../models/auth.dart';
import '../models/branding.dart';
import '../models/account.dart';
import '../models/symbol.dart';

/// Single AuthStore instance shared by the ApiClient and the auth controller.
final authStoreProvider = Provider<AuthStore>((_) => AuthStore());

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(authStoreProvider)));

/// Auth state surfaced to the UI (the router watches this).
class AuthState {
  final bool loading;
  final bool authenticated;
  final String? role;
  const AuthState({this.loading = true, this.authenticated = false, this.role});
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(const AuthState(loading: true)) {
    _wire();
    _restore();
  }
  final Ref _ref;
  static const _kAccess = 'bt_access';
  static const _kRefresh = 'bt_refresh';
  static const _kRole = 'bt_role';

  AuthStore get _store => _ref.read(authStoreProvider);
  ApiClient get _api => _ref.read(apiClientProvider);

  /// Persist refreshed tokens, and drop to login if the refresh chain fails.
  void _wire() {
    _store.onTokens = (s) async {
      final p = await SharedPreferences.getInstance();
      if (s.accessToken != null) await p.setString(_kAccess, s.accessToken!);
      if (s.refreshToken != null) await p.setString(_kRefresh, s.refreshToken!);
    };
    _store.onSessionLost = () => _clearLocal();
  }

  Future<void> _clearLocal() async {
    _store.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kAccess);
    await p.remove(_kRefresh);
    await p.remove(_kRole);
    if (mounted) state = const AuthState(loading: false, authenticated: false);
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final access = p.getString(_kAccess);
    final refresh = p.getString(_kRefresh);
    if (access != null && refresh != null) {
      _store
        ..accessToken = access
        ..refreshToken = refresh
        ..role = p.getString(_kRole);
      state = AuthState(loading: false, authenticated: true, role: _store.role);
    } else {
      state = const AuthState(loading: false, authenticated: false);
    }
  }

  Future<void> login(String email, String password) async {
    final data = await _api.post('/auth/login', {'email': email, 'password': password});
    await _store4(data);
  }

  /// CRM client forgot-password (email reset link). Independent of B-Trader login.
  Future<String> forgotPassword(String email) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://crm.burjexprime.net/api/v1',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
    final res = await dio.post('/auth/forgot-password/', data: {'email': email.trim()});
    final data = res.data;
    if (data is Map && data['success'] == true) {
      return (data['message'] as String?) ?? 'Password reset email sent.';
    }
    final msg = data is Map ? data['message'] : null;
    throw Exception(msg is String && msg.isNotEmpty ? msg : 'Request failed');
  }

  /// MT5-style login by trading account number + password (trader app).
  Future<void> loginByAccount(String accountNumber, String password) async {
    final data = await _api.post('/auth/account-login', {'login': accountNumber, 'password': password});
    await _store4(data, activeAccountId: data['accountId'] as String?);
  }

  /// CRM client signup — same fields as portal Create Account.
  Future<String> signupCrm(Map<String, dynamic> body) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://crm.burjexprime.net/api/v1',
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final res = await dio.post('/auth/signup/', data: body);
    final data = res.data;
    if (data is Map && data['success'] == true) {
      return (data['message'] as String?) ?? 'Account created successfully.';
    }
    final msg = data is Map ? data['message'] : null;
    throw Exception(msg is String && msg.isNotEmpty ? msg : 'Registration failed');
  }

  /// Self-serve demo signup (lead-gen): creates a lead user + demo account and
  /// auto-logs in. Returns the response so the caller can show login/password.
  Future<Map<String, dynamic>> registerDemo(Map<String, dynamic> body) async {
    final data = await _api.post('/auth/demo-register', body);
    await _store4(data, activeAccountId: data['accountId'] as String?);
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> _store4(dynamic data, {String? activeAccountId}) async {
    final t = AuthTokens.fromJson(data);
    _store
      ..accessToken = t.accessToken
      ..refreshToken = t.refreshToken
      ..role = t.role;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccess, t.accessToken);
    await p.setString(_kRefresh, t.refreshToken);
    await p.setString(_kRole, t.role);
    state = AuthState(loading: false, authenticated: true, role: t.role);
    if (activeAccountId != null) {
      _ref.read(activeAccountIdProvider.notifier).state = activeAccountId;
    }
  }

  Future<void> logout() async {
    _store.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kAccess);
    await p.remove(_kRefresh);
    await p.remove(_kRole);
    state = const AuthState(loading: false, authenticated: false);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));

/// Tenant branding for theming — fetched unauthenticated at launch.
final brandingProvider = FutureProvider<Branding>((ref) async {
  try {
    final dio = Dio(BaseOptions(baseUrl: '${BtConfig.apiBase}/v1'));
    final res = await dio.get('/public/branding', options: Options(headers: {'X-BT-Tenant': BtConfig.tenant}));
    return Branding.fromJson(res.data);
  } catch (_) {
    return Branding.fallback;
  }
});

/// The signed-in trader's accounts.
final accountsProvider = FutureProvider<List<Account>>((ref) async {
  ref.watch(authControllerProvider); // refetch after login
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/accounts/me') as List;
  return data.map((e) => Account.fromJson(e)).toList();
});

/// Currently selected account (defaults to the first).
final activeAccountIdProvider = StateProvider<String?>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull;
  return accounts != null && accounts.isNotEmpty ? accounts.first.id : null;
});

/// Enabled symbols for the **active trading account's group**.
///
/// Passes `accountId` so the gateway returns only instruments assigned to that
/// trading group (e.g. Pro → XAUUSD with `.p` display + group markup). Refetches
/// when the user switches accounts on Home → Trade.
final symbolsProvider = FutureProvider<List<TradeSymbol>>((ref) async {
  ref.watch(authControllerProvider);
  final accountId = ref.watch(activeAccountIdProvider);
  final api = ref.watch(apiClientProvider);
  final query = <String, dynamic>{'enabled': 'true'};
  if (accountId != null && accountId.isNotEmpty) {
    query['accountId'] = accountId;
  }
  final data = await api.get('/symbols', query: query) as List;
  return data.map((e) => TradeSymbol.fromJson(e as Map<String, dynamic>)).toList();
});
