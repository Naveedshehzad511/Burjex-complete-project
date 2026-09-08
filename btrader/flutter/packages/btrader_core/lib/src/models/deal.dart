class Deal {
  final String id;
  final String type;
  final String? side;
  final double? volume;
  final double? price; // deal/close price
  final double profit;
  final double swap;
  final double commission;
  final double balanceAfter;
  final String? comment;
  final DateTime createdAt;
  // Enriched by the history endpoint:
  final String? symbol; // null for balance ops
  final int digits;
  final double? openPrice; // entry price of the related position
  final double amount; // signed balance change (deposits +, withdrawals -)

  const Deal({
    required this.id,
    required this.type,
    this.side,
    this.volume,
    this.price,
    required this.profit,
    this.swap = 0,
    this.commission = 0,
    required this.balanceAfter,
    this.comment,
    required this.createdAt,
    this.symbol,
    this.digits = 5,
    this.openPrice,
    this.amount = 0,
  });

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;
  static double? _dn(dynamic v) => v == null ? null : double.tryParse(v.toString());

  /// True for closed-trade rows (have a symbol + realized P/L); false for
  /// balance operations (deposit / withdrawal / bonus / etc.).
  bool get isTrade => type == 'CLOSE' || type == 'PARTIAL_CLOSE';

  factory Deal.fromJson(Map<String, dynamic> j) {
    final sym = j['symbol'];
    return Deal(
      id: j['id'],
      type: j['type'],
      side: j['side'],
      volume: _dn(j['volume']),
      price: _dn(j['price']),
      profit: _d(j['profit']),
      swap: _d(j['swap']),
      commission: _d(j['commission']),
      balanceAfter: _d(j['balanceAfter']),
      comment: j['comment'],
      createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      symbol: sym is Map ? sym['symbol'] as String? : sym as String?,
      digits: (j['digits'] is num) ? (j['digits'] as num).toInt() : 5,
      openPrice: _dn(j['openPrice']),
      amount: _d(j['amount']),
    );
  }
}
