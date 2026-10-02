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

  /// Admin-configured trading-session windows (day/open/close, UTC). Empty
  /// means "no explicit schedule" — [isSymbolTradableNow] then falls back to
  /// always-open for crypto and the standard forex week for everything else,
  /// mirroring the trading engine's own `is_symbol_tradable` exactly so the
  /// portal's BUY/SELL enablement never disagrees with what the engine will
  /// actually accept or reject.
  final List<TradingSessionWindow> tradingSessions;

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
    this.tradingSessions = const [],
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
      tradingSessions: TradingSessionWindow.listFromJson(j['tradingSessions']),
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

/// One admin-configured trading-session window: [day] is 0=Sunday..6=Saturday
/// (UTC), [open]/[close] are "HH:MM" (UTC). Mirrors the engine's
/// `SessionWindow` (trading-core-rs/src/sessions.rs) field-for-field.
class TradingSessionWindow {
  const TradingSessionWindow({required this.day, required this.open, required this.close});
  final int day;
  final String open;
  final String close;

  static List<TradingSessionWindow> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <TradingSessionWindow>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final day = e['day'];
      final open = e['open'];
      final close = e['close'];
      if (day is! num || open == null || close == null) continue;
      out.add(TradingSessionWindow(day: day.toInt(), open: '$open', close: '$close'));
    }
    return out;
  }
}

int _minutesOfDay(String hhmm) {
  final parts = hhmm.split(':');
  final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  return h * 60 + m;
}

bool _isMarketOpen(List<TradingSessionWindow> sessions, DateTime utcNow) {
  if (sessions.isEmpty) return true;
  final day = utcNow.weekday % 7; // DateTime: Mon=1..Sun=7 → Sun=0..Sat=6
  final mins = utcNow.hour * 60 + utcNow.minute;
  for (final s in sessions) {
    if (s.day != day) continue;
    final open = _minutesOfDay(s.open);
    final close = _minutesOfDay(s.close);
    if (open <= close) {
      if (mins >= open && mins < close) return true;
    } else if (mins >= open || mins < close) {
      return true; // overnight window (e.g. 22:00 → 06:00)
    }
  }
  return false;
}

bool _isForexWeekOpen(DateTime utcNow) {
  final day = utcNow.weekday % 7;
  final mins = utcNow.hour * 60 + utcNow.minute;
  const roll = 21 * 60; // 21:00 UTC, the standard FX week open/close roll
  if (day == 6) return false; // Saturday: always closed
  if (day == 0 && mins < roll) return false; // Sunday before the week opens
  if (day == 5 && mins >= roll) return false; // Friday after the week closes
  return true;
}

/// Whether [symbol] is tradable right now, evaluated against [utcNow] (pass
/// the actual current UTC time — never a cached/stale value, so this reflects
/// the live session boundary the moment it is crossed, no refetch needed).
///
/// Precedence — identical to the trading engine's `is_symbol_tradable`:
///  1. Explicit session windows, if the admin configured any.
///  2. Otherwise: CRYPTO trades round the clock.
///  3. Otherwise: the standard forex week (closed all Saturday, plus the
///     Friday/Sunday 21:00 UTC roll).
bool isSymbolTradableNow(TradeSymbol symbol, DateTime utcNow) {
  if (symbol.tradingSessions.isNotEmpty) {
    return _isMarketOpen(symbol.tradingSessions, utcNow);
  }
  if (symbol.klass.toUpperCase() == 'CRYPTO') return true;
  return _isForexWeekOpen(utcNow);
}
