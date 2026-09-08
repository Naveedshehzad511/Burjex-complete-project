import 'account.dart';

class Client {
  final String id;
  final String email;
  final String? firstName;
  final String? lastName;
  final bool isActive;
  final DateTime createdAt;
  final List<Account> accounts;

  const Client({
    required this.id,
    required this.email,
    this.firstName,
    this.lastName,
    required this.isActive,
    required this.createdAt,
    required this.accounts,
  });

  String get name => [firstName, lastName].where((e) => e != null && e.isNotEmpty).join(' ');

  factory Client.fromJson(Map<String, dynamic> j) => Client(
        id: j['id'],
        email: j['email'],
        firstName: j['firstName'],
        lastName: j['lastName'],
        isActive: j['isActive'] ?? true,
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        accounts: ((j['accounts'] ?? []) as List).map((a) => Account.fromJson(a)).toList(),
      );
}
