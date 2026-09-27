import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/crm_api.dart';
import '../state/account_view.dart';

class DepositScreen extends ConsumerStatefulWidget {
  const DepositScreen({super.key});
  @override
  ConsumerState<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends ConsumerState<DepositScreen> {
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  Map<String, dynamic>? _methods;
  Object? _loadError;
  bool _busy = false;
  String? _gateway;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref.read(crmApiProvider).get('/deposits/methods/');
      if (!mounted) return;
      setState(() {
        _methods = data;
        _loadError = null;
        final gws = data['gateways'];
        if (gws is List && gws.isNotEmpty && gws.first is Map) {
          _gateway = '${gws.first['id'] ?? gws.first['pk'] ?? ''}';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount')));
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(crmApiProvider).post('/deposits/', {
        'amount': amt.toStringAsFixed(2),
        'currency': 'USD',
        if (_gateway != null && _gateway!.isNotEmpty) 'gateway': _gateway,
        'notes': _notes.text.trim(),
        'trading_account': ref.read(activeAccountProvider)?.login ?? 'wallet',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deposit request submitted.')));
      context.go('/home');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final acc = ref.watch(activeAccountProvider);
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/home')), title: const Text('Deposit')),
      body: _loadError != null
          ? Center(child: Text('$_loadError', textAlign: TextAlign.center))
          : _methods == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  if (acc != null) Text('Account #${acc.login}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  if (_methods!['allowed'] == false)
                    Text('${_methods!['block_reason'] ?? 'Deposits are not available.'}', style: const TextStyle(color: Color(0xFFE5484D))),
                  TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount (USD)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Submitting…' : 'Submit deposit')),
                ]),
    );
  }
}
