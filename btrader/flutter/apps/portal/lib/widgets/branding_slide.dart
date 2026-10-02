import 'package:flutter/material.dart';

import '../crm/onboarding_slides.dart';

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

/// A landing slide managed in the CRM (image + optional title / description). With no copy it is
/// full-bleed artwork like the bundled slides; with copy it is the image over a title and a short
/// description. A failed or slow image falls back to the page colour — never a broken-image icon.
class RemoteBrandingSlide extends StatelessWidget {
  const RemoteBrandingSlide({super.key, required this.slide});
  final OnboardingSlideData slide;

  static const _ink = Color(0xFF111111);

  Widget _image(BoxFit fit) => Image.network(
        slide.imageUrl,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );

  @override
  Widget build(BuildContext context) {
    if (!slide.hasText) return _image(BoxFit.cover);
    // Transparent: the landing screen's soft grey-to-white gradient shows behind the illustration.
    return Column(children: [
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(32, 40, 32, 8), child: _image(BoxFit.contain))),
        if (slide.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(slide.title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _ink, fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
          ),
        if (slide.description.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(slide.description,
                textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF444A52), fontSize: 15, height: 1.4)),
          ),
        const SizedBox(height: 8),
      ]);
  }
}
