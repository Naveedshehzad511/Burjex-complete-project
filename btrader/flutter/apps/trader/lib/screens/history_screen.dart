import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../widgets/account_panel.dart';

/// MT5-style account history: closed trades (entry → exit, profit) and balance
/// operations (deposits/withdrawals) in one list, with a totals summary footer.
/// MT5 colour convention: profit/credit = blue, loss/debit = red.
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_historyProvider))],
      ),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
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

          final suffix = ref.watch(clientSuffixProvider);
          return ListView(children: [
            for (final d in rows) _HistoryRow(d: d, tc: tc, suffix: suffix),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(children: [
                _sumRow(context, 'Deposit', money(deposit), tc.up),
                _sumRow(context, 'Withdrawal', money(withdrawal), withdrawal < 0 ? tc.down : null),
                _sumRow(context, 'Profit', money(profit), profit >= 0 ? tc.up : tc.down),
                _sumRow(context, 'Swap', money(swap), null),
                _sumRow(context, 'Commission', money(commission), commission < 0 ? tc.down : null),
                const SizedBox(height: 4),
                _sumRow(context, 'Balance', money(balance), null, bold: true),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _sumRow(BuildContext context, String k, String v, Color? color, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontSize: 14)),
          Text(v,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.d, required this.tc, required this.suffix});
  final Deal d;
  final String suffix;
  final TradeColors tc;

  @override
  Widget build(BuildContext context) {
    final faint = Theme.of(context).hintColor;
    final ts = dateTime(d.createdAt);

    if (d.isTrade) {
      final side = (d.side ?? '').toLowerCase();
      final pl = d.profit;
      final entryExit =
          '${d.openPrice != null ? price(d.openPrice!, d.digits) : '—'} → ${d.price != null ? price(d.price!, d.digits) : '—'}';
      return ListTile(
        dense: true,
        title: Row(children: [
          Text(d.symbol == null ? '—' : symbolDisplay(d.symbol!, suffix), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(width: 6),
          Text('$side ${d.volume?.toStringAsFixed(2) ?? ''}',
              style: TextStyle(color: side == 'buy' ? tc.up : tc.down, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
        subtitle: Text(entryExit, style: TextStyle(fontSize: 11.5, color: faint, fontFeatures: const [FontFeature.tabularFigures()])),
        trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.up : tc.down, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
          Text(ts, style: TextStyle(fontSize: 10.5, color: faint)),
        ]),
      );
    }

    final amt = d.amount;
    return ListTile(
      dense: true,
      title: const Text('Balance', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      subtitle: Text(d.comment ?? d.type, style: TextStyle(fontSize: 11.5, color: faint)),
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(money(amt), style: TextStyle(color: amt >= 0 ? tc.up : tc.down, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
        Text(ts, style: TextStyle(fontSize: 10.5, color: faint)),
      ]),
    );
  }
}
