import 'package:flutter_riverpod/flutter_riverpod.dart';

class PendingSignup {
  const PendingSignup({required this.email, required this.password});
  final String email;
  final String password;
}

final pendingSignupProvider = StateProvider<PendingSignup?>((ref) => null);
