import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

class CandleChart extends StatelessWidget {
  const CandleChart({super.key, required this.candles, required this.digits, this.lastPrice});
  final List<Candle> candles;
  final int digits;
  final double? lastPrice;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (candles.isEmpty) {
      return Center(child: Text('No candles', style: TextStyle(color: Theme.of(context).hintColor)));
    }
    return CustomPaint(
      painter: _CandlePainter(
        candles: candles.length > 120 ? candles.sublist(candles.length - 120) : candles,
        up: tc.up,
        down: tc.down,
        grid: Theme.of(context).dividerColor,
        last: lastPrice,
        digits: digits,
        labelColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.candles,
    required this.up,
    required this.down,
    required this.grid,
    required this.last,
    required this.digits,
    required this.labelColor,
  });

  final List<Candle> candles;
  final Color up, down, grid, labelColor;
  final double? last;
  final int digits;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    var lo = candles.first.l, hi = candles.first.h;
    for (final c in candles) {
      if (c.l < lo) lo = c.l;
      if (c.h > hi) hi = c.h;
    }
    if (last != null) {
      if (last! < lo) lo = last!;
      if (last! > hi) hi = last!;
    }
    final pad = (hi - lo).abs() * 0.08 + 1e-9;
    lo -= pad;
    hi += pad;
    final span = hi - lo;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final slot = size.width / candles.length;
    final bodyW = (slot * 0.62).clamp(1.5, 9.0);
    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final x = (i + 0.5) * slot;
      final bull = c.c >= c.o;
      final paint = Paint()
        ..color = bull ? up : down
        ..strokeWidth = 1;
      double y(double p) => size.height * (1 - (p - lo) / span);
      canvas.drawLine(Offset(x, y(c.h)), Offset(x, y(c.l)), paint);
      final top = y(bull ? c.c : c.o);
      final bot = y(bull ? c.o : c.c);
      canvas.drawRect(Rect.fromLTRB(x - bodyW / 2, top, x + bodyW / 2, bot == top ? top + 1 : bot), paint);
    }

    if (last != null) {
      final y = size.height * (1 - (last! - lo) / span);
      final p = Paint()
        ..color = labelColor
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      final tp = TextPainter(
        text: TextSpan(text: last!.toStringAsFixed(digits), style: TextStyle(color: labelColor, fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 4, (y - tp.height - 2).clamp(0, size.height - tp.height)));
    }
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) =>
      old.candles != candles || old.last != last || old.up != up || old.down != down;
}
