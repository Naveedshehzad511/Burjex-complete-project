import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../auth/auth_page.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).login(_email.text.trim(), _password.text);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      children: [
        const Text(
          'Welcome to Burjex Prime',
          style: TextStyle(color: authNavy, fontSize: 26, fontWeight: FontWeight.w700, height: 1.2),
        ),
        const SizedBox(height: 8),
        Text('Sign in to your client account', style: TextStyle(color: Colors.grey.shade600, fontSize: 15, height: 1.4)),
        const SizedBox(height: 28),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: authField('Email'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          obscureText: _hide,
          decoration: authField(
            'Password',
            suffix: IconButton(
              onPressed: () => setState(() => _hide = !_hide),
              icon: Icon(_hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy ? null : () => context.push('/forgot-password'),
            child: const Text('Forgot password?'),
          ),
        ),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Color(0xFFE5484D), height: 1.35)),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: authPrimaryButton(),
          child: Text(_busy ? 'Signing in…' : 'LOGIN', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : () => context.push('/register'),
          style: authOutlineButton(),
          child: const Text('Create Account', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
