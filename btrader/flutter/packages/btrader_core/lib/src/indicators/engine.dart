import 'dart:math' as math;

import '../models/candle.dart';

/// Pure-Dart technical-indicator math. No Flutter imports — unit-testable in
/// isolation and reusable across the trader and admin apps.
///
/// Every function returns a list aligned 1:1 with its input: index `i` in the
/// output corresponds to input bar `i`. Positions with insufficient look-back
/// (the warm-up period) are `null` so callers can skip them when drawing.
///
/// All of these are O(n) single-pass (or close to it): recomputing a handful of
/// indicators over ~500 candles on every live tick costs well under a
/// millisecond, so the chart just recomputes on each rebuild rather than
/// carrying incremental state.

/// The price field an indicator is computed from.
enum IndicatorSource { close, open, high, low, hl2, hlc3, ohlc4 }

extension IndicatorSourceApi on IndicatorSource {
  String get label => switch (this) {
        IndicatorSource.close => 'Close',
        IndicatorSource.open => 'Open',
        IndicatorSource.high => 'High',
        IndicatorSource.low => 'Low',
        IndicatorSource.hl2 => 'HL/2',
        IndicatorSource.hlc3 => 'HLC/3',
        IndicatorSource.ohlc4 => 'OHLC/4',
      };

  double of(Candle k) => switch (this) {
        IndicatorSource.close => k.c,
        IndicatorSource.open => k.o,
        IndicatorSource.high => k.h,
        IndicatorSource.low => k.l,
        IndicatorSource.hl2 => (k.h + k.l) / 2,
        IndicatorSource.hlc3 => (k.h + k.l + k.c) / 3,
        IndicatorSource.ohlc4 => (k.o + k.h + k.l + k.c) / 4,
      };
}

/// Project a candle list onto a single price series.
List<double> priceSeries(List<Candle> candles, IndicatorSource src) =>
    List<double>.generate(candles.length, (i) => src.of(candles[i]), growable: false);

/// Simple Moving Average.
List<double?> sma(List<double> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n < period) return out;
  double sum = 0;
  for (var i = 0; i < n; i++) {
    sum += src[i];
    if (i >= period) sum -= src[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

/// Exponential Moving Average, seeded with the SMA of the first `period` values
/// (standard convention, matches MT5/TradingView).
List<double?> ema(List<double> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n < period) return out;
  final k = 2 / (period + 1);
  double sum = 0;
  for (var i = 0; i < period; i++) {
    sum += src[i];
  }
  double prev = sum / period;
  out[period - 1] = prev;
  for (var i = period; i < n; i++) {
    prev = (src[i] - prev) * k + prev;
    out[i] = prev;
  }
  return out;
}

/// EMA over a possibly gappy series (leading `null`s from an upstream warm-up,
/// e.g. the MACD line). Seeds once `period` consecutive real values are seen.
List<double?> _emaNullable(List<double?> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0) return out;
  final k = 2 / (period + 1);
  double sum = 0;
  int count = 0;
  double? prev;
  for (var i = 0; i < n; i++) {
    final v = src[i];
    if (v == null) continue;
    if (prev == null) {
      sum += v;
      count++;
      if (count == period) {
        prev = sum / period;
        out[i] = prev;
      }
    } else {
      prev = (v - prev) * k + prev;
      out[i] = prev;
    }
  }
  return out;
}

/// Weighted Moving Average (linear weights 1..period, newest heaviest).
List<double?> wma(List<double> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n < period) return out;
  final denom = period * (period + 1) / 2;
  for (var i = period - 1; i < n; i++) {
    double acc = 0;
    for (var j = 0; j < period; j++) {
      acc += src[i - period + 1 + j] * (j + 1);
    }
    out[i] = acc / denom;
  }
  return out;
}

/// Bollinger Bands: middle SMA and ±`mult` population-standard-deviations.
({List<double?> upper, List<double?> middle, List<double?> lower}) bollinger(
    List<double> src, int period, double mult) {
  final n = src.length;
  final mid = sma(src, period);
  final upper = List<double?>.filled(n, null);
  final lower = List<double?>.filled(n, null);
  for (var i = period - 1; i < n; i++) {
    final m = mid[i];
    if (m == null) continue;
    double sq = 0;
    for (var j = i - period + 1; j <= i; j++) {
      final d = src[j] - m;
      sq += d * d;
    }
    final sd = math.sqrt(sq / period);
    upper[i] = m + mult * sd;
    lower[i] = m - mult * sd;
  }
  return (upper: upper, middle: mid, lower: lower);
}

/// Relative Strength Index (Wilder smoothing).
List<double?> rsi(List<double> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n <= period) return out;
  double gain = 0, loss = 0;
  for (var i = 1; i <= period; i++) {
    final ch = src[i] - src[i - 1];
    if (ch >= 0) {
      gain += ch;
    } else {
      loss -= ch;
    }
  }
  double avgGain = gain / period, avgLoss = loss / period;
  out[period] = _rsiFrom(avgGain, avgLoss);
  for (var i = period + 1; i < n; i++) {
    final ch = src[i] - src[i - 1];
    final g = ch > 0 ? ch : 0.0;
    final l = ch < 0 ? -ch : 0.0;
    avgGain = (avgGain * (period - 1) + g) / period;
    avgLoss = (avgLoss * (period - 1) + l) / period;
    out[i] = _rsiFrom(avgGain, avgLoss);
  }
  return out;
}

