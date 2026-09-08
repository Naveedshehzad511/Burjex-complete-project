import 'dart:math';

/// All order types supported by the engine.
enum OrderType { market, limit, stop, stopLimit, buyStop, sellStop, buyLimit, sellLimit }

extension OrderTypeApi on OrderType {
  String get api => switch (this) {
        OrderType.market => 'MARKET',
        OrderType.limit => 'LIMIT',
        OrderType.stop => 'STOP',
        OrderType.stopLimit => 'STOP_LIMIT',
        OrderType.buyStop => 'BUY_STOP',
        OrderType.sellStop => 'SELL_STOP',
        OrderType.buyLimit => 'BUY_LIMIT',
        OrderType.sellLimit => 'SELL_LIMIT',
      };
  String get label => switch (this) {
        OrderType.market => 'Market',
        OrderType.limit => 'Limit',
        OrderType.stop => 'Stop',
        OrderType.stopLimit => 'Stop Limit',
        OrderType.buyStop => 'Buy Stop',
        OrderType.sellStop => 'Sell Stop',
        OrderType.buyLimit => 'Buy Limit',
        OrderType.sellLimit => 'Sell Limit',
      };
}

class PlaceOrderRequest {
  final String accountId;
  final String symbol;
  final String side; // BUY | SELL
  final OrderType type;
  final double volume;
  final double? price;
  final double? stopPrice;
  final double? slPrice;
  final double? tpPrice;
  final bool oneClick;
  /// Idempotency key. Generated if omitted so a double-tap cannot open two trades.
  final String? clientOrderId;

  const PlaceOrderRequest({
    required this.accountId,
    required this.symbol,
    required this.side,
    required this.type,
    required this.volume,
    this.price,
    this.stopPrice,
    this.slPrice,
    this.tpPrice,
    this.oneClick = false,
    this.clientOrderId,
  });

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'symbol': symbol,
        'side': side,
        'type': type.api,
        'volume': volume,
        if (price != null) 'price': price,
        if (stopPrice != null) 'stopPrice': stopPrice,
        if (slPrice != null) 'slPrice': slPrice,
        if (tpPrice != null) 'tpPrice': tpPrice,
        'oneClick': oneClick,
        'clientOrderId': clientOrderId ?? _clientOrderId(),
      };
}

String _clientOrderId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}
