import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

const _navy = Color(0xFF002D58);

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, required this.uid, required this.token});
  final String uid;
  final String token;

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
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
      final msg = await ref.read(authControllerProvider.notifier).resetPassword(
            uid: widget.uid,
            token: widget.token,
            password: _pass.text,
            confirm: _confirm.text,
          );
      if (mounted) setState(() => _ok = msg);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.uid.isEmpty || widget.token.isEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _navy,
        elevation: 0,
        title: const Text('Reset password'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (missing)
                const Text('This reset link is incomplete. Request a new one from Forgot password.')
              else ...[
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 14),
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
                    onPressed: _busy || _ok != null ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    child: Text(_busy ? 'Saving…' : 'Update password'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Back to login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
