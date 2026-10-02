import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

/// MT5-style circular/radial chart menu: an outer ring of drawing tools (trend
/// line, horizontal / vertical line, ray, arrow, rectangle, ellipse, Fibonacci)
/// and an inner ring of three wedges (Duplicate / Objects / Indicators), with a
/// non-interactive crosshair glyph at the very centre. Timeframes are NOT on this
/// menu — they live on the toolbar's timeframe button. Tapping a wedge fires
/// its action and closes the menu; tapping anywhere else inside the overlay
/// (empty inner space, or outside the outer ring) just dismisses it — this is
/// what gives the "tap again to close" behaviour with no dedicated close button.
///
/// Pure geometry + a single [GestureDetector]; no external charting library.
/// [center]/[outerRadius]/[innerRadius] are computed by the caller from the
/// available chart area, so the ring always fits and never clips.
class RadialChartMenu extends StatelessWidget {
  const RadialChartMenu({
    super.key,
    required this.center,
    required this.outerRadius,
    required this.innerRadius,
    this.tools = kRadialTools,
    this.activeTool,
    required this.onSelectTool,
    required this.onDuplicate,
    required this.onObjects,
    required this.onIndicators,
    required this.onDismiss,
  });

  final Offset center;
  final double outerRadius;
  final double innerRadius;
  final List<DrawingType> tools;

  /// The tool currently being placed, if any (highlighted on the ring).
  final DrawingType? activeTool;
  final ValueChanged<DrawingType> onSelectTool;
  final VoidCallback onDuplicate;
  final VoidCallback onObjects;
  final VoidCallback onIndicators;
  final VoidCallback onDismiss;

  // Inner-ring tool wedges, in "up = 0°, clockwise" degrees — stacked down the
  // left side of the ring, matching the MT5 reference layout.
  // Geometry below is kept for when the inner wedges are restored.
  // ignore_for_file: unused_field
  static const double _dupStart = 293, _dupEnd = 337;
  static const double _objStart = 248, _objEnd = 292;
  static const double _indStart = 203, _indEnd = 247;
  static const double _centerHoleFrac = 0.42; // fraction of innerRadius left fully inert

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _handleTap(d.localPosition),
      child: CustomPaint(
        size: Size.infinite,
        painter: _RadialMenuPainter(
          center: center,
          outerRadius: outerRadius,
          innerRadius: innerRadius,
          tools: tools,
          active: activeTool,
          ringColor: cs.surfaceContainerHighest,
          centerColor: cs.surface,
          highlight: cs.primary,
          onSurface: cs.onSurface,
          divider: Theme.of(context).dividerColor,
        ),
      ),
    );
  }

  void _handleTap(Offset p) {
    final v = p - center;
    final dist = v.distance;
    if (dist > outerRadius) {
      onDismiss();
      return;
    }
    var canvasAngle = math.atan2(v.dy, v.dx);
    if (canvasAngle < 0) canvasAngle += 2 * math.pi;
    // Re-express in "up = 0°, clockwise" degrees to match the painter's wedges.
    final upDeg = (((canvasAngle + math.pi / 2) % (2 * math.pi)) * 180 / math.pi);

    if (dist >= innerRadius) {
      final n = tools.length;
      final seg = 360.0 / n;
      final idx = (upDeg / seg).floor().clamp(0, n - 1);
      onSelectTool(tools[idx]);
      return;
    }
    if (dist < innerRadius * _centerHoleFrac) {
      onDismiss();
      return;
    }
    // Inner wedges hidden for now (see the painter): a tap anywhere inside just closes the menu.
    // if (upDeg >= _dupStart && upDeg <= _dupEnd) {
    //   onDuplicate();
    // } else if (upDeg >= _objStart && upDeg <= _objEnd) {
    //   onObjects();
    // } else if (upDeg >= _indStart && upDeg <= _indEnd) {
    //   onIndicators();
    // } else {
    //   onDismiss();
    // }
    onDismiss();
  }
}

/// The drawing tools offered on the outer ring, in clockwise order from the top.
const List<DrawingType> kRadialTools = [
  DrawingType.trendline,
  DrawingType.horizontalLine,
  DrawingType.verticalLine,
  DrawingType.ray,
  DrawingType.arrow,
  DrawingType.rectangle,
  DrawingType.ellipse,
  DrawingType.fibRetracement,
];

IconData radialToolIcon(DrawingType t) => switch (t) {
      DrawingType.trendline => Icons.trending_up,
      DrawingType.horizontalLine => Icons.horizontal_rule,
      DrawingType.verticalLine => Icons.more_vert,
      DrawingType.ray => Icons.call_made,
      DrawingType.arrow => Icons.north_east,
      DrawingType.rectangle => Icons.crop_square,
      DrawingType.ellipse => Icons.panorama_fish_eye,
      DrawingType.fibRetracement => Icons.stacked_line_chart,
    };

