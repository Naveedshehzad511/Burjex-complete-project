import 'package:dio/dio.dart';

/// Interceptors every CRM client of the apps carries. Empty by default; the iPhone / iPad portal adds its location
/// check here at start-up (`X-Client-Platform` / `X-Geo-Ticket`, see the portal's `security/geo_gate.dart`).
final List<Interceptor> crmInterceptors = [];

/// A Dio for the CRM API with [crmInterceptors] attached. Every CRM client is built with this.
Dio newCrmDio(BaseOptions options) => Dio(options)..interceptors.addAll(crmInterceptors);
