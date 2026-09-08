import '../models/candle.dart';
import 'engine.dart';
import 'indicator_config.dart';

/// One drawable line of an indicator, aligned 1:1 with the candle list. When
/// [dots] is true it's rendered as discrete points (e.g. Parabolic SAR) instead
/// of a connected line.
class ComputedLine {
  final List<double?> values;
  final int colorArgb;
  final double width;
  final String label;
  final bool dots;

  /// Horizontal render offset in bars: +N plots the value N bars into the future
  /// (Ichimoku Senkou spans), −N N bars in the past (Chikou). 0 = at its own bar.
  final int shift;

  const ComputedLine(this.values, this.colorArgb,
      {this.width = 1.4, this.label = '', this.dots = false, this.shift = 0});
}

/// A fully evaluated indicator, ready to render. Overlays are painted on the
/// price pane; the rest go in an oscillator sub-pane described by [guides],
/// [fixedRange], [zeroLine] and [histogram].
class ComputedIndicator {
  final String id;
  final IndicatorType type;
  final bool isOverlay;
  final List<ComputedLine> lines;

  /// MACD histogram (bars), sign-colored by the painter. Null for others.
  final ComputedLine? histogram;

  /// Horizontal reference levels drawn inside an oscillator pane (e.g. RSI
  /// 30/70, Stochastic 20/80).
  final List<double> guides;

  /// Forces the oscillator pane's vertical range (e.g. 0..100 for RSI/Stoch).
  /// Null → the pane auto-scales to the visible data.
  final ({double lo, double hi})? fixedRange;

  /// Draw a zero baseline in the pane (MACD).
  final bool zeroLine;

  /// Volume pane: draw `lines[0]` as bars rising from zero, colored by each
  /// candle's up/down direction rather than by a fixed line color.
  final bool volumeBars;

  /// Ichimoku: fill the Kumo cloud between `lines[2]` (Senkou A) and `lines[3]`
  /// (Senkou B), and how many bars of future space the projection needs.
  final bool ichimokuCloud;
  final int futureShift;

  /// Display label for the oscillator pane header, e.g. "RSI 14".
  final String label;

  const ComputedIndicator({
    required this.id,
    required this.type,
    required this.isOverlay,
    required this.lines,
    this.histogram,
    this.guides = const [],
    this.fixedRange,
    this.zeroLine = false,
    this.volumeBars = false,
    this.ichimokuCloud = false,
    this.futureShift = 0,
    this.label = '',
  });

  ComputedIndicator withLabel(String l) => ComputedIndicator(
        id: id,
        type: type,
        isOverlay: isOverlay,
        lines: lines,
        histogram: histogram,
        guides: guides,
        fixedRange: fixedRange,
        zeroLine: zeroLine,
        volumeBars: volumeBars,
        ichimokuCloud: ichimokuCloud,
        futureShift: futureShift,
        label: l,
      );

  /// Every value across all lines (for auto-scaling an oscillator pane).
  Iterable<double> get allValues sync* {
    for (final ln in lines) {
      for (final v in ln.values) {
        if (v != null) yield v;
      }
    }
    if (histogram != null) {
      for (final v in histogram!.values) {
        if (v != null) yield v;
      }
    }
  }
}

