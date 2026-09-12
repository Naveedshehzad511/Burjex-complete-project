import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

const _navy = Color(0xFF002D58);

class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  bool _busy = true;
  String? _error;
  String? _ok;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (widget.token.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'This verification link is incomplete.';
      });
      return;
    }
    try {
      final msg = await ref.read(authControllerProvider.notifier).verifyEmailToken(widget.token);
      if (mounted) setState(() => _ok = msg);
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
        title: const Text('Verify email'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const Text('Verifying your email…'),
              if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B))),
              if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
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
