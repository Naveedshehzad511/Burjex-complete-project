import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../shell.dart';
import '../widgets/adaptive_table.dart';
import 'accounts_screen.dart' show allAccountsProvider;

/// Demo (paper-trading) accounts only — kept entirely separate from the live
/// Trading Accounts page. Virtual balances, B-book, real prices.
class DemoAccountsScreen extends ConsumerWidget {
  const DemoAccountsScreen({super.key});

  static double _n(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

  static String _date(dynamic v) {
    if (v == null) return '—';
    final d = DateTime.tryParse(v.toString())?.toLocal();
    if (d == null) return '—';
    return '${d.day}/${d.month}/${d.year % 100}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(allAccountsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(allAccountsProvider);

    return AdminPage(
      title: 'Demo Accounts',
      actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))],
      child: accounts.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final list = all.where((a) => a['isDemo'] == true).toList();
          if (list.isEmpty) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: Text('No demo accounts yet. Clients can open one from the app, or create a DEMO-type account in Clients.')),
              ),
            );
          }
          return SingleChildScrollView(
            child: AdaptiveTable(
              columns: const ['#', 'Name', 'Email', 'Phone', 'Account #', 'Ccy', 'Leverage', 'Balance', 'Equity', 'Floating P/L', 'Created'],
              rows: [
                for (var i = 0; i < list.length; i++)
                  () {
                    final a = list[i];
                    final fpl = _n(a['floatingPL']);
                    return AdaptiveRow(
                      onTap: () => context.go('/account/${a['id']}'),
                      cells: [
                        Text('${i + 1}'),
                        Row(children: [
                          Flexible(child: Text('${a['name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 6),
                          const _DemoBadge(),
                        ]),
                        SelectableText('${a['email'] ?? '—'}'),
                        SelectableText('${a['phone'] ?? '—'}'),
                        Text('${a['login'] ?? ''}'),
                        Text('${a['currency'] ?? ''}'),
                        Text('1:${a['leverage'] ?? 100}'),
                        Text(money(_n(a['balance']))),
                        Text(money(_n(a['equity']))),
                        Text(money(fpl), style: TextStyle(color: fpl > 0 ? tc.profit : (fpl < 0 ? tc.loss : null))),
                        Text(_date(a['createdAt'])),
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

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFFFFA726), borderRadius: BorderRadius.circular(4)),
        child: const Text('DEMO', style: TextStyle(color: Color(0xFF4A2A00), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      );
}
