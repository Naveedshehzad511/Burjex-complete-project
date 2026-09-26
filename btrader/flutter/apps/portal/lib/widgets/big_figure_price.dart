import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

/// MT5-style price: the bulk normal-size, the two pip digits enlarged, and the
/// fractional-pip digit as a small superscript — all in one color.
class BigFigurePrice extends StatelessWidget {
  const BigFigurePrice({
    super.key,
    required this.value,
    required this.digits,
    required this.color,
    this.baseSize = 15,
  });
  final double value;
  final int digits;
  final Color color;
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    final f = mt5Price(value, digits);
    final base = TextStyle(
      color: color,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return RichText(
      text: TextSpan(
        style: base.copyWith(fontSize: baseSize),
        children: [
          TextSpan(text: f.normal),
          TextSpan(text: f.big, style: base.copyWith(fontSize: baseSize * 1.6, fontWeight: FontWeight.w700)),
          if (f.sup.isNotEmpty)
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Transform.translate(
                offset: Offset(0, baseSize * 0.05),
                child: Text(f.sup, style: base.copyWith(fontSize: baseSize * 0.8)),
              ),
            ),
        ],
      ),
    );
  }
}
