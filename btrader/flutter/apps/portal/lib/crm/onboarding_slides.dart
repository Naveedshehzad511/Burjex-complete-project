import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One landing-carousel slide, as managed in the CRM
/// (`GET /api/v1/branding/slides/`).
class OnboardingSlideData {
  const OnboardingSlideData({required this.id, required this.title, required this.description, required this.imageUrl});

  final int id;
  final String title;
  final String description;
  final String imageUrl;

  /// A slide with no copy is just full-bleed artwork (like the bundled slides).
  bool get hasText => title.trim().isNotEmpty || description.trim().isNotEmpty;

  factory OnboardingSlideData.fromJson(Map<String, dynamic> j) => OnboardingSlideData(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: '${j['title'] ?? ''}',
        description: '${j['description'] ?? ''}',
        imageUrl: '${j['image_url'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'description': description, 'image_url': imageUrl};
}

/// The carousel as the app should show it: the slides plus the auto-advance interval.
class OnboardingSlides {
  const OnboardingSlides(this.slides, {this.interval = const Duration(seconds: 3)});
  final List<OnboardingSlideData> slides;
  final Duration interval;

  static const empty = OnboardingSlides([]);

  static OnboardingSlides fromBody(dynamic body) {
    if (body is! Map || body['success'] != true || body['data'] is! Map) return empty;
    final data = body['data'] as Map;
    final raw = data['slides'];
    final slides = [
      if (raw is List)
        for (final e in raw)
          if (e is Map<String, dynamic>) OnboardingSlideData.fromJson(e),
    ].where((s) => s.imageUrl.isNotEmpty).toList();
    final secs = (data['interval_seconds'] as num?)?.toInt() ?? 3;
    return OnboardingSlides(slides, interval: Duration(seconds: secs.clamp(2, 15)));
  }
}

const _kSlidesCacheKey = 'onboarding_slides_cache';

/// Landing slides from the CRM. Emits the last good copy immediately (so the carousel is
/// right on the first frame, even offline), then the fresh list. An empty list means "use
/// the bundled artwork" — the landing screen never ends up blank.
final onboardingSlidesProvider = StreamProvider<OnboardingSlides>((ref) async* {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_kSlidesCacheKey);
  if (cached != null) {
    try {
      final c = OnboardingSlides.fromBody(jsonDecode(cached));
      if (c.slides.isNotEmpty) yield c;
    } catch (_) {/* a corrupt cache is just ignored */}
  }
  try {
    final res = await Dio(BaseOptions(
      baseUrl: BtConfig.crmBase,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
    )).get('/branding/slides/');
    final fresh = OnboardingSlides.fromBody(res.data);
    // Cache even an empty answer: if the admin removed every slide, don't keep showing stale ones.
    await prefs.setString(_kSlidesCacheKey, jsonEncode(res.data));
    yield fresh;
  } catch (_) {
    // Offline / CRM down: keep whatever was already emitted (cache), else the bundled slides show.
  }
});