double _rsiFrom(double avgGain, double avgLoss) {
  if (avgLoss == 0) return 100;
  final rs = avgGain / avgLoss;
  return 100 - 100 / (1 + rs);
}

/// MACD: `macd` = EMA(fast) − EMA(slow); `signal` = EMA(macd, signalPeriod);
/// `hist` = macd − signal.
({List<double?> macd, List<double?> signal, List<double?> hist}) macd(
    List<double> src, int fast, int slow, int signalPeriod) {
  final n = src.length;
  final ef = ema(src, fast);
  final es = ema(src, slow);
  final line = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final a = ef[i], b = es[i];
    if (a != null && b != null) line[i] = a - b;
  }
  final sig = _emaNullable(line, signalPeriod);
  final hist = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final m = line[i], s = sig[i];
    if (m != null && s != null) hist[i] = m - s;
  }
  return (macd: line, signal: sig, hist: hist);
}

/// Stochastic oscillator. `k` is the slowed %K (SMA of raw %K over `kSlow`);
/// `d` is the SMA of %K over `dPeriod`. Raw %K uses a `kPeriod` look-back.
({List<double?> k, List<double?> d}) stochastic(
    List<Candle> candles, int kPeriod, int kSlow, int dPeriod) {
  final n = candles.length;
  final raw = List<double?>.filled(n, null);
  for (var i = kPeriod - 1; i < n; i++) {
    double hi = candles[i].h, lo = candles[i].l;
    for (var j = i - kPeriod + 1; j <= i; j++) {
      if (candles[j].h > hi) hi = candles[j].h;
      if (candles[j].l < lo) lo = candles[j].l;
    }
    final range = hi - lo;
    raw[i] = range == 0 ? 100.0 : (candles[i].c - lo) / range * 100;
  }
  final k = _smaNullable(raw, kSlow);
  final d = _smaNullable(k, dPeriod);
  return (k: k, d: d);
}

/// SMA over a gappy series, aligned to input; emits once a full window of
/// consecutive real values is available.
List<double?> _smaNullable(List<double?> src, int period) {
  final n = src.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0) return out;
  if (period == 1) return List<double?>.from(src);
  for (var i = period - 1; i < n; i++) {
    double sum = 0;
    var ok = true;
    for (var j = i - period + 1; j <= i; j++) {
      final v = src[j];
      if (v == null) {
        ok = false;
        break;
      }
      sum += v;
    }
    if (ok) out[i] = sum / period;
  }
  return out;
}

/// Average True Range (Wilder smoothing).
List<double?> atr(List<Candle> candles, int period) {
  final n = candles.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n <= period) return out;
  final tr = List<double>.filled(n, 0);
  tr[0] = candles[0].h - candles[0].l;
  for (var i = 1; i < n; i++) {
    final h = candles[i].h, l = candles[i].l, pc = candles[i - 1].c;
    tr[i] = math.max(h - l, math.max((h - pc).abs(), (l - pc).abs()));
  }
  double sum = 0;
  for (var i = 1; i <= period; i++) {
    sum += tr[i];
  }
  double prev = sum / period;
  out[period] = prev;
  for (var i = period + 1; i < n; i++) {
    prev = (prev * (period - 1) + tr[i]) / period;
    out[i] = prev;
  }
  return out;
}

/// Commodity Channel Index: (typicalPrice − SMA) / (0.015 × meanDeviation).
List<double?> cci(List<Candle> candles, int period) {
  final n = candles.length;
  final out = List<double?>.filled(n, null);
  if (period <= 0 || n < period) return out;
  final tp = List<double>.generate(n, (i) => (candles[i].h + candles[i].l + candles[i].c) / 3);
  for (var i = period - 1; i < n; i++) {
    double sum = 0;
    for (var j = i - period + 1; j <= i; j++) {
      sum += tp[j];
    }
    final ma = sum / period;
    double md = 0;
    for (var j = i - period + 1; j <= i; j++) {
      md += (tp[j] - ma).abs();
    }
    md /= period;
    out[i] = md == 0 ? 0 : (tp[i] - ma) / (0.015 * md);
  }
  return out;
}

