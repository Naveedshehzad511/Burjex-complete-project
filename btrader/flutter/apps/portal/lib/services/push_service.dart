import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Registers this device with the CRM so Deposit / Withdrawal pushes reach it
/// (CRM: `POST /notifications/device/`; delivery goes through FCM, which bridges
/// to APNs on iOS).
///
/// Push is optional infrastructure: when Firebase is not configured for the
/// build (no google-services / GoogleService-Info), or on web, every call is a
/// silent no-op and never affects login or trading.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _initTried = false;
  bool _ready = false;
  String? _crmToken;
  String? _deviceToken;
  StreamSubscription<String>? _refreshSub;

  Future<bool> _init() async {
    if (kIsWeb) return false;
    if (_initTried) return _ready;
    _initTried = true;
    try {
      await Firebase.initializeApp();
      final m = FirebaseMessaging.instance;
      await m.requestPermission(alert: true, badge: true, sound: true);
      // Show the banner + sound even while the app is open.
      await m.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      _ready = true;
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
    return _ready;
  }

  Dio _dio(String crmToken) => Dio(BaseOptions(
        baseUrl: BtConfig.crmBase,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Authorization': 'Token $crmToken'},
      ));

  String get _platform => defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Call after a CRM login / session restore. Safe to call repeatedly.
  Future<void> register(String crmToken) async {
    _crmToken = crmToken;
    if (!await _init()) return;
    try {
      final m = FirebaseMessaging.instance;
      final token = await m.getToken();
      if (token != null && token.isNotEmpty) await _send(token);
      _refreshSub ??= m.onTokenRefresh.listen(_send, onError: (_) {});
    } catch (e) {
      debugPrint('Push register failed: $e');
    }
  }

  Future<void> _send(String deviceToken) async {
    final crm = _crmToken;
    if (crm == null) return;
    _deviceToken = deviceToken;
    try {
      await _dio(crm).post('/notifications/device/', data: {'token': deviceToken, 'platform': _platform});
    } catch (e) {
      debugPrint('Push token upload failed: $e');
    }
  }

  /// Call on logout, before the CRM token is discarded, so the next user of this
  /// device does not receive the previous user's deposit alerts.
  Future<void> unregister(String crmToken) async {
    final device = _deviceToken;
    _crmToken = null;
    if (device == null) return;
    _deviceToken = null;
    try {
      await _dio(crmToken).delete('/notifications/device/', data: {'token': device});
    } catch (_) {/* best effort */}
  }
}
