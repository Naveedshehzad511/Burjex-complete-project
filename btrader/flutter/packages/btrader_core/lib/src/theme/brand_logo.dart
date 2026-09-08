import 'package:flutter/material.dart';
import '../models/branding.dart';

/// White-label brand mark. Renders the tenant's [Branding.logoUrl] when set,
/// otherwise a colored tile with the first letter of the app name — so every
/// surface follows the tenant's branding with no hardcoded logo.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, required this.branding, this.size = 40});

  final Branding branding;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.26;
    final url = branding.logoUrl;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // If the logo fails to load, fall back to the lettered tile rather
          // than showing a broken image.
          errorBuilder: (_, __, ___) => _tile(radius),
          loadingBuilder: (_, child, progress) => progress == null ? child : _tile(radius),
        ),
      );
    }
    return _tile(radius);
  }

  Widget _tile(double radius) {
    final name = branding.appName.trim();
    final letter = name.isNotEmpty ? name[0].toUpperCase() : 'B';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: branding.primary,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.6, height: 1.0),
      ),
    );
  }
}
