import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../state/account_view.dart';

final _historyProvider = FutureProvider.autoDispose<List<Deal>>((ref) async {
  final id = ref.watch(activeAccountIdProvider);
  if (id == null) return [];
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/history/deals', query: {'accountId': id}) as List;
  return data.map((e) => Deal.fromJson(e)).toList();
});

const _balanceTypes = {'DEPOSIT', 'WITHDRAWAL', 'BONUS', 'DIVIDEND', 'CREDIT', 'BALANCE'};

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final suffix = ref.watch(clientSuffixProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_historyProvider))],
      ),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final rows = all.where((d) => d.isTrade || _balanceTypes.contains(d.type)).toList();
          if (rows.isEmpty) {
            return Center(child: Text('No history yet.', style: TextStyle(color: Theme.of(context).hintColor)));
          }
          double deposit = 0, withdrawal = 0, profit = 0, swap = 0, commission = 0;
          for (final d in all) {
            if (d.isTrade) {
              profit += d.profit;
              swap += d.swap;
              commission += d.commission;
            } else if (d.type == 'WITHDRAWAL') {
              withdrawal += d.amount;
            } else if (_balanceTypes.contains(d.type)) {
              deposit += d.amount;
            }
          }
          final balance = all.isNotEmpty ? all.first.balanceAfter : 0;
          return ListView(children: [
            for (final d in rows)
              ListTile(
                title: Text(d.isTrade ? symbolDisplay(d.symbol ?? '', suffix) : d.type, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(dateTime(d.createdAt)),
                trailing: Text(
                  money(d.isTrade ? d.profit : d.amount),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: (d.isTrade ? d.profit : d.amount) >= 0 ? tc.up : tc.down,
                  ),
                ),
              ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(children: [
                _sum(context, 'Deposit', money(deposit), tc.up),
                _sum(context, 'Withdrawal', money(withdrawal), tc.down),
                _sum(context, 'Profit', money(profit), profit >= 0 ? tc.up : tc.down),
                _sum(context, 'Swap', money(swap), null),
                _sum(context, 'Commission', money(commission), commission < 0 ? tc.down : null),
                _sum(context, 'Balance', money(balance), null, bold: true),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _sum(BuildContext context, String k, String v, Color? color, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          Text(v, style: TextStyle(color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );
}
