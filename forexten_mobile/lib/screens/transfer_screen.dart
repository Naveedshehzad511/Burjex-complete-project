import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/crm_api.dart';

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});
  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  final _amount = TextEditingController();
  Map<String, dynamic>? _opts;
  Object? _loadError;
  bool _busy = false;
  String? _from;
  String? _to;
  String? _type;
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
      final data = await ref.read(crmApiProvider).get('/transfers/internal/');
      if (!mounted) return;
      setState(() {
        _opts = data;
        _loadError = null;
        _requestUid = data['request_uid']?.toString();
        final types = data['transfer_types'];
        if (types is List && types.isNotEmpty) _type = types.first.toString();
        final accts = data['trading_accounts'];
        if (accts is List && accts.isNotEmpty && accts.first is Map) {
          _from = accts.first['from_account_key']?.toString();
          if (accts.length > 1) _to = (accts[1] as Map)['from_account_key']?.toString();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await ref.read(crmApiProvider).post('/transfers/internal/', {
        'transfer_type': _type,
        'from_account': _from,
        'to_account': _to,
        'amount': _amount.text.trim(),
        if (_requestUid != null) 'request_uid': _requestUid,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transfer submitted.')));
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
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/home')), title: const Text('Internal Transfer')),
      body: _loadError != null
          ? Center(child: Text('$_loadError', textAlign: TextAlign.center))
          : _opts == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  if (_opts!['allowed'] == false)
                    Text('${_opts!['block_reason'] ?? 'Transfers are not available.'}', style: const TextStyle(color: Color(0xFFE5484D))),
                  Text('Wallet ${(_opts!['wallet_balance'] ?? '—')}'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Submitting…' : 'Submit transfer')),
                ]),
    );
  }
}
