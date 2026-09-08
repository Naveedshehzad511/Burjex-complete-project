class Account {
  final String id;
  final String login;
  final String type;
  final String status;
  final String currency;
  final int leverage;
  final double balance;
  final double credit;
  final double equity;
  final double margin;
  final double freeMargin;
  final double marginLevel;
  final double floatingPL;
  /// 'A' | 'B' | null (null = inherit group default book).
  final String? book;

  /// Client-facing symbol suffix from this account's group (e.g. ".s"). Display
  /// only — all data (quotes, orders, candles) uses the canonical symbol name.
  final String? symbolSuffix;

  /// Account holder's display name and trading-group name (from /accounts/me).
  final String? ownerName;
  final String? groupName;

  /// True for a virtual (paper-trading) account — B-book only, real prices.
  final bool isDemo;

  const Account({
    required this.id,
    required this.login,
    required this.type,
    required this.status,
    required this.currency,
    required this.leverage,
    required this.balance,
    required this.credit,
    required this.equity,
    required this.margin,
    required this.freeMargin,
    required this.marginLevel,
    required this.floatingPL,
    this.book,
    this.symbolSuffix,
    this.ownerName,
    this.groupName,
    this.isDemo = false,
  });

  /// Append this account's group suffix to a canonical symbol for display.
  String display(String canonicalSymbol) =>
      (symbolSuffix == null || symbolSuffix!.isEmpty) ? canonicalSymbol : '$canonicalSymbol$symbolSuffix';

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'],
        login: j['login']?.toString() ?? '',
        type: j['type'] ?? 'STANDARD',
        status: j['status'] ?? 'ACTIVE',
        currency: j['currency'] ?? 'USD',
        leverage: (j['leverage'] ?? 100) as int,
        balance: _d(j['balance']),
        credit: _d(j['credit']),
        equity: _d(j['equity']),
        margin: _d(j['margin']),
        freeMargin: _d(j['freeMargin']),
        marginLevel: _d(j['marginLevel']),
        floatingPL: _d(j['floatingPL']),
        book: j['book'] as String?,
        symbolSuffix: j['symbolSuffix'] as String?,
        ownerName: j['ownerName'] as String?,
        groupName: j['groupName'] as String?,
        isDemo: j['isDemo'] == true,
      );

  /// Apply a live snapshot pushed over the WebSocket.
  Account withSnapshot(Map<String, dynamic> s) => Account(
        id: id, login: login, type: type, status: status, currency: currency, leverage: leverage,
        balance: _d(s['balance']), credit: _d(s['credit']), equity: _d(s['equity']),
        margin: _d(s['margin']), freeMargin: _d(s['freeMargin']),
        marginLevel: _d(s['marginLevel']), floatingPL: _d(s['floatingPL']), book: book,
        symbolSuffix: symbolSuffix,
        ownerName: ownerName,
        groupName: groupName,
        isDemo: isDemo,
      );

  // Equity is definitionally balance + credit + floating P/L. The stored
  // `equity` field is just a cache the engine refreshes on trade activity, so
  // for display we derive it — this shows the correct equity even at rest
  // (no open positions), before the engine has recomputed.
  double get liveEquity => balance + credit + floatingPL;
  double get liveFreeMargin => liveEquity - margin;
  double get liveMarginLevel => margin > 0 ? liveEquity / margin * 100 : 0;
}
