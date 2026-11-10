import 'dart:math' as math;

import 'package:flutter/material.dart';

/// MT5's chart-toolbar glyphs, drawn to match its red / blue look:
/// [Mt5OrderIcon] - "new order": a red left half-ring, a blue right half-ring, clock hands inside;
/// [Mt5TradePanelIcon] - the one-click Buy / Sell panel switch: a red | blue rounded square with a
/// white bar across. Look only: the buttons that show them keep their actions.
class Mt5OrderIcon extends StatelessWidget {
  const Mt5OrderIcon({super.key, required this.size, required this.sell, required this.buy});
  final double size;
  final Color sell, buy;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _OrderPainter(sell, buy, Theme.of(context).colorScheme.onSurface));
}

class _OrderPainter extends CustomPainter {
  _OrderPainter(this.sell, this.buy, this.hands);
  final Color sell, buy, hands;

  @override
  void paint(Canvas c, Size s) {
    final o = s.center(Offset.zero);
    final w = s.shortestSide * 0.17; // ring thickness
    final r = s.shortestSide / 2 - w / 2;
    final rect = Rect.fromCircle(center: o, radius: r);
    const gap = 0.32; // radians left open at the top and bottom between the halves
    Paint ring(Color col) => Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    // Left half red, right half blue (canvas angles: 0 = right, clockwise).
    c.drawArc(rect, math.pi / 2 + gap / 2, math.pi - gap, false, ring(sell));
    c.drawArc(rect, -math.pi / 2 + gap / 2, math.pi - gap, false, ring(buy));
    // Clock hands: one up, one to the lower right.
    final hand = Paint()
      ..color = hands
      ..strokeWidth = w * 0.62
      ..strokeCap = StrokeCap.round;
    final inner = r - w * 0.9;
    c.drawLine(o, o + Offset(0, -inner * 0.85), hand);
    c.drawLine(o, o + Offset(inner * 0.55, inner * 0.55), hand);
  }

  @override
  bool shouldRepaint(_OrderPainter o) => o.sell != sell || o.buy != buy || o.hands != hands;
}

class Mt5TradePanelIcon extends StatelessWidget {
  const Mt5TradePanelIcon({super.key, required this.size, required this.sell, required this.buy, required this.on});
  final double size;
  final Color sell, buy;

  /// Panel shown: full colour. Hidden: dimmed, the same switch as before.
  final bool on;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: on ? 1 : 0.5,
        child: CustomPaint(size: Size.square(size), painter: _PanelPainter(sell, buy)),
      );
}

class _PanelPainter extends CustomPainter {
  _PanelPainter(this.sell, this.buy);
  final Color sell, buy;

  @override
  void paint(Canvas c, Size s) {
    final side = s.shortestSide * 0.88;
    final body = Rect.fromCenter(center: s.center(Offset.zero), width: side, height: side * 0.86);
    final rr = RRect.fromRectAndRadius(body, Radius.circular(side * 0.2));
    c.save();
    c.clipRRect(rr);
    c.drawRect(Rect.fromLTRB(body.left, body.top, body.center.dx, body.bottom), Paint()..color = sell);
    c.drawRect(Rect.fromLTRB(body.center.dx, body.top, body.right, body.bottom), Paint()..color = buy);
    c.restore();
    // The white bar across the middle, as on MT5's icon.
    final bar = Rect.fromCenter(center: body.center, width: body.width * 0.5, height: body.height * 0.32);
    c.drawRRect(RRect.fromRectAndRadius(bar, Radius.circular(bar.height / 2)), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PanelPainter o) => o.sell != sell || o.buy != buy;
}
