import 'dart:async';
import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crm/crm.dart';

/// Which trading account Quotes / Chart / Trade / History are working on.
///
/// Home never reads this: it is built from the CRM's own account list, so signing
/// into another client's account for management can never touch the dashboard.
class ActiveTrading {
  const ActiveTrading({
    this.login,
    this.accountId,
    this.readonly = false,
    this.managed = false,
    this.holderName = '',
    this.loading = false,
    this.error,
  });
  final String? login;
  final String? accountId;

  /// Investor-password session: the server rejects every trade mutation too.
  final bool readonly;

  /// True for an account added through the Trade screen's "+" (not the user's own).
  final bool managed;
  final String holderName;
  final bool loading;
  final String? error;
  bool get ready => accountId != null && !loading;
}

/// A trading account the user signed into via "+", saved for one-tap switching.
/// Only the gateway refresh token is kept — never the password.
class ManagedAccount {
  const ManagedAccount({
    required this.login,
    required this.accountId,
    required this.holderName,
    required this.balance,
    required this.readonly,
    required this.isDemo,
    required this.refreshToken,
  });
  final String login;
  final String accountId;
  final String holderName;
  final double balance;
  final bool readonly;
  final bool isDemo;
  final String refreshToken;

  ManagedAccount copyWith({double? balance, String? refreshToken, String? holderName}) => ManagedAccount(
        login: login,
        accountId: accountId,
        holderName: holderName ?? this.holderName,
        balance: balance ?? this.balance,
        readonly: readonly,
        isDemo: isDemo,
        refreshToken: refreshToken ?? this.refreshToken,
      );

  Map<String, dynamic> toJson() => {
        'login': login,
        'accountId': accountId,
        'holderName': holderName,
        'balance': balance,
        'readonly': readonly,
        'isDemo': isDemo,
        'refreshToken': refreshToken,
      };

  factory ManagedAccount.fromJson(Map<String, dynamic> j) => ManagedAccount(
        login: '${j['login']}',
        accountId: '${j['accountId']}',
        holderName: '${j['holderName'] ?? ''}',
        balance: crmNum(j['balance']),
        readonly: j['readonly'] == true,
        isDemo: j['isDemo'] == true,
        refreshToken: '${j['refreshToken']}',
      );
}

/// Encrypted key/value storage with a plain-prefs fallback for browsers that
/// don't expose WebCrypto (plain-http LAN pages).
class _SecureBox {
  static const _key = 'bx_managed_accounts_v1';
  static const _s = FlutterSecureStorage();

  static Future<String?> read() async {
    try {
      final v = await _s.read(key: _key);
      if (v != null) return v;
    } catch (_) {}
    return (await SharedPreferences.getInstance()).getString(_key);
  }

  static Future<void> write(String value) async {
    try {
      await _s.write(key: _key, value: value);
      return;
    } catch (_) {}
    await (await SharedPreferences.getInstance()).setString(_key, value);
  }
}

class ManagedAccountsController extends StateNotifier<List<ManagedAccount>> {
  ManagedAccountsController() : super(const []) {
    loaded = _load();
  }

  /// Completes once the saved list has been read from storage.
  late final Future<void> loaded;

  Future<void> _load() async {
    try {
      final raw = await _SecureBox.read();
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List)
          .map((e) => ManagedAccount.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (mounted) state = list;
    } catch (_) {/* corrupt payload — start empty rather than crash the app */}
  }

  Future<void> _persist() => _SecureBox.write(jsonEncode([for (final a in state) a.toJson()]));

  Future<void> upsert(ManagedAccount a) async {
    state = [a, ...state.where((x) => x.login != a.login)];
    await _persist();
  }

  Future<void> remove(String login) async {
    state = state.where((x) => x.login != login).toList();
    await _persist();
  }

  Future<void> updateBalance(String login, double balance) async {
    final i = state.indexWhere((x) => x.login == login);
    if (i < 0 || state[i].balance == balance) return;
    final next = [...state];
    next[i] = next[i].copyWith(balance: balance);
    state = next;
    await _persist();
  }

