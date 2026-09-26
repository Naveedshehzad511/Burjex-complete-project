import 'package:flutter/material.dart';

/// Onboarding card image from `assets/branding/{1,2,3,4}.png` (or jpg/webp).
/// Drop replacement artwork in that folder using those file names.
class BrandingSlide extends StatelessWidget {
  const BrandingSlide({super.key, required this.index});

  /// 0-based slide index.
  final int index;

  static const exts = ['.png', '.jpg', '.jpeg', '.webp'];

  String get _stem => '${index + 1}';

  @override
  Widget build(BuildContext context) {
    return _try(0);
  }

  Widget _try(int extIndex) {
    final path = 'assets/branding/$_stem${exts[extIndex]}';
    return Image.asset(
      path,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) {
        if (extIndex + 1 < exts.length) return _try(extIndex + 1);
        return const ColoredBox(color: Colors.white);
      },
    );
  }
}
