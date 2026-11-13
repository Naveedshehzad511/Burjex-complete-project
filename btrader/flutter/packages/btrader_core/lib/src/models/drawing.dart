/// User-drawn chart objects (lines, ray, arrow, rectangle, ellipse, Fibonacci).
/// Anchors are stored in chart space — (time, price) — not pixels, so a drawing
/// stays pinned to the same bars/levels through pan, zoom and timeframe changes.

enum DrawingType { horizontalLine, trendline, fibRetracement, verticalLine, ray, arrow, rectangle, ellipse }

extension DrawingTypeMeta on DrawingType {
  String get label => switch (this) {
        DrawingType.horizontalLine => 'Horizontal line',
        DrawingType.trendline => 'Trend line',
        DrawingType.fibRetracement => 'Fib retracement',
        DrawingType.verticalLine => 'Vertical line',
        DrawingType.ray => 'Ray',
        DrawingType.arrow => 'Arrow',
        DrawingType.rectangle => 'Rectangle',
        DrawingType.ellipse => 'Ellipse',
      };

  String get shortLabel => switch (this) {
        DrawingType.horizontalLine => 'H-Line',
        DrawingType.trendline => 'Trend',
        DrawingType.fibRetracement => 'Fib',
        DrawingType.verticalLine => 'V-Line',
        DrawingType.ray => 'Ray',
        DrawingType.arrow => 'Arrow',
        DrawingType.rectangle => 'Rect',
        DrawingType.ellipse => 'Ellipse',
      };

  /// Number of taps needed to define the object.
  int get anchorCount => (this == DrawingType.horizontalLine || this == DrawingType.verticalLine) ? 1 : 2;

  int get defaultColor => switch (this) {
        DrawingType.horizontalLine => 0xFFFFB74D,
        DrawingType.trendline => 0xFF42A5F5,
        DrawingType.fibRetracement => 0xFF26A69A,
        DrawingType.verticalLine => 0xFFFFB74D,
        DrawingType.ray => 0xFF42A5F5,
        DrawingType.arrow => 0xFFEF5350,
        DrawingType.rectangle => 0xFFAB47BC,
        DrawingType.ellipse => 0xFF26C6DA,
      };
}

/// MT5 line styles for a drawing: solid, dashed, dotted.
enum DrawingLineStyle { solid, dashed, dotted }

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

  /// MT5 object properties. Older saved drawings have none of these and get the old look
  /// (solid, width 1, filled box, all timeframes, drawn over the candles).
  final DrawingLineStyle lineStyle;
  final int width; // 1..5
  final bool fill; // rectangle / ellipse only
  final bool background; // drawn under the candles
  final String? name; // user name; null = [displayName] default
  final Set<String>? timeframes; // Timeframe names it shows on; null = all

  const DrawingObject({
    required this.id,
    required this.symbol,
    required this.type,
    required this.anchors,
    required this.colorArgb,
    this.lineStyle = DrawingLineStyle.solid,
    this.width = 1,
    this.fill = true,
    this.background = false,
    this.name,
    this.timeframes,
  });

  bool get supportsFill => type == DrawingType.rectangle || type == DrawingType.ellipse;

  /// MT5-style object name, e.g. "Rectangle 51738" (number taken from the unique id).
  String get displayName {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    final digits = id.replaceAll(RegExp(r'[^0-9]'), '');
    final tail = digits.length > 5 ? digits.substring(digits.length - 5) : digits;
    return tail.isEmpty ? type.label : '${type.label} $tail';
  }

  /// Shown on the chart's timeframe [tfName] (a `Timeframe.name`)?
  bool visibleOn(String tfName) => timeframes == null || timeframes!.contains(tfName);

  DrawingObject copyWith({
    String? id,
    List<DrawingAnchor>? anchors,
    int? colorArgb,
    DrawingLineStyle? lineStyle,
    int? width,
    bool? fill,
    bool? background,
    String? name,
    Set<String>? timeframes,
    bool allTimeframes = false,
  }) =>
      DrawingObject(
        id: id ?? this.id,
        symbol: symbol,
        type: type,
        anchors: anchors ?? this.anchors,
        colorArgb: colorArgb ?? this.colorArgb,
        lineStyle: lineStyle ?? this.lineStyle,
        width: width ?? this.width,
        fill: fill ?? this.fill,
        background: background ?? this.background,
        name: name ?? this.name,
        timeframes: allTimeframes ? null : (timeframes ?? this.timeframes),
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
      case DrawingType.verticalLine:
        return 'Vertical line';
      case DrawingType.ray:
      case DrawingType.arrow:
      case DrawingType.rectangle:
      case DrawingType.ellipse:
        return '${type.label} ${anchors.first.price.toStringAsFixed(digits)} → ${anchors.last.price.toStringAsFixed(digits)}';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'type': type.name,
        'anchors': anchors.map((a) => a.toJson()).toList(),
        'color': colorArgb,
        'style': lineStyle.name,
        'width': width,
        'fill': fill,
        'bg': background,
        if (name != null) 'name': name,
        if (timeframes != null) 'tfs': timeframes!.toList(),
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
        lineStyle: DrawingLineStyle.values.firstWhere((s) => s.name == j['style'], orElse: () => DrawingLineStyle.solid),
        width: ((j['width'] as num?)?.toInt() ?? 1).clamp(1, 5),
        fill: j['fill'] as bool? ?? true,
        background: j['bg'] as bool? ?? false,
        name: j['name'] as String?,
        timeframes: (j['tfs'] as List?)?.map((e) => e as String).toSet(),
      );
}
