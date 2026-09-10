import 'package:dio/dio.dart';
import '../config.dart';

/// Holds auth state and tenant context. The ApiClient reads from it; the auth
/// controller writes to it. Kept separate so Dio interceptors stay simple.
class AuthStore {
  String? accessToken;
  String? refreshToken;
  String? role;
  String tenant = BtConfig.tenant;

  /// Called whenever the access/refresh token changes (e.g. after a silent
  /// refresh) so the new tokens are persisted to disk — without this, an app
  /// that refreshed in memory then restarted would load a stale token.
  Future<void> Function(AuthStore)? onTokens;

  /// Called when a refresh fails (refresh token invalid/expired) so the app can
  /// drop to the login screen instead of stranding the user on a 401.
  void Function()? onSessionLost;

  void clear() {
    accessToken = null;
    refreshToken = null;
    role = null;
  }
}

/// Dio wrapper for the B-Trader gateway. Attaches the bearer token + tenant
/// header on every call and transparently refreshes once on 401.
class ApiClient {
  ApiClient(this._auth, {String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: '${baseUrl ?? BtConfig.apiBase}/v1',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_auth.accessToken != null) {
          options.headers['Authorization'] = 'Bearer ${_auth.accessToken}';
        }
        if (_auth.tenant.isNotEmpty) options.headers['X-BT-Tenant'] = _auth.tenant;
        handler.next(options);
      },
      onError: (e, handler) async {
        if (e.response?.statusCode == 401 && _auth.refreshToken != null && !_skipRefreshOn401(e)) {
          final ok = await _refresh();
          if (ok) {
            final req = e.requestOptions;
            req.headers['Authorization'] = 'Bearer ${_auth.accessToken}';
            try {
              final clone = await _dio.fetch(req);
              return handler.resolve(clone);
            } catch (_) {/* fall through */}
          }
        }
        handler.next(e);
      },
    ));
  }

  final Dio _dio;
  final AuthStore _auth;

  bool _isRefreshCall(DioException e) => e.requestOptions.path.contains('/auth/refresh');

  bool _skipRefreshOn401(DioException e) {
    final p = e.requestOptions.path;
    return p.contains('/auth/refresh') ||
        p.contains('/auth/login') ||
        p.contains('/auth/account-login');
  }

  // Single-flight: collapse concurrent 401s into one refresh.
  Future<bool>? _refreshing;
  Future<bool> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  /// Public hook so other transports (e.g. the WebSocket) can proactively
  /// renew the access token without waiting for an HTTP 401.
  Future<bool> refreshAccessToken() {
    if (_auth.refreshToken == null) return Future.value(false);
    return _refresh();
  }

  Future<bool> _doRefresh() async {
    try {
      final res = await _dio.post('/auth/refresh', data: {'refreshToken': _auth.refreshToken});
      _auth.accessToken = res.data['accessToken'] as String?;
      // Backend keeps the same refresh token (non-rotating); tolerate either.
      _auth.refreshToken = (res.data['refreshToken'] as String?) ?? _auth.refreshToken;
      await _auth.onTokens?.call(_auth);
      return true;
    } on DioException catch (e) {
      // Only a definitive 401 means the session is truly gone (signed out,
      // revoked, or account disabled/deleted) — drop to login then. Network
      // blips, timeouts, and 5xx must NOT log the user out: keep the tokens and
      // let the next request retry, so a session persists until it's really ended.
      if (e.response?.statusCode == 401) {
        _auth.clear();
        _auth.onSessionLost?.call();
      }
      return false;
    } catch (_) {
      // Non-HTTP error (e.g. connectivity) — keep the session, retry later.
      return false;
    }
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async =>
      (await _dio.get(path, queryParameters: query)).data;
  Future<dynamic> post(String path, [dynamic body]) async => (await _dio.post(path, data: body ?? {})).data;
  Future<dynamic> patch(String path, [dynamic body]) async => (await _dio.patch(path, data: body ?? {})).data;
  Future<dynamic> put(String path, [dynamic body]) async => (await _dio.put(path, data: body ?? {})).data;
  Future<dynamic> delete(String path) async => (await _dio.delete(path)).data;

  Dio get raw => _dio;
}
