/// User-drawn chart objects (horizontal line, trendline, Fibonacci retracement).
/// Anchors are stored in chart space — (time, price) — not pixels, so a drawing
/// stays pinned to the same bars/levels through pan, zoom and timeframe changes.

enum DrawingType { horizontalLine, trendline, fibRetracement }

extension DrawingTypeMeta on DrawingType {
  String get label => switch (this) {
        DrawingType.horizontalLine => 'Horizontal line',
        DrawingType.trendline => 'Trend line',
        DrawingType.fibRetracement => 'Fib retracement',
      };

  String get shortLabel => switch (this) {
        DrawingType.horizontalLine => 'H-Line',
        DrawingType.trendline => 'Trend',
        DrawingType.fibRetracement => 'Fib',
      };

  /// Number of taps needed to define the object.
  int get anchorCount => this == DrawingType.horizontalLine ? 1 : 2;

  int get defaultColor => switch (this) {
        DrawingType.horizontalLine => 0xFFFFB74D,
        DrawingType.trendline => 0xFF42A5F5,
        DrawingType.fibRetracement => 0xFF26A69A,
      };
}

/// Standard Fibonacci retracement levels (0 → 1).
const List<double> kFibLevels = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];

/// A single (time, price) anchor point in chart space.
class DrawingAnchor {
  final int t; // epoch seconds
  final double price;
  const DrawingAnchor(this.t, this.price);

  Map<String, dynamic> toJson() => {'t': t, 'p': price};
  factory DrawingAnchor.fromJson(Map<String, dynamic> j) =>
      DrawingAnchor((j['t'] as num).toInt(), (j['p'] as num).toDouble());
}

class DrawingObject {
  final String id;
  final String symbol;
  final DrawingType type;
  final List<DrawingAnchor> anchors;
  final int colorArgb;

  const DrawingObject({
    required this.id,
    required this.symbol,
    required this.type,
    required this.anchors,
    required this.colorArgb,
  });

  DrawingObject copyWith({List<DrawingAnchor>? anchors, int? colorArgb}) => DrawingObject(
        id: id,
        symbol: symbol,
        type: type,
        anchors: anchors ?? this.anchors,
        colorArgb: colorArgb ?? this.colorArgb,
      );

  /// Copy with anchor [index] replaced (used by drag-to-move).
  DrawingObject withAnchor(int index, DrawingAnchor a) {
    if (index < 0 || index >= anchors.length) return this;
    final list = [...anchors];
    list[index] = a;
    return copyWith(anchors: list);
  }

  /// Short "type @ price" summary for the manage list.
  String summary(int digits) {
    switch (type) {
      case DrawingType.horizontalLine:
        return 'Horizontal @ ${anchors.first.price.toStringAsFixed(digits)}';
      case DrawingType.trendline:
        return 'Trend ${anchors.first.price.toStringAsFixed(digits)} → ${anchors.last.price.toStringAsFixed(digits)}';
      case DrawingType.fibRetracement:
        return 'Fib ${anchors.first.price.toStringAsFixed(digits)} → ${anchors.last.price.toStringAsFixed(digits)}';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'type': type.name,
        'anchors': anchors.map((a) => a.toJson()).toList(),
        'color': colorArgb,
      };

  factory DrawingObject.fromJson(Map<String, dynamic> j) => DrawingObject(
        id: j['id'] as String,
        symbol: j['symbol'] as String,
        type: DrawingType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => DrawingType.horizontalLine,
        ),
        anchors: (j['anchors'] as List)
            .map((e) => DrawingAnchor.fromJson(e as Map<String, dynamic>))
            .toList(),
        colorArgb: (j['color'] as num?)?.toInt() ?? 0xFFFFB74D,
      );
}