  Future<void> clear() async {
    state = const [];
    await _persist();
  }
}

final managedAccountsProvider =
    StateNotifierProvider<ManagedAccountsController, List<ManagedAccount>>((_) => ManagedAccountsController());

/// The account Quotes / Chart / Trade / History were last working on, kept across a
/// page refresh / app restart. Only the account number and kind — never a password or
/// token (a managed account reopens through its own saved refresh token).
class LastTrading {
  const LastTrading({required this.login, required this.managed, required this.owners});
  final String login;
  final bool managed;

  /// The signed-in user's own account numbers when this was saved. It is only
  /// restored for a user who owns at least one of them, so it can never carry
  /// over to someone else who signs in on the same device.
  final List<String> owners;

  static const _key = 'bx_last_trading_v1';

  static Future<LastTrading?> read() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return LastTrading(
        login: '${j['login']}',
        managed: j['managed'] == true,
        owners: [for (final o in (j['owners'] as List? ?? const [])) '$o'],
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String login, {required bool managed, required List<String> owners}) async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode({'login': login, 'managed': managed, 'owners': owners}));
    } catch (_) {/* not remembered; the session itself is fine */}
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  bool belongsTo(Iterable<String> ownLogins) => owners.any(ownLogins.contains);
}

class TradingSessionController extends StateNotifier<ActiveTrading> {
  TradingSessionController(this._ref) : super(const ActiveTrading()) {
    // Keep the signed-in user's own account numbers at hand (the dashboard provider
    // is auto-dispose; this also keeps it alive while a session exists).
    _ref.listen<AsyncValue<CrmDashboard>>(crmDashboardProvider, (_, next) {
      final accts = next.valueOrNull?.accounts;
      if (accts != null) _owners = [for (final a in accts) a.login];
    }, fireImmediately: true);
  }
  final Ref _ref;

  /// Own CRM account numbers of the signed-in user (tags what is remembered).
  List<String> _owners = const [];

  void _remember(String login, {required bool managed}) {
    final owners = _owners;
    if (owners.isEmpty) return;
    unawaited(LastTrading.write(login, managed: managed, owners: owners));
  }

  ApiClient get _api => _ref.read(apiClientProvider);

  /// Serialises switches so a quick double-tap cannot interleave two logins.
  Future<void>? _busy;
  Future<void> _run(Future<void> Function() body) {
    final prev = _busy ?? Future<void>.value();
    final next = prev.catchError((_) {}).then((_) => body());
    _busy = next;
    return next;
  }

  String _gwMessage(Object e, String fallback) {
    if (e is DioException) {
      final d = e.response?.data;
      if (d is Map) {
        final m = d['message'];
        if (m is String && m.isNotEmpty) return m;
      }
      if (e.response == null) return 'Cannot reach the trading server. Check your connection.';
      if (e.response?.statusCode == 401) return 'Invalid account ID or password.';
      if (e.response?.statusCode == 429) return 'Too many attempts. Please wait a moment.';
    }
    return fallback;
  }

  /// Open one of the user's OWN accounts (from the CRM list) for trading.
  /// The trading credentials come from the CRM — the user never types them.
  Future<void> openOwn(String login) {
    // Show "switching" at once, so a screen opened right after this call never
    // shows the previous (e.g. read-only) account while the login is in flight.
    if (!(state.login == login && state.ready && !state.managed)) {
      state = ActiveTrading(login: login, loading: true, holderName: state.holderName);
    }
    return _run(() async {
        if (state.login == login && state.ready && !state.managed) return;
        state = ActiveTrading(login: login, loading: true, holderName: state.holderName);
        try {
          final res = await _ref.read(crmDioProvider).get('/accounts/$login/trading-session/');
          final d = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
          final pw = '${d['password'] ?? ''}';
          final data = await _api.post('/auth/account-login', {'login': login, 'password': pw}) as Map;
          final tokens = data.cast<String, dynamic>();
          await _ref.read(authControllerProvider.notifier).adoptSession(tokens, activeAccountId: tokens['accountId'] as String?);
          _ref.read(closedPositionIdsProvider.notifier).clear();
          _ref.read(sessionEpochProvider.notifier).state++;
          state = ActiveTrading(
            login: login,
            accountId: tokens['accountId'] as String?,
            readonly: tokens['readonly'] == true,
            holderName: '${tokens['holderName'] ?? ''}',
          );
          _remember(login, managed: false);
        } catch (e) {
          state = ActiveTrading(login: login, error: e is DioException ? _gwMessage(e, crmMessage(e)) : 'Could not open the account.');
        }
      });
  }

