import 'package:flutter/material.dart';

/// Tenant white-label branding, fetched from /v1/public/branding at launch.
class Branding {
  final String appName;
  final String? logoUrl;
  final Color primary;
  final Color accent;
  final String baseCurrency;

  const Branding({
    required this.appName,
    this.logoUrl,
    required this.primary,
    required this.accent,
    this.baseCurrency = 'USD',
  });

  /// Shown INSTANTLY at cold start while /public/branding is in flight, then
  /// replaced by the live fetch. Seeded from build-time dart-defines so each
  /// tenant build opens with its own name/colors/logo instead of flashing a
  /// generic (or wrong) brand. Keys: BRAND_NAME, BRAND_LOGO, BRAND_PRIMARY,
  /// BRAND_ACCENT — set them in config/<tenant>.json.
  static final fallback = Branding(
    appName: const String.fromEnvironment('BRAND_NAME', defaultValue: 'B-Trader'),
    logoUrl: const String.fromEnvironment('BRAND_LOGO').isEmpty
        ? null
        : const String.fromEnvironment('BRAND_LOGO'),
    primary: _hex(const String.fromEnvironment('BRAND_PRIMARY', defaultValue: '#1652F0'), const Color(0xFF1652F0)),
    accent: _hex(const String.fromEnvironment('BRAND_ACCENT', defaultValue: '#0BB07B'), const Color(0xFF0BB07B)),
  );

  factory Branding.fromJson(Map<String, dynamic> j) => Branding(
        appName: j['appName'] ?? 'B-Trader',
        logoUrl: j['logoUrl'],
        primary: _hex(j['primaryColor'], const Color(0xFF1652F0)),
        accent: _hex(j['accentColor'], const Color(0xFF0BB07B)),
        baseCurrency: j['baseCurrency'] ?? 'USD',
      );

  static Color _hex(dynamic v, Color fallback) {
    if (v is! String) return fallback;
    var s = v.replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    final n = int.tryParse(s, radix: 16);
    return n == null ? fallback : Color(n);
  }
}
