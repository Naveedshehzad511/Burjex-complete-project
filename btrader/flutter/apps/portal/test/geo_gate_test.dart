import 'dart:convert';
import 'dart:typed_data';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/security/geo_gate.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The iPhone / iPad app's location rule, app side: the position goes to the CRM, its ticket rides on sign-ins, a session
/// the CRM wants re-checked is checked and its request repeated, and a refused one is signed out. Android: untouched.

const _channel = MethodChannel('bx/location');

/// Fake CRM: answers /auth/geo-check/ with [allowed]; other requests answer 403 check_required until a check passed.
class _Crm implements HttpClientAdapter {
  bool allowed = true;
  bool verified = false;
  final requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    Map<String, dynamic> out;
    var status = 200;
    if (o.path.endsWith('/auth/geo-check/')) {
      if (allowed && o.headers['Authorization'] != null) verified = true;
      out = {
        'success': true,
        'data': {
          'allowed': allowed,
          'reason': allowed ? 'allowed' : 'country_blocked',
          'message': allowed ? '' : 'Only in Pakistan.',
          'ticket': allowed ? 'T-ok' : 'T-no',
        },
      };
    } else if (o.path.endsWith('/auth/login/')) {
      out = {'success': true, 'data': {'token': 'abc'}};
    } else if (!verified) {
      status = 403;
      out = {'success': false, 'message': 'Confirm location.', 'data': {'geo': 'check_required'}};
    } else {
      out = {'success': true, 'data': {'ok': 1}};
    }
    return ResponseBody.fromString(jsonEncode(out), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Crm crm;
  late List<String> calls;
  var permission = 'granted';
  var signedOut = 0;
  final gate = GeoGate.instance;

  Dio dio() => newCrmDio(BaseOptions(baseUrl: 'http://crm.test'))..httpClientAdapter = crm;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    crm = _Crm();
    calls = [];
    permission = 'granted';
    signedOut = 0;
    gate.debugReset();
    gate.debugDio = (o) => Dio(o.copyWith(baseUrl: 'http://crm.test'))..httpClientAdapter = crm;
    gate.onRefused = () async => signedOut++;
    crmInterceptors.clear();
    gate.install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'status':
          return permission;
        case 'request':
          return permission == 'notDetermined' ? 'granted' : permission;
        case 'current':
          return {'latitude': 24.86, 'longitude': 67.01, 'accuracy': 30.0, 'simulated': false};
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    crmInterceptors.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test('every CRM request says it comes from the iPhone / iPad app; a sign-in carries the location ticket', () async {
    await dio().post('/auth/login/', data: {'username': 'a', 'password': 'b'});
    final login = crm.requests.lastWhere((r) => r.path.endsWith('/auth/login/'));
    expect(login.headers['X-Client-Platform'], 'ios');
    expect(login.headers['X-Geo-Ticket'], 'T-ok');
    final check = crm.requests.firstWhere((r) => r.path.endsWith('/auth/geo-check/'));
    expect(check.data['latitude'], 24.86);
  });

  test('the location asked for when the form opened is reused for the sign-in', () async {
    await gate.warmUp();
    await dio().post('/auth/login/', data: {});
    expect(crm.requests.where((r) => r.path.endsWith('/auth/geo-check/')), hasLength(1));
  });

  test('first time: the permission is asked for once', () async {
    permission = 'notDetermined';
    await gate.warmUp();
    expect(calls, containsAllInOrder(['status', 'request', 'current']));
  });

  test('location access off: Settings is offered and nothing is sent', () async {
    permission = 'denied';
    await gate.warmUp();
    expect(gate.prompt.value?.settings, isTrue);
    expect(calls, isNot(contains('request')), reason: 'never asked again after a refusal');
    expect(crm.requests, isEmpty);
  });

  test('a signed-in session the CRM wants re-checked is checked and the request repeated', () async {
    final res = await dio().get('/me/', options: Options(headers: {'Authorization': 'Token abc'}));
    expect(res.statusCode, 200);
    final check = crm.requests.firstWhere((r) => r.path.endsWith('/auth/geo-check/'));
    expect(check.headers['Authorization'], 'Token abc', reason: 'the check is recorded for this session');
    expect(signedOut, 0);
  });

  test('a session that is now abroad is told why and signed out', () async {
    crm.allowed = false;
    await expectLater(dio().get('/me/', options: Options(headers: {'Authorization': 'Token abc'})), throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    expect(gate.prompt.value?.message, 'Only in Pakistan.');
    expect(signedOut, 1);
  });

  test('Android: nothing is added', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    crmInterceptors.clear();
    gate.install();
    expect(crmInterceptors, isEmpty);
    await dio().post('/auth/login/', data: {});
    expect(crm.requests.single.headers.containsKey('X-Client-Platform'), isFalse);
    expect(calls, isEmpty);
  });
}
