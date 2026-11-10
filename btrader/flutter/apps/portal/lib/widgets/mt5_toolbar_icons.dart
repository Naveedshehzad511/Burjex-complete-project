import 'dart:math' as math;

import 'package:flutter/material.dart';

/// MT5's chart-toolbar glyphs, drawn so they match its red / blue look:
/// [Mt5OrderIcon] - a round "new order" mark (red quarter, blue ring);
/// [Mt5TradePanelIcon] - the one-click Buy / Sell panel switch (red | blue capsule).
/// Look only: the buttons that show them keep their actions.
class Mt5OrderIcon extends StatelessWidget {
  const Mt5OrderIcon({super.key, required this.size, required this.sell, required this.buy});
  final double size;
  final Color sell, buy;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _OrderPainter(sell, buy, Theme.of(context).colorScheme.surface));
}

class _OrderPainter extends CustomPainter {
  _OrderPainter(this.sell, this.buy, this.hole);
  final Color sell, buy, hole;

  @override
  void paint(Canvas c, Size s) {
    final o = s.center(Offset.zero);
    final r = s.shortestSide * 0.42;
    final w = s.shortestSide * 0.16;
    final rect = Rect.fromCircle(center: o, radius: r);
    // Blue ring, three quarters, from the top clockwise round to the left.
    c.drawArc(rect.deflate(w / 2), -math.pi / 2, math.pi * 1.5, false,
        Paint()
          ..color = buy
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.butt);
    // Red filled quarter, upper-left (MT5's clock-like mark).
    c.drawArc(rect, math.pi, math.pi / 2, true, Paint()..color = sell);
    // Hole so the red reads as a wedge on the ring.
    c.drawCircle(o, r * 0.34, Paint()..color = hole);
  }

  @override
  bool shouldRepaint(_OrderPainter o) => o.sell != sell || o.buy != buy || o.hole != hole;
}

class Mt5TradePanelIcon extends StatelessWidget {
  const Mt5TradePanelIcon({super.key, required this.size, required this.sell, required this.buy, required this.on});
  final double size;
  final Color sell, buy;

  /// Panel shown: full colour. Hidden: dimmed, the same switch as before.
  final bool on;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: on ? 1 : 0.55,
        child: CustomPaint(size: Size(size * 1.15, size), painter: _PanelPainter(sell, buy)),
      );
}

class _PanelPainter extends CustomPainter {
  _PanelPainter(this.sell, this.buy);
  final Color sell, buy;

  @override
  void paint(Canvas c, Size s) {
    final h = s.height * 0.62;
    final body = Rect.fromCenter(center: s.center(Offset.zero), width: s.width, height: h);
    final rr = RRect.fromRectAndRadius(body, Radius.circular(h * 0.28));
    c.save();
    c.clipRRect(rr);
    c.drawRect(Rect.fromLTRB(body.left, body.top, body.center.dx, body.bottom), Paint()..color = sell);
    c.drawRect(Rect.fromLTRB(body.center.dx, body.top, body.right, body.bottom), Paint()..color = buy);
    c.restore();
    // The white slot across the middle, as on MT5's icon.
    final slot = Rect.fromCenter(center: body.center, width: body.width * 0.46, height: h * 0.34);
    c.drawRRect(RRect.fromRectAndRadius(slot, Radius.circular(slot.height / 2)), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PanelPainter o) => o.sell != sell || o.buy != buy;
}
