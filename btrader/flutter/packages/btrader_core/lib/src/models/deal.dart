class Deal {
  final String id;
  final String type;
  final String? side;
  final double? volume;
  final double? price; // deal/close price
  final double profit;
  final double swap;
  final double commission;
  /// Commission debited when this deal's position was executed (from its OPEN deal), as the
  /// history endpoint reports it. Zero for positions opened before commission moved to execution.
  final double openCommission;
  final double balanceAfter;
  final String? comment;
  final DateTime createdAt;
  // Enriched by the history endpoint:
  final String? symbol; // null for balance ops
  final int digits;
  final double? openPrice; // entry price of the related position
  final double amount; // signed balance change (deposits +, withdrawals -)
  // Enriched (trade rows only) — the related position's protective levels and
  // when it was opened, plus its id shown as the MT5-style ticket.
  final double? slPrice;
  final double? tpPrice;
  final DateTime? openedAt;
  final String? positionId;
  final String? ticket;

  const Deal({
    required this.id,
    required this.type,
    this.side,
    this.volume,
    this.price,
    required this.profit,
    this.swap = 0,
    this.commission = 0,
    this.openCommission = 0,
    required this.balanceAfter,
    this.comment,
    required this.createdAt,
    this.symbol,
    this.digits = 5,
    this.openPrice,
    this.amount = 0,
    this.slPrice,
    this.tpPrice,
    this.openedAt,
    this.positionId,
    this.ticket,
  });

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;
  static double? _dn(dynamic v) => v == null ? null : double.tryParse(v.toString());

  /// True for closed-trade rows (have a symbol + realized P/L); false for
  /// balance operations (deposit / withdrawal / bonus / etc.).
  bool get isTrade => type == 'CLOSE' || type == 'PARTIAL_CLOSE';

  /// The deal written when a trade is executed. Its [commission] is what was debited from the
  /// balance at that moment (commission is charged at execution, not at close).
  bool get isOpenDeal => type == 'OPEN';

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
      openCommission: _d(j['openCommission']),
      balanceAfter: _d(j['balanceAfter']),
      comment: j['comment'],
      createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      symbol: sym is Map ? sym['symbol'] as String? : sym as String?,
      digits: (j['digits'] is num) ? (j['digits'] as num).toInt() : 5,
      openPrice: _dn(j['openPrice']),
      amount: _d(j['amount']),
      slPrice: _dn(j['slPrice']),
      tpPrice: _dn(j['tpPrice']),
      openedAt: j['openedAt'] == null ? null : DateTime.tryParse('${j['openedAt']}'),
      positionId: j['positionId'] as String?,
      ticket: j['ticket'] as String?,
    );
  }
}

/// Commission to show on a closed-trade row: what the CLOSE deal itself carries, plus the
/// execution-time commission once, on the position's final CLOSE (never on a partial close, so a
/// position closed in several steps still shows its commission exactly once).
double tradeRowCommission(Deal d) => d.type == 'CLOSE' ? d.commission + d.openCommission : d.commission;

/// Total commission an account has been charged across [deals]: every OPEN deal (charged at
/// execution, including for positions that are still open) plus whatever CLOSE / PARTIAL_CLOSE
/// deals carry (positions that were already open before charging moved to execution). Each amount
/// lives on exactly one deal, so nothing is counted twice.
double totalCommission(Iterable<Deal> deals) {
  var sum = 0.0;
  for (final d in deals) {
    if (d.isTrade || d.isOpenDeal) sum += d.commission;
  }
  return sum;
}
