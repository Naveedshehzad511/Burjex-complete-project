class Position {
  final String id;
  final String accountId;
  final String? accountLogin; // trading account number (admin views); null on client views
  final String side; // BUY | SELL
  final String status;
  final double volume;
  final double openPrice;
  final double? slPrice;
  final double? tpPrice;
  final double profit;
  final double swap;
  final String symbol;
  final int digits;
  final DateTime openedAt;

  const Position({
    required this.id,
    required this.accountId,
    this.accountLogin,
    required this.side,
    required this.status,
    required this.volume,
    required this.openPrice,
    this.slPrice,
    this.tpPrice,
    required this.profit,
    required this.swap,
    required this.symbol,
    required this.digits,
    required this.openedAt,
  });

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;
  static double? _dn(dynamic v) => v == null ? null : double.tryParse(v.toString());

  factory Position.fromJson(Map<String, dynamic> j) {
    final sym = j['symbol'];
    final acct = j['account'];
    return Position(
      id: j['id'],
      accountId: j['accountId'] ?? '',
      accountLogin: acct is Map ? acct['login']?.toString() : j['accountLogin']?.toString(),
      side: j['side'],
      status: j['status'] ?? 'OPEN',
      volume: _d(j['volume']),
      openPrice: _d(j['openPrice']),
      slPrice: _dn(j['slPrice']),
      tpPrice: _dn(j['tpPrice']),
      profit: _d(j['profit']),
      swap: _d(j['swap']),
      symbol: sym is Map ? sym['symbol'] : (sym ?? '').toString(),
      digits: sym is Map ? (sym['digits'] ?? 5) as int : 5,
      openedAt: DateTime.tryParse(j['openedAt'] ?? '') ?? DateTime.now(),
    );
  }

  Position copyWith({double? profit}) => Position(
        id: id, accountId: accountId, accountLogin: accountLogin, side: side, status: status, volume: volume,
        openPrice: openPrice, slPrice: slPrice, tpPrice: tpPrice,
        profit: profit ?? this.profit, swap: swap, symbol: symbol, digits: digits, openedAt: openedAt,
      );
}