class _RadialMenuPainter extends CustomPainter {
  _RadialMenuPainter({
    required this.center,
    required this.outerRadius,
    required this.innerRadius,
    required this.tools,
    required this.active,
    required this.ringColor,
    required this.centerColor,
    required this.highlight,
    required this.onSurface,
    required this.divider,
  });

  final Offset center;
  final double outerRadius, innerRadius;
  final List<DrawingType> tools;
  final DrawingType? active;
  final Color ringColor, centerColor, highlight, onSurface, divider;

  double _rad(double upDeg) => (upDeg * math.pi / 180) - math.pi / 2;

  void _paintIcon(Canvas canvas, IconData icon, Offset at, double size, Color color) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontSize: size, fontFamily: icon.fontFamily, package: icon.fontPackage, color: color),
    );
    tp.layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  void _wedgePath(Canvas canvas, double rInner, double rOuter, double startUpDeg, double endUpDeg, Paint paint) {
    final startAngle = _rad(startUpDeg);
    final sweep = (endUpDeg - startUpDeg) * math.pi / 180;
    final path = Path()
      ..addArc(Rect.fromCircle(center: center, radius: rOuter), startAngle, sweep)
      ..arcTo(Rect.fromCircle(center: center, radius: rInner), startAngle + sweep, -sweep, false)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // A soft backdrop so the ring clearly floats above the candles.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black.withValues(alpha: 0.30));

    final n = tools.length;
    final seg = 360.0 / n;

    // Outer ring background.
    canvas.drawCircle(center, outerRadius, Paint()..color = ringColor.withValues(alpha: 0.97));

    for (var i = 0; i < n; i++) {
      final tool = tools[i];
      final startDeg = i * seg, endDeg = (i + 1) * seg;
      final isSel = tool == active;
      if (isSel) {
        _wedgePath(canvas, innerRadius, outerRadius, startDeg, endDeg, Paint()..color = highlight);
      }
      final sepAngle = _rad(startDeg);
      canvas.drawLine(
        center + Offset(math.cos(sepAngle), math.sin(sepAngle)) * innerRadius,
        center + Offset(math.cos(sepAngle), math.sin(sepAngle)) * outerRadius,
        Paint()
          ..color = divider.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
      final midAngle = _rad(startDeg + seg / 2);
      final labelR = (outerRadius + innerRadius) / 2;
      final pos = center + Offset(math.cos(midAngle), math.sin(midAngle)) * labelR;
      final fg = isSel ? Colors.white : onSurface;
      // Icon, with a short name underneath when the ring is thick enough to fit it.
      final roomy = (outerRadius - innerRadius) > 52;
      _paintIcon(canvas, radialToolIcon(tool), pos - Offset(0, roomy ? 8 : 0), roomy ? 22 : 20, fg);
      if (roomy) {
        final tp = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);
        tp.text = TextSpan(text: tool.shortLabel, style: TextStyle(fontSize: 9.5, fontWeight: isSel ? FontWeight.w800 : FontWeight.w600, color: fg));
        tp.layout();
        tp.paint(canvas, pos + Offset(-tp.width / 2, 8));
      }
    }

    canvas.drawCircle(center, outerRadius, Paint()
      ..color = divider.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);

    // Inner disc (tool wedges live here) + border between the two rings.
    canvas.drawCircle(center, innerRadius, Paint()..color = centerColor);
    canvas.drawCircle(center, innerRadius, Paint()
      ..color = divider.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);

    final holeR = innerRadius * RadialChartMenu._centerHoleFrac;
    // The three inner wedges (Duplicate / Objects / Indicators) are hidden for now; the callbacks
    // and geometry stay so they can be switched back on by restoring this list and the tap
    // branches in `_handleTap`.
    const wedges = <(double, double, IconData)>[
      // (RadialChartMenu._dupStart, RadialChartMenu._dupEnd, Icons.filter_none_outlined),
      // (RadialChartMenu._objStart, RadialChartMenu._objEnd, Icons.show_chart),
      // (RadialChartMenu._indStart, RadialChartMenu._indEnd, Icons.tune),
    ];
    for (final (start, end, icon) in wedges) {
      _wedgePath(canvas, holeR, innerRadius, start, end, Paint()..color = onSurface.withValues(alpha: 0.08));
      final mid = _rad((start + end) / 2);
      final r = (holeR + innerRadius) / 2;
      _paintIcon(canvas, icon, center + Offset(math.cos(mid), math.sin(mid)) * r, 18, onSurface);
    }

    // Centre crosshair glyph (purely decorative — the hole just dismisses).
    canvas.drawCircle(center, holeR, Paint()..color = ringColor.withValues(alpha: 0.5));
    _paintIcon(canvas, Icons.add, center, 18, onSurface.withValues(alpha: 0.85));
  }

  @override
  bool shouldRepaint(covariant _RadialMenuPainter old) =>
      old.active != active ||
      old.center != center ||
      old.outerRadius != outerRadius ||
      old.innerRadius != innerRadius;
}
