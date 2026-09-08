class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String role;
  const AuthTokens({required this.accessToken, required this.refreshToken, required this.role});

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
        accessToken: j['accessToken'],
        refreshToken: j['refreshToken'],
        role: j['role'] ?? 'TRADER',
      );
}
