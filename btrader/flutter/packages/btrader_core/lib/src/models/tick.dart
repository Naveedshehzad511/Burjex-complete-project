class Tick {
  final String symbol;
  final double bid;
  final double ask;
  final int ts;
  const Tick({required this.symbol, required this.bid, required this.ask, required this.ts});

  factory Tick.fromJson(Map<String, dynamic> j) => Tick(
        symbol: j['symbol'],
        bid: (j['bid'] as num).toDouble(),
        ask: (j['ask'] as num).toDouble(),
        ts: (j['ts'] ?? 0) as int,
      );
}
