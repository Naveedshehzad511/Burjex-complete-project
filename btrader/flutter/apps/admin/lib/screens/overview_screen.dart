import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';

class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = ref.watch(clientsProvider);
    final alerts = ref.watch(marginAlertsProvider);
    final allPositions = ref.watch(allPositionsProvider); // every open position, tenant-wide
    final livePL = ref.watch(livePositionProvider); // per-position live P/L (WS)
    ref.watch(adminAccountWatchProvider); // subscribe all accounts to the live stream
    final tc = Theme.of(context).extension<TradeColors>()!;

    return AdminPage(
      title: 'Overview',
      child: clients.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          final accounts = list.expand((c) => c.accounts).toList();
          // Derive the totals from the ACTUAL open positions (like the trader
          // portfolio) so the header can never show phantom P/L for accounts
          // that are flat. Floating = sum of live per-position P/L; margin only
          // counts accounts that actually hold positions; balances come from the
          // ticker-refreshed HTTP account rows.
          final posList = allPositions.valueOrNull ?? const <Position>[];
          final activeAcctIds = posList.map((p) => p.accountId).toSet();
          double floating = 0;
          for (final p in posList) {
            floating += livePL[p.id] ?? p.profit;
          }
          double balance = 0, margin = 0;
          for (final a in accounts) {
            balance += a.balance + a.credit;
            if (activeAcctIds.contains(a.id)) margin += a.margin;
          }
          final equity = balance + floating;

          return ListView(children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              StatCard(label: 'Clients', value: '${list.length}'),
              StatCard(label: 'Total equity', value: '\$${money(equity)}'),
              StatCard(label: 'Used margin', value: '\$${money(margin)}'),
              StatCard(label: 'Floating P/L', value: '\$${money(floating)}', color: floating >= 0 ? tc.profit : tc.loss),
            ]),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Text('Margin alerts', style: TextStyle(fontWeight: FontWeight.w500)),
                    const Spacer(),
                    alerts.when(
                      skipLoadingOnReload: true,
                      data: (a) => Chip(label: Text('${a.length}'), backgroundColor: a.isEmpty ? null : tc.loss.withValues(alpha: 0.15)),
                      loading: () => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                    TextButton(onPressed: () => context.go('/risk'), child: const Text('View all')),
                  ]),
                  const SizedBox(height: 8),
                  alerts.maybeWhen(
                    skipLoadingOnReload: true,
                    data: (a) => a.isEmpty
                        ? const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('No accounts near margin call.')))
                        : Column(children: a.map((m) => ListTile(
                              dense: true,
                              title: Text('#${m.login}'),
                              trailing: Text('${m.marginLevel.toStringAsFixed(0)}%', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w500)),
                              onTap: () => context.go('/risk'),
                            )).toList()),
                    orElse: () => const SizedBox.shrink(),
                  ),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
