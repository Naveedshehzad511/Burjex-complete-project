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

  /// Further fields the positions API already returns; null / 0 when absent.
  final double commission;
  final double marginUsed;
  final double? closePrice;
  final DateTime? closedAt;
  final String? comment;

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
    this.commission = 0,
    this.marginUsed = 0,
    this.closePrice,
    this.closedAt,
    this.comment,
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
      commission: _d(j['commission']),
      marginUsed: _d(j['marginUsed']),
      closePrice: _dn(j['closePrice']),
      closedAt: DateTime.tryParse('${j['closedAt'] ?? ''}'),
      comment: j['comment'] is String ? j['comment'] as String : null,
    );
  }

  /// The position the engine just CONFIRMED as opened, from the `opened` push on the socket
  /// (the engine sends the whole row with `opened: true`). Null for anything else — live P/L
  /// snapshots, closes and the id-only "stale" pings — so only a real confirmation ever
  /// produces a row.
  static Position? tryFromOpenedEvent(Map<String, dynamic> j) {
    if (j['opened'] != true) return null;
    final id = j['id'] ?? j['positionId'];
    final side = j['side'];
    final volume = _dn(j['volume']);
    final openPrice = _dn(j['openPrice']);
    final sym = j['symbol'];
    final symbol = sym is Map ? sym['symbol'] : sym;
    if (id == null || side == null || volume == null || openPrice == null || symbol == null || '$symbol'.isEmpty) {
      return null;
    }
    final digits = j['digits'] ?? (sym is Map ? sym['digits'] : null);
    return Position(
      id: '$id',
      accountId: '${j['accountId'] ?? ''}',
      side: '$side'.toUpperCase(),
      status: 'OPEN',
      volume: volume,
      openPrice: openPrice,
      slPrice: _dn(j['slPrice']),
      tpPrice: _dn(j['tpPrice']),
      profit: _d(j['profit']),
      swap: _d(j['swap']),
      symbol: '$symbol',
      digits: digits is int ? digits : int.tryParse('$digits') ?? 5,
      openedAt: DateTime.tryParse('${j['openedAt'] ?? ''}') ?? DateTime.now(),
      commission: _d(j['commission']),
      marginUsed: _d(j['marginUsed']),
    );
  }

  Position copyWith({double? profit}) => Position(
        id: id, accountId: accountId, accountLogin: accountLogin, side: side, status: status, volume: volume,
        openPrice: openPrice, slPrice: slPrice, tpPrice: tpPrice,
        profit: profit ?? this.profit, swap: swap, symbol: symbol, digits: digits, openedAt: openedAt,
        commission: commission, marginUsed: marginUsed, closePrice: closePrice, closedAt: closedAt, comment: comment,
      );
}
