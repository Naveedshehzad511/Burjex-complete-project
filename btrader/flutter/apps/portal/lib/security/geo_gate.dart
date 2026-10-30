import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The iPhone / iPad app's location rule (App Store guideline 3.2.2(viii)): sign-in and registration only where the
/// service is offered. The CRM decides (`/auth/geo-check/`, countries and messages set in its admin panel); this side
/// only reads the position (Core Location, "When In Use", see `ios/Runner/AppDelegate.swift`), sends it, and carries
/// the server's ticket with the sign-in. Android and the website never run any of it.
bool get geoChecked => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// What the user is shown when the location rule stops them.
class GeoPrompt {
  const GeoPrompt(this.message, {this.settings = false});
  final String message;

  /// Offer "Open Settings" (location access is off).
  final bool settings;
}

/// The outcome of one location check.
class GeoCheck {
  const GeoCheck({this.ticket, this.allowed = false, this.reason = '', this.message = ''});
  final String? ticket;
  final bool allowed;
  final String reason;
  final String message;
}

/// CRM paths that start a session: they carry the location ticket.
const _kSignInPaths = ['/auth/login/', '/auth/signup/', '/auth/verify-email-otp/', '/auth/totp/verify/', '/auth/google/', '/auth/apple/'];

const _kLocationNeeded = 'Burjex Prime needs your location to confirm you are in a country where the service is '
    'available. Allow location access for Burjex Prime in Settings and try again.';
const _kServicesOff = 'Location Services are turned off. Turn them on in Settings > Privacy & Security > Location '
    'Services, and allow them for Burjex Prime.';
const _kNoFix = 'Your location could not be confirmed right now. Check that Location Services are on and try again.';

class GeoGate {
  GeoGate._();
  static final instance = GeoGate._();

  static const _channel = MethodChannel('bx/location');

  /// The message on screen, if any ([GeoPromptHost]).
  final prompt = ValueNotifier<GeoPrompt?>(null);

  /// Signs the app out: a signed-in session whose location is no longer allowed. Set by the app.
  Future<void> Function()? onRefused;

  /// Tests: the HTTP client the gate's own requests use (the location check and a repeated request).
  @visibleForTesting
  Dio Function(BaseOptions options) debugDio = Dio.new;

  @visibleForTesting
  void debugReset() {
    _last = null;
    _lastAt = null;
    _running.clear();
    _signingOut = false;
    prompt.value = null;
  }

  GeoCheck? _last;
  DateTime? _lastAt;
  final _running = <String, Future<GeoCheck>>{};
  bool _signingOut = false;

  /// At start-up: every CRM request of the iPhone / iPad app goes through the check.
  void install() {
    if (!geoChecked || crmInterceptors.any((i) => i is _GeoInterceptor)) return;
    crmInterceptors.add(_GeoInterceptor(this));
  }

  /// A sign-in or registration screen opened: ask for the location permission now (not in the middle of the form) and
  /// get a ticket ready. Only a missing permission is shown here; whether this place is allowed is said on submit.
  Future<void> warmUp() async {
    if (!geoChecked) return;
    await check();
  }

  /// One location check (concurrent callers share it). [token]: a signed-in session's, recorded by the server.
  Future<GeoCheck> check({String? token}) {
    final key = token ?? '';
    final running = _running[key];
    if (running != null) return running;
    final f = _check(token);
    _running[key] = f;
    f.whenComplete(() => _running.remove(key));
    return f;
  }

