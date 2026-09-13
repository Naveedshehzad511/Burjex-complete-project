import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../pending_signup.dart';
import '../widgets/auth_page.dart';

class VerifyOtpScreen extends ConsumerStatefulWidget {
  const VerifyOtpScreen({super.key, required this.email});
  final String email;

  @override
  ConsumerState<VerifyOtpScreen> createState() => _VerifyOtpScreenState();
}

class _VerifyOtpScreenState extends ConsumerState<VerifyOtpScreen> {
  final _otp = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _otp.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final email = widget.email.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Email is missing. Create the account again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final pending = ref.read(pendingSignupProvider);
      final password = pending?.email.toLowerCase() == email.toLowerCase() ? pending!.password : '';
      await ref.read(authControllerProvider.notifier).verifyEmailOtp(
            email: email,
            otp: _otp.text.trim(),
            password: password,
          );
      if (password.isNotEmpty) {
        await ref.read(authControllerProvider.notifier).login(email, password);
      }
      ref.read(pendingSignupProvider.notifier).state = null;
      if (mounted && password.isEmpty) context.go('/login');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final msg = await ref.read(authControllerProvider.notifier).resendEmailOtp(widget.email.trim());
      if (mounted) setState(() => _ok = msg);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      title: 'Verify email',
      onBack: () => context.canPop() ? context.pop() : context.go('/'),
      children: [
        Text(
          'Enter the 6-digit code we sent to ${widget.email}.',
          style: TextStyle(color: Colors.grey.shade700, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _otp,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: authField('6-digit code', counterText: ''),
          onSubmitted: (_) => _busy ? null : _verify(),
        ),
        const SizedBox(height: 12),
        if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B), height: 1.35)),
        if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D), height: 1.35)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _verify,
          style: authPrimaryButton(),
          child: Text(_busy ? 'Verifying…' : 'Verify and continue', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        TextButton(
          onPressed: _busy ? null : _resend,
          child: const Text('Resend code'),
        ),
      ],
    );
  }
}
