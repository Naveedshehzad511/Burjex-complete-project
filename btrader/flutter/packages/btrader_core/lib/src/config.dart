import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Build-time / platform-aware BTrader gateway config.
///
/// Override with `--dart-define=API_BASE=...` and `--dart-define=WS_URL=...`.
/// When those are unset, host resolution mirrors the CRM app:
/// - Android emulator (default): `10.0.2.2`
/// - Android physical / iOS: `LAN_HOST` (default `192.168.0.100`)
/// - Desktop / web: `127.0.0.1`
///
/// Pass `--dart-define=USE_LAN=true` on Android to force `LAN_HOST`
/// (needed for a physical device).
class BtConfig {
  BtConfig._();

  static const String _envApiBase = String.fromEnvironment('API_BASE');
  static const String _envWsUrl = String.fromEnvironment('WS_URL');
  static const String _lanHost = String.fromEnvironment(
    'LAN_HOST',
    defaultValue: '192.168.0.100',
  );
  static const bool _useLan = bool.fromEnvironment('USE_LAN', defaultValue: false);

  // Dev: sent as X-BT-Tenant. Production resolves the tenant by host instead.
  static const tenant = String.fromEnvironment('TENANT', defaultValue: 'demo');

  static const int apiPort = 4100;
  static const int wsPort = 4101;

  static bool get _preferEmulatorHost => !_useLan;

  /// Host used when API_BASE / WS_URL are not provided via dart-define.
  static String get resolvedHost {
    if (kIsWeb) return '127.0.0.1';
    try {
      if (Platform.isAndroid) {
        return _preferEmulatorHost ? '10.0.2.2' : _lanHost;
      }
      if (Platform.isIOS) return _lanHost;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        return '127.0.0.1';
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  static String get apiBase {
    if (_envApiBase.isNotEmpty) {
      return _envApiBase.replaceAll(RegExp(r'/+$'), '');
    }
    // Web builds are served behind Caddy on portal/admin.burjexprime.net —
    // same-origin /v1 (no hardcoded :4100, which breaks HTTPS / mixed content).
    if (kIsWeb) return Uri.base.origin;
    return 'http://$resolvedHost:$apiPort';
  }

  static String get wsUrl {
    if (_envWsUrl.isNotEmpty) return _envWsUrl;
    if (kIsWeb) {
      final u = Uri.base;
      final scheme = u.scheme == 'https' ? 'wss' : 'ws';
      return '$scheme://${u.host}${u.hasPort ? ':${u.port}' : ''}';
    }
    return 'ws://$resolvedHost:$wsPort';
  }
}
