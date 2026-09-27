import 'dart:async';

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
  static const _kCrmToken = 'crm_token';

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
    await p.remove(_kCrmToken);
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
    try {
      final data = await _api.post('/auth/login', {'email': email, 'password': password});
      await _store4(data);
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Login failed. Check your email and password.'));
    }
    unawaited(_tryCrmLogin(email, password));
  }

  Dio _crmDio() => Dio(BaseOptions(
        baseUrl: 'https://crm.burjexprime.net/api/v1',
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      ));

  String _crmMessage(dynamic data, String fallback) {
    if (data is Map) {
      final msg = data['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      if (msg is List && msg.isNotEmpty) return msg.first.toString();
      final errors = data['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final first = errors.values.first;
        if (first is List && first.isNotEmpty) return first.first.toString();
        if (first is String) return first;
      }
    }
    return fallback;
  }

  /// CRM client forgot-password (email OTP). Independent of B-Trader login.
  Future<String> forgotPassword(String email) async {
    try {
      final res = await _crmDio().post('/auth/forgot-password/', data: {'email': email.trim()});
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'A 6-digit code has been sent to your email.';
      }
      throw Exception(_crmMessage(data, 'Request failed'));
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Request failed'));
    }
  }

  Future<String> resetPasswordOtp({
    required String email,
    required String otp,
    required String password,
    required String confirm,
  }) async {
    try {
      final res = await _crmDio().post('/auth/reset-password-otp/', data: {
        'email': email.trim(),
        'otp': otp.trim(),
        'new_password': password,
        'confirm_password': confirm,
      });
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'Password updated.';
      }
      throw Exception(_crmMessage(data, 'Reset failed'));
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Reset failed'));
    }
  }

  Future<String> resetPassword({
    required String uid,
    required String token,
    required String password,
    required String confirm,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://crm.burjexprime.net/api/v1',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
    try {
      final res = await dio.post('/auth/reset-password/', data: {
        'uid': uid,
        'token': token,
        'new_password': password,
        'confirm_password': confirm,
      });
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'Password updated. You can sign in now.';
      }
      final msg = data is Map ? data['message'] : null;
      throw Exception(msg is String && msg.isNotEmpty ? msg : 'Request failed');
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = data is Map ? data['message'] : null;
      throw Exception(msg is String && msg.isNotEmpty ? msg : 'Reset failed');
    }
  }

  Future<String> verifyEmailOtp({
    required String email,
    required String otp,
    String password = '',
  }) async {
    try {
      final res = await _crmDio().post('/auth/verify-email-otp/', data: {
        'email': email.trim(),
        'otp': otp.trim(),
        if (password.isNotEmpty) 'password': password,
      });
      final data = res.data;
      if (data is Map && data['success'] == true) {
        final token = ((data['data'] is Map) ? data['data']['token'] : null)?.toString() ?? '';
        if (token.isNotEmpty) {
          final p = await SharedPreferences.getInstance();
          await p.setString(_kCrmToken, token);
        }
        return (data['message'] as String?) ?? 'Email verified.';
      }
      throw Exception(_crmMessage(data, 'Verification failed'));
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Verification failed'));
    }
  }

  Future<String> resendEmailOtp(String email) async {
    try {
      final res = await _crmDio().post('/auth/resend-verification/', data: {'email': email.trim()});
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'A new code was sent.';
      }
      throw Exception(_crmMessage(data, 'Could not resend code'));
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Could not resend code'));
    }
  }

  Future<String> verifyEmailToken(String token) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://crm.burjexprime.net/api/v1',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
    try {
      final res = await dio.post('/auth/verify-email/', data: {'token': token});
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'Email verified. You can sign in now.';
      }
      final msg = data is Map ? data['message'] : null;
      throw Exception(msg is String && msg.isNotEmpty ? msg : 'Verification failed');
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = data is Map ? data['message'] : null;
      throw Exception(msg is String && msg.isNotEmpty ? msg : 'Verification failed');
    }
  }

  /// MT5-style login by trading account number + password (trader app).
  Future<void> loginByAccount(String accountNumber, String password) async {
    final data = await _api.post('/auth/account-login', {'login': accountNumber, 'password': password});
    await _store4(data, activeAccountId: data['accountId'] as String?);
  }

  /// CRM client signup — same fields as portal Create Account.
  Future<String> signupCrm(Map<String, dynamic> body) async {
    try {
      final res = await _crmDio().post('/auth/signup/', data: body);
      final data = res.data;
      if (data is Map && data['success'] == true) {
        return (data['message'] as String?) ?? 'Account created. Enter the code from your email.';
      }
      throw Exception(_crmMessage(data, 'Registration failed'));
    } on DioException catch (e) {
      throw Exception(_crmMessage(e.response?.data, 'Registration failed'));
    }
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
    await p.remove(_kCrmToken);
    state = const AuthState(loading: false, authenticated: false);
  }

  Future<void> _tryCrmLogin(String email, String password) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://crm.burjexprime.net/api/v1',
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 6),
      ));
      final res = await dio.post('/auth/login/', data: {'username': email.trim(), 'password': password});
      final body = res.data;
      if (body is! Map || body['success'] != true) return;
      final data = body['data'];
      if (data is! Map) return;
      if (data['totp_required'] == true) return;
      final token = (data['token'] ?? data['access'] ?? '').toString();
      if (token.isEmpty) return;
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCrmToken, token);
    } catch (_) {}
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));

/// Tenant branding for theming — fetched unauthenticated at launch.
final brandingProvider = FutureProvider<Branding>((ref) async {
  final seed = Branding.fallback;
  try {
    final dio = Dio(BaseOptions(baseUrl: '${BtConfig.apiBase}/v1'));
    final headers = <String, dynamic>{};
    if (BtConfig.tenant.isNotEmpty) headers['X-BT-Tenant'] = BtConfig.tenant;
    final res = await dio.get('/public/branding', options: Options(headers: headers));
    final data = res.data;
    if (data is! Map) return seed;
    final api = Branding.fromJson(Map<String, dynamic>.from(data));
    final name = api.appName.trim().toLowerCase();
    if (name.isEmpty || name == 'b-trader' || name == 'btrader' || name == 'demo trader') {
      return Branding(
        appName: seed.appName,
        logoUrl: api.logoUrl ?? seed.logoUrl,
        primary: seed.primary,
        accent: seed.accent,
        baseCurrency: api.baseCurrency,
      );
    }
    return api;
  } catch (_) {
    return seed;
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

class IbReferralInfo {
  const IbReferralInfo({required this.ibCode, required this.referralLink});
  final String ibCode;
  final String referralLink;
}

/// IB ID + share link from CRM (only after CRM login with the same email).
final ibReferralProvider = FutureProvider<IbReferralInfo?>((ref) async {
  ref.watch(authControllerProvider);
  final p = await SharedPreferences.getInstance();
  final token = p.getString('crm_token') ?? '';
  if (token.isEmpty) return null;
  try {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://crm.burjexprime.net/api/v1',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Authorization': 'Token $token'},
    ));
    final res = await dio.get('/ib/dashboard/');
    final body = res.data;
    if (body is! Map || body['success'] != true) return null;
    final data = body['data'];
    if (data is! Map) return null;
    final profile = data['ib_profile'];
    if (profile is! Map) return null;
    final code = (profile['ib_code'] ?? '').toString().trim();
    if (code.isEmpty) return null;
    return IbReferralInfo(
      ibCode: code,
      referralLink: (profile['referral_link'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  }
});
