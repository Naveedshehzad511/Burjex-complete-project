import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../auth/auth_page.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _email = TextEditingController();
  final _otp = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _email.dispose();
    _otp.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final msg = await ref.read(authControllerProvider.notifier).forgotPassword(_email.text.trim());
      if (mounted) {
        setState(() {
          _ok = msg;
          _codeSent = true;
        });
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_pass.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).resetPasswordOtp(
            email: _email.text.trim(),
            otp: _otp.text.trim(),
            password: _pass.text,
            confirm: _confirm.text,
          );
      try {
        await ref.read(authControllerProvider.notifier).login(_email.text.trim(), _pass.text);
      } catch (_) {
        if (mounted) context.go('/login');
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      onBack: () => context.canPop() ? context.pop() : context.go('/login'),
      title: 'Forgot password',
      children: [
        TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: authField('Email')),
        const SizedBox(height: 12),
        if (_codeSent) ...[
          TextField(controller: _otp, keyboardType: TextInputType.number, decoration: authField('6-digit code')),
          const SizedBox(height: 12),
          TextField(controller: _pass, obscureText: true, decoration: authField('New password')),
          const SizedBox(height: 12),
          TextField(controller: _confirm, obscureText: true, decoration: authField('Confirm password')),
          const SizedBox(height: 16),
        ],
        if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0BB07B))),
        if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : (_codeSent ? _save : _send),
          style: authPrimaryButton(),
          child: Text(_busy ? 'Please wait…' : (_codeSent ? 'Update password' : 'Send code')),
        ),
      ],
    );
  }
}
