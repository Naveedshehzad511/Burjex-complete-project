import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../widgets/auth_page.dart';

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
      setState(() {
        _codeSent = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_pass.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    if (_pass.text.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
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
      title: 'Forgot password',
      onBack: () => context.canPop() ? context.pop() : context.go('/login'),
      children: [
        Text(
          _codeSent
              ? 'Enter the 6-digit code we emailed you, then choose a new password.'
              : 'Enter the email on your account. We will send a 6-digit code.',
          style: TextStyle(color: Colors.grey.shade700, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          enabled: !_codeSent,
          decoration: authField('Email'),
        ),
        if (!_codeSent) ...[
          const SizedBox(height: 16),
          if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B), height: 1.35)),
          if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D), height: 1.35)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _send,
            style: authPrimaryButton(),
            child: Text(_busy ? 'Sending…' : 'Send code', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ] else ...[
          const SizedBox(height: 14),
          TextField(
            controller: _otp,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: authField('6-digit code', counterText: ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: authField('New password', helper: 'At least 8 characters'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: authField('Confirm password'),
          ),
          const SizedBox(height: 16),
          if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B), height: 1.35)),
          if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D), height: 1.35)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: authPrimaryButton(),
            child: Text(_busy ? 'Saving…' : 'Set new password', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: _busy ? null : _send,
            child: const Text('Resend code'),
          ),
        ],
      ],
    );
  }
}