/// Evaluate one [IndicatorConfig] against a candle series. Pure/Flutter-free:
/// colors stay as ARGB ints. Returns null for a config whose type isn't handled.
ComputedIndicator computeIndicator(IndicatorConfig cfg, List<Candle> candles) {
  final t = cfg.type;
  final colors = cfg.colors;
  int color(int i) => i < colors.length ? colors[i] : (t.defaultColors.isNotEmpty ? t.defaultColors[i % t.defaultColors.length] : 0xFF2196F3);
  final labels = t.lineLabels;
  String lbl(int i) => i < labels.length ? labels[i] : '';

  List<double> src() => priceSeries(candles, cfg.source);

  switch (t) {
    case IndicatorType.sma:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [ComputedLine(sma(src(), cfg.paramInt('period')), color(0), width: 1.6, label: lbl(0))],
      );
    case IndicatorType.ema:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [ComputedLine(ema(src(), cfg.paramInt('period')), color(0), width: 1.6, label: lbl(0))],
      );
    case IndicatorType.wma:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [ComputedLine(wma(src(), cfg.paramInt('period')), color(0), width: 1.6, label: lbl(0))],
      );
    case IndicatorType.bollinger:
      final bb = bollinger(src(), cfg.paramInt('period'), cfg.paramDouble('mult'));
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [
          ComputedLine(bb.upper, color(0), width: 1.3, label: lbl(0)),
          ComputedLine(bb.middle, color(1), width: 1.2, label: lbl(1)),
          ComputedLine(bb.lower, color(2), width: 1.3, label: lbl(2)),
        ],
      );
    case IndicatorType.rsi:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [ComputedLine(rsi(src(), cfg.paramInt('period')), color(0), width: 1.4, label: lbl(0))],
        guides: const [30, 70],
        fixedRange: (lo: 0, hi: 100),
      );
    case IndicatorType.macd:
      final m = macd(src(), cfg.paramInt('fast'), cfg.paramInt('slow'), cfg.paramInt('signal'));
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [
          ComputedLine(m.macd, color(0), width: 1.4, label: lbl(0)),
          ComputedLine(m.signal, color(1), width: 1.4, label: lbl(1)),
        ],
        histogram: ComputedLine(m.hist, color(0), label: 'Hist'),
        zeroLine: true,
      );
    case IndicatorType.stochastic:
      final s = stochastic(candles, cfg.paramInt('kPeriod'), cfg.paramInt('kSlow'), cfg.paramInt('dPeriod'));
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [
          ComputedLine(s.k, color(0), width: 1.4, label: lbl(0)),
          ComputedLine(s.d, color(1), width: 1.4, label: lbl(1)),
        ],
        guides: const [20, 80],
        fixedRange: (lo: 0, hi: 100),
      );
    case IndicatorType.atr:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [ComputedLine(atr(candles, cfg.paramInt('period')), color(0), width: 1.4, label: lbl(0))],
      );
    case IndicatorType.cci:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [ComputedLine(cci(candles, cfg.paramInt('period')), color(0), width: 1.4, label: lbl(0))],
        guides: const [-100, 100],
        zeroLine: true,
      );
    case IndicatorType.adx:
      final a = adx(candles, cfg.paramInt('period'));
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [
          ComputedLine(a.adx, color(0), width: 1.6, label: lbl(0)),
          ComputedLine(a.plusDi, color(1), width: 1.2, label: lbl(1)),
          ComputedLine(a.minusDi, color(2), width: 1.2, label: lbl(2)),
        ],
        guides: const [25],
        fixedRange: (lo: 0, hi: 100),
      );
    case IndicatorType.psar:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [ComputedLine(parabolicSar(candles, cfg.paramDouble('step'), cfg.paramDouble('max')), color(0), width: 2.4, label: lbl(0), dots: true)],
      );
    case IndicatorType.volume:
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: false,
        lines: [ComputedLine([for (final k in candles) k.v], color(0), label: lbl(0))],
        volumeBars: true,
      );
    case IndicatorType.ichimoku:
      final ich = ichimoku(candles, cfg.paramInt('tenkan'), cfg.paramInt('kijun'), cfg.paramInt('senkouB'));
      final disp = cfg.paramInt('displacement');
      return ComputedIndicator(
        id: cfg.id,
        type: t,
        isOverlay: true,
        lines: [
          ComputedLine(ich.tenkan, color(0), width: 1.3, label: lbl(0)),
          ComputedLine(ich.kijun, color(1), width: 1.3, label: lbl(1)),
          ComputedLine(ich.senkouA, color(2), width: 1.0, label: lbl(2), shift: disp),
          ComputedLine(ich.senkouB, color(3), width: 1.0, label: lbl(3), shift: disp),
          ComputedLine(ich.chikou, color(4), width: 1.2, label: lbl(4), shift: -disp),
        ],
        ichimokuCloud: true,
        futureShift: disp,
      );
  }
}
