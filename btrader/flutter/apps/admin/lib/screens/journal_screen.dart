import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

final _ts = DateFormat('MMM d, HH:mm:ss'); // exact time with seconds

/// One client account's trade journal: every order (requested vs executed price,
/// slippage, exact time) and closed trades with realised P&L.
final _ordersProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, accountId) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/orders', query: {'accountId': accountId}) as List;
});

final _dealsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, accountId) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/history/deals', query: {'accountId': accountId}) as List;
});

class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key, required this.accountId, this.login});
  final String accountId;
  final String? login;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final symbols = ref.watch(adminSymbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final byId = {for (final s in symbols) s.id: s};
    final orders = ref.watch(_ordersProvider(accountId));
    final deals = ref.watch(_dealsProvider(accountId));

    double? d(dynamic v) => v == null ? null : double.tryParse(v.toString());
    String px(dynamic v, int digits) => d(v) == null ? '—' : d(v)!.toStringAsFixed(digits);

    return AdminPage(
      title: 'Trade Journal${login != null ? ' — #$login' : ''}',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: () {
            ref.invalidate(_ordersProvider(accountId));
            ref.invalidate(_dealsProvider(accountId));
          },
        ),
      ],
      child: ListView(padding: const EdgeInsets.all(4), children: [
        _sectionTitle(context, 'ORDERS — requested vs executed'),
        orders.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _err(context, e),
          data: (rows) => rows.isEmpty
              ? _empty(context, 'No orders for this account.')
              : _wrap(SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 22,
                    headingRowHeight: 34,
                    dataRowMinHeight: 30,
                    dataRowMaxHeight: 34,
                    columns: const [
                      DataColumn(label: Text('TIME')),
                      DataColumn(label: Text('SYMBOL')),
                      DataColumn(label: Text('SIDE')),
                      DataColumn(label: Text('TYPE')),
                      DataColumn(label: Text('VOL'), numeric: true),
                      DataColumn(label: Text('REQUESTED'), numeric: true),
                      DataColumn(label: Text('EXECUTED'), numeric: true),
                      DataColumn(label: Text('SLIP (pts)'), numeric: true),
                      DataColumn(label: Text('STATUS')),
                      DataColumn(label: Text('SOURCE')),
                    ],
                    rows: [
                      for (final o in rows)
                        () {
                          final m = o as Map;
                          final sym = byId[m['symbolId']];
                          final digits = sym?.digits ?? 5;
                          final req = d(m['requestedPrice']);
                          final exe = d(m['avgFillPrice']);
                          final side = '${m['side']}';
                          final slipPts = (req != null && exe != null)
                              ? ((exe - req) * _pow10(digits)).roundToDouble()
                              : null;
                          return DataRow(cells: [
                            DataCell(Text(_fmt(m['createdAt']))),
                            DataCell(Text(sym?.symbol ?? '—')),
                            DataCell(Text(side, style: TextStyle(color: side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600))),
                            DataCell(Text('${m['type']}')),
                            DataCell(Text((d(m['volume']) ?? 0).toStringAsFixed(2))),
                            DataCell(Text(px(m['requestedPrice'], digits))),
                            DataCell(Text(px(m['avgFillPrice'], digits), style: const TextStyle(fontWeight: FontWeight.w600))),
                            DataCell(Text(slipPts == null ? '—' : slipPts.toStringAsFixed(0),
                                style: TextStyle(color: slipPts == null || slipPts == 0 ? null : (slipPts > 0 ? tc.loss : tc.profit)))),
                            DataCell(_statusChip(context, '${m['status']}', tc)),
                            DataCell(Text('${m['source'] ?? ''}', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor))),
                          ]);
                        }(),
                    ],
                  ),
                )),
        ),
        const SizedBox(height: 24),
        _sectionTitle(context, 'CLOSED TRADES — realised P&L'),
        deals.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _err(context, e),
          data: (rows) {
            final closed = rows.where((r) => (r as Map)['type'] == 'CLOSE' || r['type'] == 'PARTIAL_CLOSE').toList();
            return closed.isEmpty
                ? _empty(context, 'No closed trades yet.')
                : _wrap(SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 22,
                      headingRowHeight: 34,
                      dataRowMinHeight: 30,
                      dataRowMaxHeight: 34,
                      columns: const [
                        DataColumn(label: Text('TIME')),
                        DataColumn(label: Text('SYMBOL')),
                        DataColumn(label: Text('SIDE')),
                        DataColumn(label: Text('VOL'), numeric: true),
                        DataColumn(label: Text('ENTRY'), numeric: true),
                        DataColumn(label: Text('EXIT'), numeric: true),
                        DataColumn(label: Text('P/L'), numeric: true),
                      ],
                      rows: [
                        for (final r in closed)
                          () {
                            final m = r as Map;
                            final digits = (m['digits'] ?? 5) as int;
                            final pl = d(m['profit']) ?? 0;
                            final side = '${m['side']}';
                            return DataRow(cells: [
                              DataCell(Text(_fmt(m['createdAt']))),
                              DataCell(Text('${m['symbol'] ?? '—'}')),
                              DataCell(Text(side, style: TextStyle(color: side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600))),
                              DataCell(Text((d(m['volume']) ?? 0).toStringAsFixed(2))),
                              DataCell(Text(px(m['openPrice'], digits))),
                              DataCell(Text(px(m['price'], digits))),
                              DataCell(Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss, fontWeight: FontWeight.w600))),
                            ]);
                          }(),
                      ],
                    ),
                  ));
          },
        ),
        const SizedBox(height: 24),
      ]),
    );
  }

  static double _pow10(int n) => List.filled(n, 10).fold(1.0, (a, b) => a * b);
  static String _fmt(dynamic iso) {
    final t = DateTime.tryParse('${iso ?? ''}');
    return t == null ? '—' : _ts.format(t.toLocal());
  }

  Widget _sectionTitle(BuildContext c, String s) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(s, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Theme.of(c).hintColor)),
      );

  Widget _wrap(Widget child) => Card(margin: EdgeInsets.zero, child: Padding(padding: const EdgeInsets.all(4), child: child));

  Widget _empty(BuildContext c, String s) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text(s, style: TextStyle(color: Theme.of(c).hintColor))));

  Widget _err(BuildContext c, Object e) =>
      Padding(padding: const EdgeInsets.all(16), child: Text('$e'.split('\n').first, style: TextStyle(color: Theme.of(c).colorScheme.error)));

  Widget _statusChip(BuildContext c, String s, TradeColors tc) {
    final color = switch (s) {
      'FILLED' => tc.profit,
      'PENDING' => Colors.orange,
      'CANCELLED' || 'REJECTED' || 'EXPIRED' => tc.loss,
      _ => Theme.of(c).hintColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
      child: Text(s, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
