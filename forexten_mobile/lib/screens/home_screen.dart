import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final activeId = ref.watch(activeAccountIdProvider);
    final live = ref.watch(liveAccountProvider);
    final mode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            tooltip: 'Account menu',
            icon: const Icon(Icons.person_outline),
            onPressed: () => _accountMenu(context, ref),
          ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(mode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(child: Text('$e', textAlign: TextAlign.center)),
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('No trading accounts yet.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              for (final a in list)
                _AccountCard(
                  account: live[a.id] ?? a,
                  selected: a.id == activeId,
                  onSelect: () => ref.read(activeAccountIdProvider.notifier).state = a.id,
                ),
              const SizedBox(height: 8),
              _QuickActions(
                onDeposit: () => context.push('/deposit'),
                onWithdraw: () => context.push('/withdraw'),
              ),
              const SizedBox(height: 12),
              _MyFund(
                onDeposit: () => context.push('/deposit'),
                onWithdraw: () => context.push('/withdraw'),
                onTransfer: () => context.push('/transfer'),
                onTx: () => context.push('/transactions'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _accountMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.logout, color: Color(0xFFE5484D)),
            title: const Text('Sign out', style: TextStyle(color: Color(0xFFE5484D))),
            onTap: () {
              Navigator.pop(ctx);
              ref.read(authControllerProvider.notifier).logout();
              context.go('/login');
            },
          ),
        ]),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.selected, required this.onSelect});
  final Account account;
  final bool selected;
  final VoidCallback onSelect;

  bool get _demo => account.isDemo || account.type.toUpperCase() == 'DEMO';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? scheme.primary : Theme.of(context).dividerColor),
      ),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('#${account.login}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Text(
                _demo ? 'DEMO' : account.type,
                style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _metric(context, 'Balance', money(account.balance))),
              Expanded(child: _metric(context, 'Equity', money(account.liveEquity))),
              Expanded(child: _metric(context, 'Leverage', '1:${account.leverage}')),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              if (!_demo) ...[
                Expanded(child: _action(context, 'Deposit', Icons.south_east, () => context.push('/deposit'))),
                const SizedBox(width: 8),
                Expanded(child: _action(context, 'Withdraw', Icons.north_east, () => context.push('/withdraw'))),
                const SizedBox(width: 8),
              ],
              Expanded(child: _action(context, 'Trade', Icons.swap_horiz, () => context.go('/trade'))),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      );

  Widget _action(BuildContext context, String label, IconData icon, VoidCallback onTap) {
    return FilledButton.tonal(
      onPressed: onTap,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Text(label),
      ]),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onDeposit, required this.onWithdraw});
  final VoidCallback onDeposit;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Quick Actions', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FilledButton(onPressed: onDeposit, child: const Text('Deposit'))),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(onPressed: onWithdraw, child: const Text('Withdraw')),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _MyFund extends StatelessWidget {
  const _MyFund({
    required this.onDeposit,
    required this.onWithdraw,
    required this.onTransfer,
    required this.onTx,
  });
  final VoidCallback onDeposit, onWithdraw, onTransfer, onTx;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(children: [
        const ListTile(title: Text('My Fund', style: TextStyle(fontWeight: FontWeight.w700))),
        ListTile(leading: const Icon(Icons.south_east), title: const Text('Deposit'), onTap: onDeposit),
        ListTile(leading: const Icon(Icons.north_east), title: const Text('Withdraw'), onTap: onWithdraw),
        ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Internal Transfer'), onTap: onTransfer),
        ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('Transactions'), onTap: onTx),
      ]),
    );
  }
}
