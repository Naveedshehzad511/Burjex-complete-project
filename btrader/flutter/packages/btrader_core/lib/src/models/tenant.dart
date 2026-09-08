class Tenant {
  final String id;
  final String name;
  final String slug;
  final String? domain;
  final String status;
  final String baseCurrency;
  final String appName;
  final String primaryColor;
  final String accentColor;
  final String? logoUrl;
  final String? supportEmail;
  final String? supportPhone;
  final DateTime createdAt;

  const Tenant({
    required this.id,
    required this.name,
    required this.slug,
    this.domain,
    required this.status,
    required this.baseCurrency,
    required this.appName,
    required this.primaryColor,
    this.accentColor = '#0BB07B',
    this.logoUrl,
    this.supportEmail,
    this.supportPhone,
    required this.createdAt,
  });

  factory Tenant.fromJson(Map<String, dynamic> j) {
    final b = (j['branding'] ?? {}) as Map<String, dynamic>;
    return Tenant(
      id: j['id'],
      name: j['name'],
      slug: j['slug'],
      domain: j['domain'],
      status: j['status'] ?? 'ACTIVE',
      baseCurrency: j['baseCurrency'] ?? 'USD',
      appName: b['appName'] ?? j['name'],
      primaryColor: b['primaryColor'] ?? '#1652F0',
      accentColor: b['accentColor'] ?? '#0BB07B',
      logoUrl: b['logoUrl'],
      supportEmail: b['supportEmail'],
      supportPhone: b['supportPhone'],
      createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
    );
  }
}
