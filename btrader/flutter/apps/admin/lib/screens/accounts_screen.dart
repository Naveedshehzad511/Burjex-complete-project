import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/adaptive_table.dart';

/// Flat list of every trading account with owner + live balance/equity/floating.
/// Refreshes on the shared admin live ticker so money fields stay current.
final allAccountsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  ref.watch(adminLiveTicker);
  final api = ref.watch(apiClientProvider);
  return (await api.get('/accounts/all') as List).cast<Map<String, dynamic>>();
});

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  static double _n(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(allAccountsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(allAccountsProvider);

    return AdminPage(
      title: 'Trading Accounts',
      actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))],
      child: accounts.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          // Real/live accounts only — demo accounts live on their own page.
          final list = all.where((a) => a['isDemo'] != true).toList();
          return list.isEmpty
            ? const Card(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No trading accounts.'))))
            : SingleChildScrollView(
                child: AdaptiveTable(
                  columns: const ['#', 'Name', 'Account #', 'Balance', 'Equity', 'Floating P/L'],
                  rows: [
                    for (var i = 0; i < list.length; i++)
                      () {
                        final a = list[i];
                        final fpl = _n(a['floatingPL']);
                        return AdaptiveRow(
                          onTap: () => context.go('/account/${a['id']}'),
                          cells: [
                            Text('${i + 1}'),
                            Text('${a['name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text('${a['login'] ?? ''}'),
                            Text(money(_n(a['balance']))),
                            Text(money(_n(a['equity']))),
                            Text(
                              money(fpl),
                              style: TextStyle(color: fpl > 0 ? tc.profit : (fpl < 0 ? tc.loss : null)),
                            ),
                          ],
                        );
                      }(),
                  ],
                ),
              );
        },
      ),
    );
  }
}
