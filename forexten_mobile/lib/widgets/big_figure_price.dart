import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

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
          TextSpan(text: f.big, style: base.copyWith(fontSize: baseSize * 1.55, fontWeight: FontWeight.w700)),
          if (f.sup.isNotEmpty)
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Text(f.sup, style: base.copyWith(fontSize: baseSize * 0.75)),
            ),
        ],
      ),
    );
  }
}
