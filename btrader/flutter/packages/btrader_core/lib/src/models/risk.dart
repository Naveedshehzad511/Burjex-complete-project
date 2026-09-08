class RiskLimit {
  final String id;
  final String scope;
  final double? maxLotPerOrder;
  final double? maxOpenLots;
  final int? maxOpenPositions;
  final double? maxNetExposure;
  final bool enabled;

  const RiskLimit({
    required this.id,
    required this.scope,
    this.maxLotPerOrder,
    this.maxOpenLots,
    this.maxOpenPositions,
    this.maxNetExposure,
    required this.enabled,
  });

  static double? _dn(dynamic v) => v == null ? null : double.tryParse(v.toString());

  factory RiskLimit.fromJson(Map<String, dynamic> j) => RiskLimit(
        id: j['id'],
        scope: j['scope'],
        maxLotPerOrder: _dn(j['maxLotPerOrder']),
        maxOpenLots: _dn(j['maxOpenLots']),
        maxOpenPositions: j['maxOpenPositions'],
        maxNetExposure: _dn(j['maxNetExposure']),
        enabled: j['enabled'] ?? true,
      );
}

class MarginAlert {
  final String id;
  final String login;
  final double marginLevel;
  final double equity;
  final double margin;
  const MarginAlert({required this.id, required this.login, required this.marginLevel, required this.equity, required this.margin});

  static double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;
  factory MarginAlert.fromJson(Map<String, dynamic> j) =>
      MarginAlert(id: j['id'], login: j['login'].toString(), marginLevel: _d(j['marginLevel']), equity: _d(j['equity']), margin: _d(j['margin']));
}
