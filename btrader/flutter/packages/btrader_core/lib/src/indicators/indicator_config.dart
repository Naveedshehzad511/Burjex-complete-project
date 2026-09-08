import 'engine.dart';

/// The indicator types the chart can draw. Overlays render on the price pane;
/// oscillators render in their own sub-pane with an independent scale.
enum IndicatorType { sma, ema, wma, bollinger, rsi, macd, stochastic, atr, cci, adx, psar, volume, ichimoku }

/// An editable numeric parameter of an indicator (period, multiplier, …).
class IndicatorParamField {
  final String key;
  final String label;
  final double min;
  final double max;
  final bool isInt;
  final double? step; // editor increment; defaults to 1 (int) or 0.1 (double)
  const IndicatorParamField(this.key, this.label,
      {this.min = 1, this.max = 500, this.isInt = true, this.step});
}

extension IndicatorTypeMeta on IndicatorType {
  String get displayName => switch (this) {
        IndicatorType.sma => 'Simple MA',
        IndicatorType.ema => 'Exponential MA',
        IndicatorType.wma => 'Weighted MA',
        IndicatorType.bollinger => 'Bollinger Bands',
        IndicatorType.rsi => 'RSI',
        IndicatorType.macd => 'MACD',
        IndicatorType.stochastic => 'Stochastic',
        IndicatorType.atr => 'ATR',
        IndicatorType.cci => 'CCI',
        IndicatorType.adx => 'ADX',
        IndicatorType.psar => 'Parabolic SAR',
        IndicatorType.volume => 'Volume',
        IndicatorType.ichimoku => 'Ichimoku Cloud',
      };

  String get shortName => switch (this) {
        IndicatorType.sma => 'SMA',
        IndicatorType.ema => 'EMA',
        IndicatorType.wma => 'WMA',
        IndicatorType.bollinger => 'BB',
        IndicatorType.rsi => 'RSI',
        IndicatorType.macd => 'MACD',
        IndicatorType.stochastic => 'Stoch',
        IndicatorType.atr => 'ATR',
        IndicatorType.cci => 'CCI',
        IndicatorType.adx => 'ADX',
        IndicatorType.psar => 'SAR',
        IndicatorType.volume => 'Vol',
        IndicatorType.ichimoku => 'Ichimoku',
      };

  /// True → drawn over the candles (shares the price scale).
  /// False → drawn in a separate oscillator pane below the chart.
  bool get isOverlay => switch (this) {
        IndicatorType.sma ||
        IndicatorType.ema ||
        IndicatorType.wma ||
        IndicatorType.bollinger ||
        IndicatorType.psar ||
        IndicatorType.ichimoku =>
          true,
        _ => false,
      };

  /// Whether the indicator is computed from a selectable price source. The
  /// OHLC-based indicators (ATR, Stochastic, CCI, ADX, PSAR, Volume) ignore it.
  bool get usesSource => switch (this) {
        IndicatorType.atr ||
        IndicatorType.stochastic ||
        IndicatorType.cci ||
        IndicatorType.adx ||
        IndicatorType.psar ||
        IndicatorType.volume ||
        IndicatorType.ichimoku =>
          false,
        _ => true,
      };

  List<IndicatorParamField> get paramFields => switch (this) {
        IndicatorType.sma ||
        IndicatorType.ema ||
        IndicatorType.wma ||
        IndicatorType.rsi ||
        IndicatorType.atr =>
          const [IndicatorParamField('period', 'Period')],
        IndicatorType.bollinger => const [
            IndicatorParamField('period', 'Period'),
            IndicatorParamField('mult', 'Std Dev', min: 0.1, max: 10, isInt: false),
          ],
        IndicatorType.macd => const [
            IndicatorParamField('fast', 'Fast'),
            IndicatorParamField('slow', 'Slow'),
            IndicatorParamField('signal', 'Signal'),
          ],
        IndicatorType.stochastic => const [
            IndicatorParamField('kPeriod', '%K Period'),
            IndicatorParamField('kSlow', '%K Slowing'),
            IndicatorParamField('dPeriod', '%D Period'),
          ],
        IndicatorType.cci || IndicatorType.adx => const [IndicatorParamField('period', 'Period')],
        IndicatorType.psar => const [
            IndicatorParamField('step', 'Step', min: 0.001, max: 1, isInt: false, step: 0.01),
            IndicatorParamField('max', 'Max Step', min: 0.01, max: 1, isInt: false, step: 0.02),
          ],
        IndicatorType.volume => const [],
        IndicatorType.ichimoku => const [
            IndicatorParamField('tenkan', 'Tenkan'),
            IndicatorParamField('kijun', 'Kijun'),
            IndicatorParamField('senkouB', 'Senkou B'),
            IndicatorParamField('displacement', 'Shift'),
          ],
      };

