import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

const _navy = Color(0xFF002D58);

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
      await ref.read(authControllerProvider.notifier).login(_email.text.trim(), _pass.text);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _navy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => context.canPop() ? context.pop() : context.go('/login'),
        ),
        title: const Text('Forgot Password'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: ListView(
            children: [
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                enabled: !_codeSent,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              if (!_codeSent) ...[
                const SizedBox(height: 16),
                if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B))),
                if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _busy ? null : _send,
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    child: Text(_busy ? 'Sending…' : 'Send code'),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _otp,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'OTP code', counterText: ''),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm password'),
                ),
                const SizedBox(height: 16),
                if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B))),
                if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    child: Text(_busy ? 'Saving…' : 'Set new password'),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : _send,
                  child: const Text('Resend code'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
