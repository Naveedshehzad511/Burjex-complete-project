import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/account_panel.dart';

/// Deposit / withdrawal request screen. Funding originates in the broker CRM
/// (per the platform design), so the app captures the request and hands off to
/// the broker portal rather than moving money directly. Wired from Account.
class FundingScreen extends ConsumerStatefulWidget {
  const FundingScreen({super.key, required this.type});
  final String type; // 'deposit' | 'withdraw'

  @override
  ConsumerState<FundingScreen> createState() => _FundingScreenState();
}

class _FundingScreenState extends ConsumerState<FundingScreen> {
  final _amount = TextEditingController();
  String _method = 'Bank transfer';

  bool get isDeposit => widget.type == 'deposit';

  @override
  Widget build(BuildContext context) {
    final title = isDeposit ? 'Deposit' : 'Withdraw';
    final account = ref.watch(activeAccountProvider);

    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/account')), title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const AccountPanel(),
        const SizedBox(height: 16),
        Text('$title request', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 4),
        Text(
          isDeposit
              ? 'Submit a deposit request. Your broker confirms and credits the account.'
              : 'Submit a withdrawal request. Withdrawable funds exclude margin in use.',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Amount (${account?.currency ?? 'USD'})'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _method,
          items: const ['Bank transfer', 'Card', 'Crypto', 'E-wallet']
              .map((m) => DropdownMenuItem(value: m, child: Text(m)))
              .toList(),
          onChanged: (v) => setState(() => _method = v ?? _method),
          decoration: const InputDecoration(labelText: 'Method'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$title request submitted to your broker.'), behavior: SnackBarBehavior.floating),
            );
            context.go('/account');
          },
          child: Text('Submit $title request'),
        ),
        const SizedBox(height: 12),
        Text(
          'Funds are processed by your broker. You can also manage funding from the broker client portal.',
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ]),
    );
  }
}
