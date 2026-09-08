import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final activeId = ref.watch(activeAccountIdProvider);
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => ListView(padding: const EdgeInsets.all(12), children: [
          for (final a in list)
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: a.id == activeId ? brand.primary : Theme.of(context).dividerColor),
              ),
              child: InkWell(
                onTap: () => ref.read(activeAccountIdProvider.notifier).state = a.id,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('#${a.login}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                      Text('${a.type} · 1:${a.leverage}', style: TextStyle(color: Theme.of(context).hintColor)),
                    ]),
                    const SizedBox(height: 12),
                    Wrap(spacing: 24, runSpacing: 10, children: [
                      _Metric('Balance', '${money(a.balance)} ${a.currency}'),
                      _Metric('Equity', '${money(a.equity)} ${a.currency}'),
                      _Metric('Free margin', money(a.freeMargin)),
                      _Metric('Margin level', '${a.marginLevel.toStringAsFixed(0)}%'),
                    ]),
                    if (a.id == activeId) ...[
                      const SizedBox(height: 10),
                      Text('Active', style: TextStyle(color: brand.primary, fontWeight: FontWeight.w500, fontSize: 12)),
                    ],
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 8),
          ListTile(leading: const Icon(Icons.history_rounded), title: const Text('Trade history'), trailing: const Icon(Icons.chevron_right), onTap: () => context.go('/history')),
          ListTile(leading: const Icon(Icons.tune), title: const Text('Leverage'), trailing: Text(list.isNotEmpty ? '1:${list.first.leverage}' : '—')),
          ListTile(leading: const Icon(Icons.south_east), title: const Text('Deposit'), trailing: const Icon(Icons.chevron_right), onTap: () => context.go('/deposit')),
          ListTile(leading: const Icon(Icons.north_east), title: const Text('Withdraw'), trailing: const Icon(Icons.chevron_right), onTap: () => context.go('/withdraw')),
          ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Settings'), trailing: const Icon(Icons.chevron_right), onTap: () => context.go('/settings')),
          ListTile(
            leading: const Icon(Icons.logout, color: Color(0xFFE5484D)),
            title: const Text('Sign out', style: TextStyle(color: Color(0xFFE5484D))),
            onTap: () => ref.read(authControllerProvider.notifier).logout(),
          ),
          const SizedBox(height: 16),
          Center(child: Text(brand.appName, style: TextStyle(color: Theme.of(context).hintColor))),
        ]),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w500, fontFeatures: [FontFeature.tabularFigures()])),
      ]);
}
