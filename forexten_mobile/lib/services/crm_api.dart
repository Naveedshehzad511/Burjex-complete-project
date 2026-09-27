import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:btrader_core/btrader_core.dart';

import '../config.dart';

final crmTokenProvider = FutureProvider<String?>((ref) async {
  ref.watch(authControllerProvider);
  final p = await SharedPreferences.getInstance();
  return p.getString('crm_token');
});

final crmApiProvider = Provider<CrmApi>((ref) {
  final token = ref.watch(crmTokenProvider).valueOrNull;
  return CrmApi(token);
});

class CrmApi {
  CrmApi(this.token);
  final String? token;

  Dio _dio() => Dio(BaseOptions(
        baseUrl: PortalConfig.crmBase,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          if (token != null && token!.isNotEmpty) 'Authorization': 'Token $token',
        },
      ));

  String get _missingToken => 'Sign in again to load CRM funding.';

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    if (token == null || token!.isEmpty) throw Exception(_missingToken);
    final res = await _dio().get(path, queryParameters: query);
    return _unwrap(res.data);
  }

  Future<Map<String, dynamic>> post(String path, [dynamic body]) async {
    if (token == null || token!.isEmpty) throw Exception(_missingToken);
    final res = await _dio().post(path, data: body ?? {});
    return _unwrap(res.data);
  }

  Map<String, dynamic> _unwrap(dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map['success'] == false) {
        throw Exception(_message(map, 'Request failed'));
      }
      final inner = map['data'];
      if (inner is Map) return Map<String, dynamic>.from(inner);
      if (inner is List) return {'_list': inner, 'message': map['message']};
      return map;
    }
    return {'_raw': data};
  }

  static String _message(Map data, String fallback) {
    final msg = data['message'];
    if (msg is String && msg.isNotEmpty) return msg;
    if (msg is List && msg.isNotEmpty) return msg.first.toString();
    return fallback;
  }
}
