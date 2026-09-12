import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Official-style Google "G" and Apple logo for onboarding social buttons.
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/branding/google.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => CustomPaint(size: Size.square(size), painter: _GoogleGPainter()),
    );
  }
}

class AppleMark extends StatelessWidget {
  const AppleMark({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/branding/apple.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => CustomPaint(size: Size.square(size), painter: _ApplePainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s / 48, s / 48);

    Path sector(double startDeg, double sweepDeg) {
      const c = Offset(24, 24);
      const ro = 20.0;
      const ri = 12.0;
      final start = startDeg * math.pi / 180;
      final sweep = sweepDeg * math.pi / 180;
      final p = Path()
        ..moveTo(c.dx + ro * math.cos(start), c.dy + ro * math.sin(start))
        ..arcTo(Rect.fromCircle(center: c, radius: ro), start, sweep, false)
        ..lineTo(c.dx + ri * math.cos(start + sweep), c.dy + ri * math.sin(start + sweep))
        ..arcTo(Rect.fromCircle(center: c, radius: ri), start + sweep, -sweep, false)
        ..close();
      return p;
    }

    canvas.drawPath(sector(38, 107), const Paint()..color = Color(0xFF34A853));
    canvas.drawPath(sector(145, 70), const Paint()..color = Color(0xFFFBBC05));
    canvas.drawPath(sector(215, 108), const Paint()..color = Color(0xFFEA4335));
    canvas.drawPath(sector(-38, 76), const Paint()..color = Color(0xFF4285F4));
    canvas.drawRRect(
      RRect.fromLTRBR(23.5, 20, 44, 28, const Radius.circular(1.2)),
      const Paint()..color = Color(0xFF4285F4),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ApplePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s / 24, s / 24);
    final paint = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.fill;

    final body = Path()
      ..moveTo(18.71, 19.5)
      ..relativeCubicTo(-0.83, 1.24, -1.71, 2.45, -3.05, 2.47)
      ..relativeCubicTo(-1.34, 0.03, -1.77, -0.79, -3.29, -0.79)
      ..relativeCubicTo(-1.53, 0, -2, 0.77, -3.27, 0.82)
      ..relativeCubicTo(-1.31, 0.05, -2.3, -1.32, -3.14, -2.53)
      ..cubicTo(4.25, 17, 2.94, 12.45, 4.7, 9.39)
      ..relativeCubicTo(0.87, -1.52, 2.43, -2.48, 4.24, -2.51)
      ..relativeCubicTo(1.28, -0.02, 2.5, 0.87, 3.29, 0.87)
      ..relativeCubicTo(0.78, 0, 2.26, -1.07, 3.54, -0.91)
      ..relativeCubicTo(0.6, 0.03, 2.31, 0.25, 3.51, 1.88)
      ..relativeCubicTo(-0.09, 0.06, -2.17, 1.28, -2.15, 3.81)
      ..relativeCubicTo(0.03, 3.02, 2.65, 4.03, 2.68, 4.04)
      ..relativeCubicTo(-0.03, 0.07, -0.42, 1.44, -1.38, 2.83);

    final leaf = Path()
      ..moveTo(13, 3.5)
      ..relativeCubicTo(0.73, -0.83, 1.94, -1.46, 2.94, -1.5)
      ..relativeCubicTo(0.13, 1.17, -0.34, 2.35, -1.04, 3.19)
      ..relativeCubicTo(-0.69, 0.85, -1.83, 1.51, -2.95, 1.42)
      ..relativeCubicTo(-0.15, -1.15, 0.41, -2.35, 1.05, -3.11)
      ..close();

    canvas.drawPath(body, paint);
    canvas.drawPath(leaf, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
