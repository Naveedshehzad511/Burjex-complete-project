import 'dart:convert';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// iOS has no Roboto: unless the app ships it, iOS falls back to San Francisco, which draws every weight the app
/// uses visibly bolder than Android. The theme's font must be one the app bundles, in every weight it uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the theme font is the bundled Roboto, with 400-800 all shipped', () async {
    expect(AppTheme.light(Branding.fallback).textTheme.bodyMedium?.fontFamily, kAppFontFamily);
    expect(AppTheme.dark(Branding.fallback).textTheme.titleLarge?.fontFamily, kAppFontFamily);

    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    final family = manifest.cast<Map>().where((f) => f['family'] == kAppFontFamily).toList();
    expect(family, hasLength(1), reason: 'the app must bundle $kAppFontFamily');
    final fonts = (family.single['fonts'] as List).cast<Map>();
    expect({for (final f in fonts) f['weight'] ?? 400}, containsAll(<int>[400, 500, 600, 700, 800]));
    for (final f in fonts) {
      final data = await rootBundle.load(f['asset'] as String);
      expect(data.lengthInBytes, greaterThan(100000), reason: '${f['asset']} is a real font file');
    }
  });
}