/// Average Directional Index (Wilder). Returns the trend-strength `adx` plus the
/// directional indicators `plusDi` / `minusDi`.
({List<double?> adx, List<double?> plusDi, List<double?> minusDi}) adx(
    List<Candle> candles, int period) {
  final n = candles.length;
  final outAdx = List<double?>.filled(n, null);
  final outP = List<double?>.filled(n, null);
  final outM = List<double?>.filled(n, null);
  if (period <= 0 || n <= 2 * period) return (adx: outAdx, plusDi: outP, minusDi: outM);

  final tr = List<double>.filled(n, 0);
  final plusDm = List<double>.filled(n, 0);
  final minusDm = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    final up = candles[i].h - candles[i - 1].h;
    final down = candles[i - 1].l - candles[i].l;
    plusDm[i] = (up > down && up > 0) ? up : 0;
    minusDm[i] = (down > up && down > 0) ? down : 0;
    final h = candles[i].h, l = candles[i].l, pc = candles[i - 1].c;
    tr[i] = math.max(h - l, math.max((h - pc).abs(), (l - pc).abs()));
  }

  // Wilder-smoothed sums, seeded with the first `period` values.
  double trS = 0, pS = 0, mS = 0;
  for (var i = 1; i <= period; i++) {
    trS += tr[i];
    pS += plusDm[i];
    mS += minusDm[i];
  }
  final dx = List<double?>.filled(n, null);
  for (var i = period; i < n; i++) {
    if (i > period) {
      trS = trS - trS / period + tr[i];
      pS = pS - pS / period + plusDm[i];
      mS = mS - mS / period + minusDm[i];
    }
    final pdi = trS == 0 ? 0.0 : 100 * pS / trS;
    final mdi = trS == 0 ? 0.0 : 100 * mS / trS;
    outP[i] = pdi;
    outM[i] = mdi;
    final sum = pdi + mdi;
    dx[i] = sum == 0 ? 0.0 : 100 * (pdi - mdi).abs() / sum;
  }

  // ADX = Wilder average of DX, first value at index 2*period.
  double adxSum = 0;
  for (var i = period + 1; i <= 2 * period; i++) {
    adxSum += dx[i] ?? 0;
  }
  double prevAdx = adxSum / period;
  outAdx[2 * period] = prevAdx;
  for (var i = 2 * period + 1; i < n; i++) {
    prevAdx = (prevAdx * (period - 1) + (dx[i] ?? 0)) / period;
    outAdx[i] = prevAdx;
  }
  return (adx: outAdx, plusDi: outP, minusDi: outM);
}

/// Ichimoku Kinko Hyo. Returns the five component series aligned to the bar
/// they're *computed* at — the forward displacement of the Senkou spans and the
/// backward displacement of Chikou are applied at render time, not here.
({
  List<double?> tenkan,
  List<double?> kijun,
  List<double?> senkouA,
  List<double?> senkouB,
  List<double?> chikou,
}) ichimoku(List<Candle> candles, int tenkanP, int kijunP, int senkouBP) {
  final n = candles.length;
  double? midHL(int i, int period) {
    if (i < period - 1) return null;
    double hi = candles[i].h, lo = candles[i].l;
    for (var j = i - period + 1; j <= i; j++) {
      if (candles[j].h > hi) hi = candles[j].h;
      if (candles[j].l < lo) lo = candles[j].l;
    }
    return (hi + lo) / 2;
  }

  final tenkan = List<double?>.filled(n, null);
  final kijun = List<double?>.filled(n, null);
  final senkouA = List<double?>.filled(n, null);
  final senkouB = List<double?>.filled(n, null);
  final chikou = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    tenkan[i] = midHL(i, tenkanP);
    kijun[i] = midHL(i, kijunP);
    if (tenkan[i] != null && kijun[i] != null) senkouA[i] = (tenkan[i]! + kijun[i]!) / 2;
    senkouB[i] = midHL(i, senkouBP);
    chikou[i] = candles[i].c;
  }
  return (tenkan: tenkan, kijun: kijun, senkouA: senkouA, senkouB: senkouB, chikou: chikou);
}

/// Parabolic SAR (Wilder). Returns the stop-and-reverse dot for each bar.
List<double?> parabolicSar(List<Candle> candles, double step, double maxStep) {
  final n = candles.length;
  final out = List<double?>.filled(n, null);
  if (n < 2) return out;
  // Seed the trend from the first two bars.
  bool up = candles[1].c >= candles[0].c;
  double af = step;
  double ep = up ? candles[0].h : candles[0].l;
  double sar = up ? candles[0].l : candles[0].h;
  out[0] = sar;
  for (var i = 1; i < n; i++) {
    sar = sar + af * (ep - sar);
    final h = candles[i].h, l = candles[i].l;
    if (up) {
      // SAR can't rise above the prior two lows.
      sar = math.min(sar, candles[i - 1].l);
      if (i >= 2) sar = math.min(sar, candles[i - 2].l);
      if (h > ep) {
        ep = h;
        af = math.min(af + step, maxStep);
      }
      if (l < sar) {
        up = false;
        sar = ep;
        ep = l;
        af = step;
      }
    } else {
      sar = math.max(sar, candles[i - 1].h);
      if (i >= 2) sar = math.max(sar, candles[i - 2].h);
      if (l < ep) {
        ep = l;
        af = math.min(af + step, maxStep);
      }
      if (h > sar) {
        up = true;
        sar = ep;
        ep = h;
        af = step;
      }
    }
    out[i] = sar;
  }
  return out;
}
