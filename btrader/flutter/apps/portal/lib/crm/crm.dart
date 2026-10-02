import 'dart:async';
import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/push_service.dart';

/// Same key btrader_core reads (IB referral etc.), so both layers share one CRM token.
const kCrmTokenKey = 'crm_token';

/// Best human-readable message from a CRM error body / Dio error.
String crmMessage(Object? e, [String fallback = 'Something went wrong. Please try again.']) {
  dynamic data = e;
  if (e is DioException) {
    data = e.response?.data;
    if (data == null) {
      return e.type == DioExceptionType.connectionError || e.type == DioExceptionType.connectionTimeout
          ? 'Cannot reach the server. Check your connection.'
          : fallback;
    }
  }
  if (data is Map) {
    final errors = data['errors'];
    if (errors is Map && errors.isNotEmpty) {
      final first = errors.values.first;
      if (first is List && first.isNotEmpty) return first.first.toString();
      if (first is String) return first;
    }
    final msg = data['message'] ?? data['detail'];
    if (msg is String && msg.isNotEmpty) return msg;
  }
  return fallback;
}

double crmNum(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

class CrmAuthState {
  const CrmAuthState({this.loading = true, this.token});
  final bool loading;
  final String? token;
  bool get authenticated => token != null && token!.isNotEmpty;
}

/// Client login against the CRM (the source of truth for who the user is).
/// The token is what unlocks Home, funding and account opening; trading
/// sessions on the gateway are bootstrapped from it separately.
class CrmSession extends StateNotifier<CrmAuthState> {
  CrmSession(this._ref) : super(const CrmAuthState()) {
    _restore();
  }
  final Ref _ref;

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = p.getString(kCrmTokenKey);
    state = CrmAuthState(loading: false, token: saved);
    if (saved != null && saved.isNotEmpty) unawaited(PushService.instance.register(saved));
  }

  /// Returns null on success, otherwise the message to show.
  Future<String?> login(String email, String password) async {
    try {
      final res = await Dio(BaseOptions(
        baseUrl: BtConfig.crmBase,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      )).post('/auth/login/', data: {'username': email.trim(), 'password': password});
      final body = res.data;
      if (body is! Map || body['success'] != true) return crmMessage(body, 'Login failed.');
      final data = body['data'];
      if (data is! Map) return 'Login failed.';
      if (data['totp_required'] == true) {
        return 'Two-factor authentication is enabled on this account. Use the web portal to sign in.';
      }
      final token = (data['token'] ?? data['access'] ?? '').toString();
      if (token.isEmpty) return 'Login failed.';
      final p = await SharedPreferences.getInstance();
      await p.setString(kCrmTokenKey, token);
      state = CrmAuthState(loading: false, token: token);
      unawaited(PushService.instance.register(token));
      return null;
    } on DioException catch (e) {
      return crmMessage(e, 'Login failed. Check your email and password.');
    } catch (_) {
      return 'Login failed. Please try again.';
    }
  }

  Future<void> logout() async {
    final token = state.token;
    state = const CrmAuthState(loading: false);
    final p = await SharedPreferences.getInstance();
    await p.remove(kCrmTokenKey);
    await p.remove(_kDashCacheKey);
    _dashSeeded = false;
    if (token != null) {
      unawaited(PushService.instance.unregister(token));
      // Best effort — the local session is already gone.
      unawaited(Dio(BaseOptions(baseUrl: BtConfig.crmBase, headers: {'Authorization': 'Token $token'}))
          .post('/auth/logout/')
          .then((_) {}, onError: (_) {}));
    }
    await _ref.read(authControllerProvider.notifier).logout();
  }
}

final crmSessionProvider = StateNotifierProvider<CrmSession, CrmAuthState>((ref) => CrmSession(ref));

/// Authenticated Dio for the CRM client API. A 401 means the CRM session ended.
final crmDioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    baseUrl: BtConfig.crmBase,
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
  ));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (o, h) {
      final t = ref.read(crmSessionProvider).token;
      if (t != null) o.headers['Authorization'] = 'Token $t';
      h.next(o);
    },
    onError: (e, h) {
      if (e.response?.statusCode == 401 && ref.read(crmSessionProvider).authenticated) {
        Future.microtask(() => ref.read(crmSessionProvider.notifier).logout());
      }
      h.next(e);
    },
  ));
  return dio;
});

/// One CRM trading account row (`/accounts/`, `/dashboard/` accounts[]).
class CrmAccount {
  const CrmAccount({
    required this.login,
    required this.type,
    required this.isDemo,
    required this.balance,
    required this.equity,
    required this.leverage,
    required this.currency,
    required this.status,
    required this.tradingEnabled,
    required this.depositEnabled,
    required this.withdrawEnabled,
    required this.platform,
  });
  final String login;
  final String type;
  final bool isDemo;
  final double balance;
  final double equity;
  final int leverage;
  final String currency;
  final String status;
  final bool tradingEnabled;
  final bool depositEnabled;
  final bool withdrawEnabled;
  final String platform;

  /// "Real (BTrader) — Standard" -> "Standard".
  String get plan {
    final parts = type.split(RegExp(r'\s[—–-]\s'));
    return parts.isEmpty ? type : parts.last.trim();
  }

  factory CrmAccount.fromJson(Map<String, dynamic> j) => CrmAccount(
        login: (j['login_id'] ?? j['account_number'] ?? '').toString(),
        type: (j['account_type'] ?? '').toString(),
        isDemo: j['is_demo'] == true,
        balance: crmNum(j['balance']),
        equity: crmNum(j['equity']),
        leverage: int.tryParse('${j['leverage']}') ?? 100,
        currency: (j['currency'] ?? 'USD').toString(),
        status: (j['status'] ?? '').toString(),
        tradingEnabled: j['trading_enabled'] != false,
        depositEnabled: j['deposit_enabled'] != false,
        withdrawEnabled: j['withdraw_enabled'] != false,
        platform: (j['platform'] ?? '').toString(),
      );
}