  Map<String, double> get defaultParams => switch (this) {
        IndicatorType.sma => {'period': 20},
        IndicatorType.ema => {'period': 20},
        IndicatorType.wma => {'period': 20},
        IndicatorType.bollinger => {'period': 20, 'mult': 2},
        IndicatorType.rsi => {'period': 14},
        IndicatorType.macd => {'fast': 12, 'slow': 26, 'signal': 9},
        IndicatorType.stochastic => {'kPeriod': 14, 'kSlow': 3, 'dPeriod': 3},
        IndicatorType.atr => {'period': 14},
        IndicatorType.cci => {'period': 20},
        IndicatorType.adx => {'period': 14},
        IndicatorType.psar => {'step': 0.02, 'max': 0.2},
        IndicatorType.volume => {},
        IndicatorType.ichimoku => {'tenkan': 9, 'kijun': 26, 'senkouB': 52, 'displacement': 26},
      };

  /// Human labels for each drawn line, in order (drives the color editor too).
  List<String> get lineLabels => switch (this) {
        IndicatorType.sma => const ['SMA'],
        IndicatorType.ema => const ['EMA'],
        IndicatorType.wma => const ['WMA'],
        IndicatorType.bollinger => const ['Upper', 'Basis', 'Lower'],
        IndicatorType.rsi => const ['RSI'],
        IndicatorType.macd => const ['MACD', 'Signal'],
        IndicatorType.stochastic => const ['%K', '%D'],
        IndicatorType.atr => const ['ATR'],
        IndicatorType.cci => const ['CCI'],
        IndicatorType.adx => const ['ADX', '+DI', '-DI'],
        IndicatorType.psar => const ['SAR'],
        IndicatorType.volume => const ['Volume'],
        IndicatorType.ichimoku => const ['Tenkan', 'Kijun', 'Senkou A', 'Senkou B', 'Chikou'],
      };

  /// Default line colors (ARGB), one per entry in [lineLabels].
  List<int> get defaultColors => switch (this) {
        IndicatorType.sma => const [0xFF2196F3],
        IndicatorType.ema => const [0xFFFF9800],
        IndicatorType.wma => const [0xFFAB47BC],
        IndicatorType.bollinger => const [0xFF42A5F5, 0xFF90A4AE, 0xFF42A5F5],
        IndicatorType.rsi => const [0xFF7E57C2],
        IndicatorType.macd => const [0xFF2196F3, 0xFFFF7043],
        IndicatorType.stochastic => const [0xFF2196F3, 0xFFFF7043],
        IndicatorType.atr => const [0xFF26A69A],
        IndicatorType.cci => const [0xFF26A69A],
        IndicatorType.adx => const [0xFFFFB74D, 0xFF42A5F5, 0xFFEF5350],
        IndicatorType.psar => const [0xFF26C6DA],
        IndicatorType.volume => const [0xFF78909C],
        IndicatorType.ichimoku => const [0xFF2196F3, 0xFFEF5350, 0xFF66BB6A, 0xFFEF9A9A, 0xFF9C7BF0],
      };
}

/// A configured indicator instance: type + parameters + colors + on/off. Held
/// in [chartIndicatorsProvider] and persisted to disk as JSON.
class IndicatorConfig {
  final String id;
  final IndicatorType type;
  final bool enabled;
  final IndicatorSource source;
  final Map<String, double> params;
  final List<int> colors; // ARGB, aligned to type.lineLabels

  const IndicatorConfig({
    required this.id,
    required this.type,
    this.enabled = true,
    this.source = IndicatorSource.close,
    required this.params,
    required this.colors,
  });

  /// A fresh config with the type's default params/colors.
  factory IndicatorConfig.defaults(IndicatorType type, String id) => IndicatorConfig(
        id: id,
        type: type,
        enabled: true,
        source: IndicatorSource.close,
        params: Map<String, double>.from(type.defaultParams),
        colors: List<int>.from(type.defaultColors),
      );

  int paramInt(String key) => (params[key] ?? type.defaultParams[key] ?? 0).round();
  double paramDouble(String key) => params[key] ?? type.defaultParams[key] ?? 0;

  IndicatorConfig copyWith({
    bool? enabled,
    IndicatorSource? source,
    Map<String, double>? params,
    List<int>? colors,
  }) =>
      IndicatorConfig(
        id: id,
        type: type,
        enabled: enabled ?? this.enabled,
        source: source ?? this.source,
        params: params ?? this.params,
        colors: colors ?? this.colors,
      );

  /// Short "type period" summary for the manage list, e.g. "EMA 20" or
  /// "MACD 12,26,9".
  String get summary {
    final ps = type.paramFields
        .map((f) => f.isInt ? paramInt(f.key).toString() : _fmt(paramDouble(f.key)))
        .join(',');
    return '${type.shortName} $ps';
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'enabled': enabled,
        'source': source.name,
        'params': params,
        'colors': colors,
      };

  factory IndicatorConfig.fromJson(Map<String, dynamic> j) {
    final type = IndicatorType.values.firstWhere(
      (t) => t.name == j['type'],
      orElse: () => IndicatorType.sma,
    );
    return IndicatorConfig(
      id: j['id'] as String,
      type: type,
      enabled: j['enabled'] as bool? ?? true,
      source: IndicatorSource.values.firstWhere(
        (s) => s.name == j['source'],
        orElse: () => IndicatorSource.close,
      ),
      params: (j['params'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toDouble())) ??
          Map<String, double>.from(type.defaultParams),
      colors: (j['colors'] as List?)?.map((e) => (e as num).toInt()).toList() ??
          List<int>.from(type.defaultColors),
    );
  }
}
