import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/adaptive_table.dart';

/// Trading control: net exposure + all open positions with modify/close/close-all.
class TradingScreen extends ConsumerWidget {
  const TradingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions = ref.watch(allPositionsProvider);
    final exposure = ref.watch(exposureProvider);
    ref.watch(adminAccountWatchProvider); // subscribe accounts so live position P/L flows
    final livePL = ref.watch(livePositionProvider); // per-position P/L pushed on each tick
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async {
      ref.invalidate(allPositionsProvider);
      ref.invalidate(exposureProvider);
    }

    return AdminPage(
      title: 'Trading Control',
      actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))],
      child: ListView(children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Net exposure (signed lots)', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 10),
              exposure.maybeWhen(
                skipLoadingOnReload: true,
                data: (net) => net.isEmpty
                    ? const Text('No open exposure.')
                    : Wrap(spacing: 10, runSpacing: 10, children: net.entries.map((e) {
                        final c = e.value >= 0 ? tc.profit : tc.loss;
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                          child: Text('${e.key}: ${e.value >= 0 ? '+' : ''}${e.value.toStringAsFixed(2)}',
                              style: TextStyle(color: c, fontWeight: FontWeight.w500)),
                        );
                      }).toList()),
                orElse: () => const SizedBox.shrink(),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        positions.when(
          skipLoadingOnReload: true,
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) => list.isEmpty
              ? const Card(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No open positions.'))))
              : SingleChildScrollView(
                  child: AdaptiveTable(
                    columns: const ['Account', 'Symbol', 'Side', 'Volume', 'Open', 'P/L'],
                    rows: list.map((p) {
                      // Live per-tick P/L (WS) overrides the stale stored value.
                      final pl = livePL[p.id] ?? p.profit;
                      return AdaptiveRow(
                          cells: [
                            Text(p.accountLogin ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(p.symbol),
                            Text(p.side, style: TextStyle(color: p.side == 'BUY' ? tc.buy : tc.sell)),
                            Text(p.volume.toStringAsFixed(2)),
                            Text(price(p.openPrice, p.digits)),
                            Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss)),
                          ],
                          actions: [
                            TextButton(
                              onPressed: () async { await api.post('/positions/${p.id}/close'); await refresh(); },
                              child: Text('Close', style: TextStyle(color: tc.loss)),
                            ),
                            TextButton(
                              onPressed: () async { await api.post('/accounts/${p.accountId}/close-all'); await refresh(); },
                              child: const Text('Close all'),
                            ),
                          ],
                        );
                    }).toList(),
                  ),
                ),
          ),
      ]),
    );
  }
}