  /// "+" flow: sign into any trading account with its trading OR investor password.
  /// Returns null on success, otherwise the message to show in the dialog.
  Future<String?> addManaged(String login, String password) async {
    String? result;
    await _run(() async {
      final prev = state;
      state = ActiveTrading(login: prev.login, accountId: prev.accountId, readonly: prev.readonly, managed: prev.managed, holderName: prev.holderName, loading: true);
      try {
        final data = await _api.post('/auth/account-login', {'login': login.trim(), 'password': password}) as Map;
        final t = data.cast<String, dynamic>();
        final entry = ManagedAccount(
          login: '${t['login'] ?? login.trim()}',
          accountId: '${t['accountId']}',
          holderName: '${t['holderName'] ?? ''}',
          balance: crmNum(t['balance']),
          readonly: t['readonly'] == true,
          isDemo: t['isDemo'] == true,
          refreshToken: '${t['refreshToken']}',
        );
        await _ref.read(managedAccountsProvider.notifier).upsert(entry);
        await _ref.read(authControllerProvider.notifier).adoptSession(t, activeAccountId: entry.accountId);
        _ref.read(closedPositionIdsProvider.notifier).clear();
        _ref.read(sessionEpochProvider.notifier).state++;
        state = ActiveTrading(
          login: entry.login,
          accountId: entry.accountId,
          readonly: entry.readonly,
          managed: true,
          holderName: entry.holderName,
        );
        _remember(entry.login, managed: true);
      } catch (e) {
        state = prev;
        result = _gwMessage(e, 'Login failed. Please try again.');
      }
    });
    return result;
  }

  /// One-tap switch to a saved managed account — refresh-token based, no password.
  Future<String?> openManaged(ManagedAccount a) async {
    String? result;
    await _run(() async {
      final prev = state;
      state = ActiveTrading(login: a.login, loading: true, managed: true, holderName: a.holderName);
      try {
        final data = await _api.post('/auth/refresh', {'refreshToken': a.refreshToken}) as Map;
        final t = {...data.cast<String, dynamic>(), 'accountId': a.accountId};
        await _ref.read(authControllerProvider.notifier).adoptSession(t, activeAccountId: a.accountId);
        _ref.read(closedPositionIdsProvider.notifier).clear();
        _ref.read(sessionEpochProvider.notifier).state++;
        state = ActiveTrading(
          login: a.login,
          accountId: a.accountId,
          readonly: t['readonly'] == true || a.readonly,
          managed: true,
          holderName: a.holderName,
        );
        _remember(a.login, managed: true);
      } catch (e) {
        state = prev;
        final expired = e is DioException && e.response?.statusCode == 401;
        if (expired) await _ref.read(managedAccountsProvider.notifier).remove(a.login);
        result = expired
            ? 'This saved session has expired. Sign in to ${a.login} again with "+".'
            : _gwMessage(e, 'Could not open the account.');
      }
    });
    return result;
  }

  /// Sign-out: forget the session and what was remembered for the next start.
  void reset() {
    state = const ActiveTrading();
    unawaited(LastTrading.clear());
  }
}

final tradingSessionProvider =
    StateNotifierProvider<TradingSessionController, ActiveTrading>((ref) => TradingSessionController(ref));
