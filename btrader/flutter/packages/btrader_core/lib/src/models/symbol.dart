import 'tick.dart';

class TradeSymbol {
  final String id;
  final String symbol;
  /// Client-facing name for this account's group (e.g. XAUUSD.p). Falls back to [symbol].
  final String displaySymbol;
  final String? description;
  final String klass;
  final int digits;
  final double minLot;
  final double maxLot;
  final double lotStep;
  final double contractSize;
  /// Extra spread points from the account's trading group (legacy fixed markup).
  final int markupPoints;
  /// Symbol Mapping pricing method, if configured for this group.
  final String? pricingMethod;
  /// Total client spread floor (points). 0 = unused.
  final int minSpreadPoints;
  /// Total client spread cap (points). 0 = no cap.
  final int maxSpreadPoints;
  final bool enabled;

  const TradeSymbol({
    required this.id,
    required this.symbol,
    required this.displaySymbol,
    this.description,
    required this.klass,
    required this.digits,
    required this.minLot,
    required this.maxLot,
    required this.lotStep,
    required this.contractSize,
    this.markupPoints = 0,
    this.pricingMethod,
    this.minSpreadPoints = 0,
    this.maxSpreadPoints = 0,
    required this.enabled,
  });

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

  factory TradeSymbol.fromJson(Map<String, dynamic> j) {
    final klass = (j['class'] ?? 'FOREX').toString();
    final defaultCs = klass.toUpperCase() == 'FOREX' ? 100000.0 : 1.0;
    final symbol = (j['symbol'] ?? '').toString();
    return TradeSymbol(
      id: j['id'],
      symbol: symbol,
      displaySymbol: (j['displaySymbol'] ?? j['clientSymbol'] ?? symbol).toString(),
      description: j['description'],
      klass: klass,
      digits: (j['digits'] ?? 5) as int,
      minLot: _d(j['minLot'] ?? 0.01),
      maxLot: _d(j['maxLot'] ?? 100),
      lotStep: _d(j['lotStep'] ?? 0.01),
      contractSize: _d(j['contractSize'] ?? defaultCs).clamp(0.0001, double.infinity),
      markupPoints: (j['markupPoints'] is num)
          ? (j['markupPoints'] as num).round()
          : int.tryParse('${j['markupPoints'] ?? 0}') ?? 0,
      pricingMethod: j['pricingMethod']?.toString(),
      minSpreadPoints: (j['minSpreadPoints'] is num)
          ? (j['minSpreadPoints'] as num).round()
          : int.tryParse('${j['minSpreadPoints'] ?? 0}') ?? 0,
      maxSpreadPoints: (j['maxSpreadPoints'] is num)
          ? (j['maxSpreadPoints'] as num).round()
          : int.tryParse('${j['maxSpreadPoints'] ?? 0}') ?? 0,
      enabled: j['enabled'] ?? true,
    );
  }

  /// Apply this group's Symbol Mapping / markup to an LP tick.
  ///
  /// COMMISSION_ONLY → raw LP quote.
  /// SPREAD_ONLY / SPREAD_AND_COMMISSION with min/max → clamp total spread into
  /// the band (both sides move so mid stays put).
  /// Legacy fixed [markupPoints] when no band is configured.
  Tick applyGroupMarkup(Tick raw) {
    if (pricingMethod == 'COMMISSION_ONLY') return raw;

    final point = _pointSize(digits);
    if (point <= 0) return raw;

    final lpSpreadPts = (raw.ask - raw.bid) / point;
    final hasBand = minSpreadPoints > 0 || maxSpreadPoints > 0;

    if (hasBand) {
      var target = lpSpreadPts;
      if (minSpreadPoints > 0 && target < minSpreadPoints) {
        target = minSpreadPoints.toDouble();
      }
      if (maxSpreadPoints > 0 && target > maxSpreadPoints) {
        target = maxSpreadPoints.toDouble();
      }
      final halfExtra = (target - lpSpreadPts) / 2.0;
      final delta = halfExtra * point;
      if (delta == 0) return raw;
      return Tick(
        symbol: raw.symbol,
        bid: raw.bid - delta,
        ask: raw.ask + delta,
        ts: raw.ts,
      );
    }

    if (markupPoints == 0) return raw;
    final delta = markupPoints * point;
    return Tick(
      symbol: raw.symbol,
      bid: raw.bid - delta,
      ask: raw.ask + delta,
      ts: raw.ts,
    );
  }

  static double _pointSize(int digits) {
    var p = 1.0;
    for (var i = 0; i < digits; i++) {
      p /= 10;
    }
    return p;
  }
}