class CrmMetrics {
  const CrmMetrics({this.balance = 0, this.equity = 0, this.openPnl = 0, this.withdrawable = 0, this.margin = 0});
  final double balance;
  final double equity;
  final double openPnl;
  final double withdrawable;

  /// Margin in use. Not part of the CRM payload — filled from the live trading accounts.
  final double margin;
  factory CrmMetrics.fromJson(Map<String, dynamic>? j) => j == null
      ? const CrmMetrics()
      : CrmMetrics(
          balance: crmNum(j['total_balance']),
          equity: crmNum(j['total_equity']),
          openPnl: crmNum(j['open_pnl']),
          withdrawable: crmNum(j['available_to_withdraw']),
        );

  /// Open PnL as a % of balance — the card's performance signal. Null when no balance.
  double? get performancePct => balance > 0 ? openPnl / balance * 100 : null;
}

class CrmDashboard {
  const CrmDashboard({
    required this.real,
    required this.demo,
    required this.accounts,
    required this.userName,
    required this.walletBalance,
  });
  final CrmMetrics real;
  final CrmMetrics demo;
  final List<CrmAccount> accounts;
  final String userName;
  final double walletBalance;
}

const _kDashCacheKey = 'crm_dashboard_cache';

/// True while the dashboard on screen is the saved copy (offline / slow network).
final crmDashboardOfflineProvider = StateProvider<bool>((_) => false);

/// First load of an app session shows the saved copy instantly, then refreshes.
bool _dashSeeded = false;

CrmDashboard _parseDashboard(Map data) {
  final tm = (data['tab_metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
  final accs = [
    for (final a in (data['accounts'] as List? ?? const [])) CrmAccount.fromJson((a as Map).cast<String, dynamic>()),
  ];
  final user = (data['user'] as Map?)?.cast<String, dynamic>() ?? const {};
  final wallet = (data['wallet'] as Map?)?.cast<String, dynamic>() ?? const {};
  return CrmDashboard(
    real: CrmMetrics.fromJson((tm['real'] as Map?)?.cast<String, dynamic>()),
    demo: CrmMetrics.fromJson((tm['demo'] as Map?)?.cast<String, dynamic>()),
    accounts: accs,
    userName: (user['display_name'] ?? user['first_name'] ?? user['email'] ?? '').toString(),
    walletBalance: crmNum(wallet['wallet_balance']),
  );
}

/// Stale-while-revalidate: the last good dashboard is kept on disk, shown at once
/// on open, and used again if the network is slow or down - so Home never turns
/// into an error screen just because the connection is bad.
final crmDashboardProvider = FutureProvider.autoDispose<CrmDashboard>((ref) async {
  ref.watch(crmSessionProvider.select((s) => s.token));
  ref.keepAlive();
  final prefs = await SharedPreferences.getInstance();
  Map? cached;
  try {
    final raw = prefs.getString(_kDashCacheKey);
    if (raw != null) cached = jsonDecode(raw) as Map;
  } catch (_) {}
  void setOffline(bool v) => Future.microtask(() {
        try {
          ref.read(crmDashboardOfflineProvider.notifier).state = v;
        } catch (_) {}
      });

  if (cached != null && !_dashSeeded) {
    _dashSeeded = true;
    Future.microtask(() {
      try {
        ref.invalidateSelf();
      } catch (_) {}
    });
    return _parseDashboard(cached);
  }
  try {
    final res = await ref.watch(crmDioProvider).get('/dashboard/', options: Options(receiveTimeout: const Duration(seconds: 15)));
    final data = (res.data as Map)['data'] as Map;
    unawaited(prefs.setString(_kDashCacheKey, jsonEncode(data)));
    setOffline(false);
    return _parseDashboard(data);
  } catch (e) {
    final authEnded = e is DioException && e.response?.statusCode == 401;
    if (cached != null && !authEnded) {
      setOffline(true);
      return _parseDashboard(cached);
    }
    rethrow;
  }
});

class CrmProfile {
  const CrmProfile({
    required this.name,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.country,
    required this.address,
    required this.accountStatus,
    required this.kycStatus,
    required this.walletBalance,
  });
  final String name, email, firstName, lastName, phone, country, address, accountStatus, kycStatus;
  final double walletBalance;

  bool get kycApproved => kycStatus.toUpperCase() == 'APPROVED' || kycStatus.toUpperCase() == 'VERIFIED';
}

final crmProfileProvider = FutureProvider.autoDispose<CrmProfile>((ref) async {
  ref.watch(crmSessionProvider.select((s) => s.token));
  final res = await ref.watch(crmDioProvider).get('/me/');
  final data = (res.data as Map)['data'] as Map;
  final u = (data['user'] as Map).cast<String, dynamic>();
  return CrmProfile(
    name: (u['display_name'] ?? u['email'] ?? '').toString(),
    email: (u['email'] ?? '').toString(),
    firstName: (u['first_name'] ?? '').toString(),
    lastName: (u['last_name'] ?? '').toString(),
    phone: (u['phone'] ?? '').toString(),
    country: (u['country'] ?? '').toString(),
    address: (u['address'] ?? '').toString(),
    accountStatus: (u['account_status'] ?? '').toString(),
    kycStatus: (u['kyc_status'] ?? '').toString(),
    walletBalance: crmNum(u['wallet_balance']),
  );
});
