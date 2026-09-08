import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

/// Manual money movements: deposit / withdraw / bonus / dividend / manual.
class FinancialScreen extends ConsumerStatefulWidget {
  const FinancialScreen({super.key, this.initialAccountId});
  final String? initialAccountId;
  @override
  ConsumerState<FinancialScreen> createState() => _FinancialScreenState();
}

class _FinancialScreenState extends ConsumerState<FinancialScreen> {
  late String? _accountId = widget.initialAccountId;
  String _type = 'DEPOSIT';
  final _amount = TextEditingController();
  final _comment = TextEditingController();
  String? _result;
  bool _busy = false;

  Future<void> _submit() async {
    if (_accountId == null || _amount.text.isEmpty) return;
    setState(() { _busy = true; _result = null; });
    try {
      final r = await ref.read(apiClientProvider).post('/financial/adjust', {
        'accountId': _accountId, 'type': _type, 'amount': double.tryParse(_amount.text), 'comment': _comment.text,
      });
      setState(() => _result = '✓ Applied. New balance: ${money(r['balanceAfter'] ?? 0)}');
      _amount.clear();
      ref.invalidate(clientsProvider);
    } catch (_) {
      setState(() => _result = '✗ Operation failed');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(clientsProvider);
    return AdminPage(
      title: 'Financial Operations',
      child: clients.when(
        // The account list refetches every ~2s via adminLiveTicker (to keep the
        // dropdown balances live). Without this, each reload re-enters the
        // loading state and the whole form flashes to a spinner every couple of
        // seconds — keep the form on screen during the silent refresh instead.
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          final accounts = [for (final c in list) for (final a in c.accounts) (a: a, name: c.name)];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    const Text('Balance adjustment', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16)),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _accountId,
                      isExpanded: true,
                      hint: const Text('Select an account'),
                      items: accounts.map((e) => DropdownMenuItem(value: e.a.id, child: Text('#${e.a.login} · ${e.name} · ${e.a.currency} ${money(e.a.balance)}'))).toList(),
                      onChanged: (v) => setState(() => _accountId = v),
                      decoration: const InputDecoration(labelText: 'Account'),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: DropdownButtonFormField<String>(
                        initialValue: _type,
                        items: const ['DEPOSIT', 'WITHDRAWAL', 'BONUS', 'DIVIDEND', 'CREDIT', 'MANUAL', 'CORRECTION'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                        onChanged: (v) => setState(() => _type = v ?? 'DEPOSIT'),
                        decoration: const InputDecoration(labelText: 'Type'),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount'))),
                    ]),
                    const SizedBox(height: 12),
                    TextField(controller: _comment, decoration: const InputDecoration(labelText: 'Comment')),
                    if (_result != null) ...[
                      const SizedBox(height: 12),
                      Text(_result!, style: TextStyle(color: _result!.startsWith('✓') ? Theme.of(context).extension<TradeColors>()!.profit : Theme.of(context).extension<TradeColors>()!.loss)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Processing…' : 'Apply $_type')),
                    const SizedBox(height: 8),
                    Text('BONUS / CREDIT move non-withdrawable credit. WITHDRAWAL checks free balance. CRM-originated ops arrive via the signed integration API and are idempotent.',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
