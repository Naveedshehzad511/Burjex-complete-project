class AuditEntry {
  final String id;
  final String action;
  final String? entity;
  final String? entityId;
  final String? actorType;
  final String? actorId;
  final String? ip;
  final DateTime createdAt;

  const AuditEntry({
    required this.id,
    required this.action,
    this.entity,
    this.entityId,
    this.actorType,
    this.actorId,
    this.ip,
    required this.createdAt,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'],
        action: j['action'],
        entity: j['entity'],
        entityId: j['entityId'],
        actorType: j['actorType'],
        actorId: j['actorId'],
        ip: j['ip'],
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      );
}
