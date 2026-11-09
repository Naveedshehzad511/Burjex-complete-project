import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import 'account_detail_screen.dart' as acct show accountPositionsProvider, accountLiveWatchProvider;

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

/// The client IP recorded at each trade open / close (admin-only endpoint). Recorded from the
/// trade request itself; trades from before recording started have none ("Not available").
final _ipsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, accountId) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/history/trade-ips', query: {'accountId': accountId}) as List;
});

const _na = 'Not available';

/// Open IP of a position: the OPEN event for it.
String _openIp(List<dynamic> ips, dynamic positionId) {
  for (final r in ips) {
    if (r['kind'] == 'OPEN' && r['positionId'] == positionId && positionId != null) return '${r['ip']}';
  }
  return _na;
}

/// Close IP of a closed-trade row: the CLOSE event for its position nearest the deal's time
/// (a position closed in parts has one per part).
String _closeIp(List<dynamic> ips, dynamic positionId, dynamic dealAt) {
  final t = DateTime.tryParse('${dealAt ?? ''}');
  String? best;
  int? bestGap; // no `1 << 62` start: on the web a shift is 32-bit and that is 0
  for (final r in ips) {
    if (r['kind'] != 'CLOSE' || r['positionId'] != positionId || positionId == null) continue;
    final at = DateTime.tryParse('${r['at'] ?? ''}');
    final gap = (t == null || at == null) ? 0 : at.difference(t).inMilliseconds.abs();
    if (bestGap == null || gap < bestGap) { bestGap = gap; best = '${r['ip']}'; }
  }
  // More than a minute apart is a different close (e.g. a later SL/TP): not this one.
  return best != null && bestGap! <= 60000 ? best : _na;
}

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
    final ips = ref.watch(_ipsProvider(accountId)).valueOrNull ?? const [];
    // Open trades: the same account-scoped list the Account page uses (refetched every 2s),
    // with live P/L pushed over the socket and the live price from the quote stream.
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    ref.watch(acct.accountLiveWatchProvider(accountId));
    final open = ref.watch(acct.accountPositionsProvider(accountId));
    final livePL = ref.watch(livePositionProvider);
    final quotes = ref.watch(quotesProvider);
    // A position opened or closed: reload Orders and Closed Trades so it moves across at once.
    ref.listen(acct.accountPositionsProvider(accountId), (prev, next) {
      final a = prev?.valueOrNull?.map((p) => '${p['id']}:${p['volume']}').toSet();
      final b = next.valueOrNull?.map((p) => '${p['id']}:${p['volume']}').toSet();
      if (a != null && b != null && (a.length != b.length || !a.containsAll(b))) {
        ref.invalidate(_ordersProvider(accountId));
        ref.invalidate(_dealsProvider(accountId));
        ref.invalidate(_ipsProvider(accountId));
      }
    });

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
            ref.invalidate(acct.accountPositionsProvider(accountId));
            ref.invalidate(_ipsProvider(accountId));
          },
        ),
      ],
      child: ListView(padding: const EdgeInsets.all(4), children: [
        _sectionTitle(context, 'OPEN TRADES (LIVE)'),
        open.when(
          skipLoadingOnReload: true, // no spinner flash on each refetch
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _err(context, e),
          data: (rows) => rows.isEmpty
              ? _empty(context, 'No open trades on this account.')
              : _wrap(SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 22,
                    headingRowHeight: 34,
                    dataRowMinHeight: 30,
                    dataRowMaxHeight: 34,
                    columns: const [
                      DataColumn(label: Text('OPEN TIME')),
                      DataColumn(label: Text('SYMBOL')),
                      DataColumn(label: Text('SIDE')),
                      DataColumn(label: Text('VOL'), numeric: true),
                      DataColumn(label: Text('ENTRY'), numeric: true),
                      DataColumn(label: Text('CURRENT'), numeric: true),
                      DataColumn(label: Text('SL'), numeric: true),
                      DataColumn(label: Text('TP'), numeric: true),
                      DataColumn(label: Text('FLOATING P/L'), numeric: true),
                      DataColumn(label: Text('STATUS')),
                      DataColumn(label: Text('OPEN IP')),
                      DataColumn(label: Text('CLOSE IP')),
                    ],
                    rows: [
                      for (final p in rows)
                        () {
                          final m = p as Map;
                          final s = m['symbol'];
                          final name = s is Map ? '${s['symbol']}' : '${s ?? '—'}';
                          final digits = s is Map ? (s['digits'] ?? 5) as int : (byId[m['symbolId']]?.digits ?? 5);
                          final side = '${m['side']}';
                          final q = quotes[name];
                          // A BUY closes at the Bid, a SELL at the Ask (same rule as the apps).
                          final cur = q == null ? null : (side == 'BUY' ? q.bid : q.ask);
                          final pl = livePL[m['id']] ?? d(m['profit']);
                          return DataRow(cells: [
                            DataCell(Text(_fmt(m['openedAt']))),
                            DataCell(Text(name)),
                            DataCell(Text(side, style: TextStyle(color: side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600))),
                            DataCell(Text((d(m['volume']) ?? 0).toStringAsFixed(2))),
                            DataCell(Text(px(m['openPrice'], digits))),
                            DataCell(Text(cur == null ? '—' : cur.toStringAsFixed(digits), style: const TextStyle(fontWeight: FontWeight.w600))),
                            DataCell(Text(px(m['slPrice'], digits))),
                            DataCell(Text(px(m['tpPrice'], digits))),
                            DataCell(Text(pl == null ? '—' : money(pl),
                                style: TextStyle(color: pl == null || pl == 0 ? null : (pl > 0 ? tc.profit : tc.loss), fontWeight: FontWeight.w600))),
                            DataCell(_statusChip(context, 'OPEN', tc)),
                            DataCell(_ip(context, _openIp(ips, m['id']))),
                            DataCell(_ip(context, 'Pending')),
                          ]);
                        }(),
                    ],
                  ),
                )),
        ),
        const SizedBox(height: 24),
        _sectionTitle(context, 'HISTORY SUMMARY'),
        deals.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => _err(context, e),
          data: (rows) {
            // Same deals and the same rule as the app's History tab (historyTotals in btrader_core).
            final t = historyTotals([for (final r in rows) Deal.fromJson(Map<String, dynamic>.from(r as Map))]);
            Widget row(String k, double v, Color? color, {bool bold = false}) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
                    Text(money(v), style: TextStyle(color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
                  ]),
                );
            Color? sign(double v) => v > 0 ? tc.profit : (v < 0 ? tc.loss : null);
            return Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _wrap(Column(children: [
                  row('Deposit', t.deposit, sign(t.deposit)),
                  row('Withdrawal', t.withdrawal, sign(t.withdrawal)),
                  row('Profit', t.profit, sign(t.profit)),
                  row('Swap', t.swap, sign(t.swap)),
                  row('Commission', t.commission, sign(t.commission)),
                  const Divider(height: 8),
                  row('Balance', t.balance, null, bold: true),
                ])),
              ),
            );
          },
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
                : _box(SingleChildScrollView(
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
                        DataColumn(label: Text('OPEN IP')),
                        DataColumn(label: Text('CLOSE IP')),
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
                              DataCell(_ip(context, _openIp(ips, m['positionId']))),
                              DataCell(_ip(context, _closeIp(ips, m['positionId'], m['createdAt']))),
                            ]);
                          }(),
                      ],
                    ),
                  ));
          },
        ),
        const SizedBox(height: 24),
        _sectionTitle(context, 'ORDERS — requested vs executed'),
        orders.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _err(context, e),
          data: (rows) => rows.isEmpty
              ? _empty(context, 'No orders for this account.')
              : _box(SingleChildScrollView(
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

  Widget _ip(BuildContext c, String s) => s == _na || s == 'Pending'
      ? Text(s, style: TextStyle(fontSize: 12, color: Theme.of(c).hintColor))
      : SelectableText(s, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'));

  /// A long list in a box of about 12 rows; the rest scrolls inside it, not the whole page.
  Widget _box(Widget child) => _wrap(ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 34.0 + 12 * 34 + 8),
        child: SingleChildScrollView(primary: false, child: child),
      ));

  Widget _wrap(Widget child) => Card(margin: EdgeInsets.zero, child: Padding(padding: const EdgeInsets.all(4), child: child));

  Widget _empty(BuildContext c, String s) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text(s, style: TextStyle(color: Theme.of(c).hintColor))));

  Widget _err(BuildContext c, Object e) =>
      Padding(padding: const EdgeInsets.all(16), child: Text('$e'.split('\n').first, style: TextStyle(color: Theme.of(c).colorScheme.error)));

  Widget _statusChip(BuildContext c, String s, TradeColors tc) {
    final color = switch (s) {
      'FILLED' || 'OPEN' => tc.profit,
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
