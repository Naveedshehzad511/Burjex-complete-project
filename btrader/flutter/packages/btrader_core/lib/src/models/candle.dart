/// OHLC candle (open time in epoch seconds), as returned by /v1/market/candles.
class Candle {
  final int t;
  final double o;
  final double h;
  final double l;
  final double c;
  final double v;

  const Candle({required this.t, required this.o, required this.h, required this.l, required this.c, required this.v});

  static double _d(dynamic x) => x == null ? 0 : (x as num).toDouble();

  factory Candle.fromJson(Map<String, dynamic> j) =>
      Candle(t: (j['t'] as num).toInt(), o: _d(j['o']), h: _d(j['h']), l: _d(j['l']), c: _d(j['c']), v: _d(j['v']));

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(t * 1000);

  Candle copyWith({double? h, double? l, double? c, double? v}) =>
      Candle(t: t, o: o, h: h ?? this.h, l: l ?? this.l, c: c ?? this.c, v: v ?? this.v);
}

enum Timeframe { m1, m5, m15, m30, h1, h4, d1, w1, mn1 }

extension TimeframeApi on Timeframe {
  String get api => switch (this) {
        Timeframe.m1 => '1m',
        Timeframe.m5 => '5m',
        Timeframe.m15 => '15m',
        Timeframe.m30 => '30m',
        Timeframe.h1 => '1h',
        Timeframe.h4 => '4h',
        Timeframe.d1 => '1d',
        Timeframe.w1 => '1w',
        Timeframe.mn1 => '1mn',
      };
  String get label => switch (this) {
        Timeframe.m1 => '1m',
        Timeframe.m5 => '5m',
        Timeframe.m15 => '15m',
        Timeframe.m30 => '30m',
        Timeframe.h1 => '1H',
        Timeframe.h4 => '4H',
        Timeframe.d1 => '1D',
        Timeframe.w1 => '1W',
        Timeframe.mn1 => 'MN',
      };
  /// MT5 naming, for the chart's timeframe strip (M1 … MN). [label] is unchanged.
  String get mt5Label => switch (this) {
        Timeframe.m1 => 'M1',
        Timeframe.m5 => 'M5',
        Timeframe.m15 => 'M15',
        Timeframe.m30 => 'M30',
        Timeframe.h1 => 'H1',
        Timeframe.h4 => 'H4',
        Timeframe.d1 => 'D1',
        Timeframe.w1 => 'W1',
        Timeframe.mn1 => 'MN',
      };
  /// Nominal bar length. W1/MN1 use approximate values (their real boundaries
  /// are calendar-based — see [bucketStart]/[nextBucketStart]).
  int get seconds => switch (this) {
        Timeframe.m1 => 60,
        Timeframe.m5 => 300,
        Timeframe.m15 => 900,
        Timeframe.m30 => 1800,
        Timeframe.h1 => 3600,
        Timeframe.h4 => 14400,
        Timeframe.d1 => 86400,
        Timeframe.w1 => 604800,
        Timeframe.mn1 => 2629800,
      };

  /// Open time (epoch seconds) of the bar containing [t]. Intraday bars align to a fixed UTC grid;
  /// W1 aligns to Monday 00:00 UTC and MN1 to the 1st of the month 00:00 UTC, matching the
  /// gateway's server-side aggregation.
  ///
  /// H4 and D1 follow the BROKER's clock ([brokerOffsetSec], from `/market/clock`): the history
  /// rollup, the MT5 bridge and the live candle engine all put their H4 / D1 boundaries on the
  /// broker's grid, so the forming bar here must too, or it would overlap the bar beside it.
  int bucketStart(int t, {int brokerOffsetSec = 0}) {
    switch (this) {
      case Timeframe.w1:
        final d = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
        final monday = DateTime.utc(d.year, d.month, d.day - (d.weekday - 1));
        return monday.millisecondsSinceEpoch ~/ 1000;
      case Timeframe.mn1:
        final d = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
        return DateTime.utc(d.year, d.month).millisecondsSinceEpoch ~/ 1000;
      case Timeframe.h4:
      case Timeframe.d1:
        if (brokerOffsetSec != 0) return ((t + brokerOffsetSec) ~/ seconds) * seconds - brokerOffsetSec;
        return (t ~/ seconds) * seconds;
      default:
        return (t ~/ seconds) * seconds;
    }
  }

  /// Open time of the bar immediately after the one containing [t].
  int nextBucketStart(int t, {int brokerOffsetSec = 0}) {
    switch (this) {
      case Timeframe.w1:
        return bucketStart(t) + 604800;
      case Timeframe.mn1:
        final d = DateTime.fromMillisecondsSinceEpoch(bucketStart(t) * 1000, isUtc: true);
        final next = d.month == 12 ? DateTime.utc(d.year + 1) : DateTime.utc(d.year, d.month + 1);
        return next.millisecondsSinceEpoch ~/ 1000;
      default:
        return bucketStart(t, brokerOffsetSec: brokerOffsetSec) + seconds;
    }
  }
}