  Future<GeoCheck> _check(String? token) async {
    var status = 'denied';
    try {
      status = await _channel.invokeMethod<String>('status') ?? 'denied';
      if (status == 'notDetermined') status = await _channel.invokeMethod<String>('request') ?? 'denied';
    } catch (_) {}
    if (status != 'granted') {
      prompt.value = GeoPrompt(status == 'servicesOff' ? _kServicesOff : _kLocationNeeded, settings: true);
      return const GeoCheck(reason: 'location_required');
    }
    Map<Object?, Object?>? pos;
    try {
      pos = await _channel.invokeMethod<Map<Object?, Object?>>('current');
    } catch (_) {}
    if (pos == null) return const GeoCheck(reason: 'unavailable', message: _kNoFix);
    try {
      final res = await debugDio(BaseOptions(
        baseUrl: BtConfig.crmBase,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'X-Client-Platform': 'ios', if (token != null) 'Authorization': 'Token $token'},
      )).post('/auth/geo-check/', data: {for (final e in pos.entries) '${e.key}': e.value});
      final d = (res.data as Map)['data'] as Map;
      final c = GeoCheck(
        ticket: d['ticket'] as String?,
        allowed: d['allowed'] == true,
        reason: '${d['reason'] ?? ''}',
        message: '${d['message'] ?? ''}',
      );
      _last = c;
      _lastAt = DateTime.now();
      return c;
    } catch (_) {
      return const GeoCheck(reason: 'unreachable');
    }
  }

  /// The ticket for a sign-in / registration: the one prepared when the screen opened while it is fresh and allowed,
  /// else a new check (the place or the network may have changed).
  Future<String?> _ticketForSignIn() async {
    final last = _last, at = _lastAt;
    if (last != null && last.allowed && at != null && DateTime.now().difference(at) < const Duration(minutes: 4)) {
      return last.ticket;
    }
    return (await check()).ticket;
  }

  /// A signed-in session may not go on: say why and sign out. A check that could not be made (no network, no position
  /// right now) signs no one out.
  void _refuse(GeoCheck c) {
    if (c.reason == 'unreachable') return;
    if (c.reason == 'unavailable') {
      prompt.value = const GeoPrompt(_kNoFix);
      return;
    }
    prompt.value = GeoPrompt(c.message.isNotEmpty ? c.message : _kLocationNeeded, settings: c.reason == 'location_required');
    if (_signingOut) return;
    _signingOut = true;
    unawaited(Future(() async {
      try {
        await onRefused?.call();
      } finally {
        _signingOut = false;
      }
    }));
  }

  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (_) {}
  }
}

String? _geoCode(Object? body) {
  if (body is! Map) return null;
  final d = body['data'];
  return d is Map && d['geo'] is String ? d['geo'] as String : null;
}

class _GeoInterceptor extends Interceptor {
  _GeoInterceptor(this.gate);
  final GeoGate gate;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    options.headers['X-Client-Platform'] = 'ios';
    if (_kSignInPaths.any(options.path.endsWith)) {
      final t = await gate._ticketForSignIn();
      if (t != null) options.headers['X-Geo-Ticket'] = t;
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final res = err.response;
    final geo = res?.statusCode == 403 ? _geoCode(res?.data) : null;
    if (geo == 'check_required' && err.requestOptions.extra['geoRetried'] != true) {
      // A signed-in session whose location has to be confirmed again: check, then repeat the request once.
      final auth = '${err.requestOptions.headers['Authorization'] ?? ''}';
      final c = await gate.check(token: auth.startsWith('Token ') ? auth.substring(6) : null);
      if (c.allowed) {
        try {
          err.requestOptions.extra['geoRetried'] = true;
          return handler.resolve(await gate.debugDio(BaseOptions()).fetch<dynamic>(err.requestOptions));
        } on DioException catch (again) {
          return handler.next(again);
        }
      }
      gate._refuse(c);
    } else if (geo == 'location_required') {
      // A sign-in refused for want of a location: offer Settings (the screen shows the message too).
      gate.prompt.value = GeoPrompt(
        (res?.data is Map ? '${(res!.data as Map)['message'] ?? ''}' : '').isNotEmpty
            ? '${(res!.data as Map)['message']}'
            : _kLocationNeeded,
        settings: true,
      );
    }
    handler.next(err);
  }
}

/// Shows [GeoGate.prompt] over the app: the reason, "Open Settings" when location access is off, and OK.
class GeoPromptHost extends StatelessWidget {
  const GeoPromptHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!geoChecked) return child;
    final gate = GeoGate.instance;
    return ValueListenableBuilder<GeoPrompt?>(
      valueListenable: gate.prompt,
      builder: (context, p, _) => Stack(children: [
        child,
        if (p != null)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Material(
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.location_on_outlined, size: 36, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 12),
                        Text(p.message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, height: 1.35)),
                        const SizedBox(height: 16),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          if (p.settings)
                            TextButton(
                              onPressed: () {
                                gate.prompt.value = null;
                                gate.openSettings();
                              },
                              child: const Text('Open Settings'),
                            ),
                          TextButton(onPressed: () => gate.prompt.value = null, child: const Text('OK')),
                        ]),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
