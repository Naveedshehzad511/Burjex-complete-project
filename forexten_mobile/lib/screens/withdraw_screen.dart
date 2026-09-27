import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/crm_api.dart';
import '../state/account_view.dart';

class WithdrawScreen extends ConsumerStatefulWidget {
  const WithdrawScreen({super.key});
  @override
  ConsumerState<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends ConsumerState<WithdrawScreen> {
  final _amount = TextEditingController();
  Map<String, dynamic>? _methods;
  Object? _loadError;
  bool _busy = false;
  String? _gateway;
  String? _requestUid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref.read(crmApiProvider).get('/withdrawals/methods/');
      if (!mounted) return;
      setState(() {
        _methods = data;
        _loadError = null;
        _requestUid = data['request_uid']?.toString();
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
      await ref.read(crmApiProvider).post('/withdrawals/', {
        'amount': amt.toStringAsFixed(2),
        'currency': 'USD',
        'withdraw_from': 'wallet',
        if (_gateway != null && _gateway!.isNotEmpty) 'gateway': _gateway,
        if (_requestUid != null) 'request_uid': _requestUid,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Withdrawal request submitted.')));
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
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/home')), title: const Text('Withdraw')),
      body: _loadError != null
          ? Center(child: Text('$_loadError', textAlign: TextAlign.center))
          : _methods == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  if (acc != null) Text('Wallet / account #${acc.login}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('Withdrawals debit the CRM wallet. Transfer from a trading account first if needed.'),
                  const SizedBox(height: 12),
                  if (_methods!['allowed'] == false)
                    Text('${_methods!['block_reason'] ?? 'Withdrawals are not available.'}', style: const TextStyle(color: Color(0xFFE5484D))),
                  TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount (USD)'),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Submitting…' : 'Submit withdrawal')),
                ]),
    );
  }
}
