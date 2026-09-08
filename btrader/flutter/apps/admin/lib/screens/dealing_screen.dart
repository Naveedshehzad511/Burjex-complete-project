import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

/// Dealing desk styled after the MT5 Manager terminal: dense data grids, tabbed
/// sections, tabular blue/red numerics. Assign clients A (STP) or B (warehouse),
/// monitor net exposure, watch the A-book cover blotter, configure the LP bridge.
class DealingScreen extends ConsumerWidget {
  const DealingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminPage(
      title: 'Dealing Desk — A / B Book',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: () {
            ref.invalidate(bookExposureProvider);
            ref.invalidate(hedgeBlotterProvider);
            ref.invalidate(lpConfigProvider);
            ref.invalidate(lpVenuesProvider);
            ref.invalidate(routingRulesProvider);
            ref.invalidate(clientsProvider);
          },
        ),
      ],
      child: DefaultTabController(
        length: 7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: const TabBar(
              isScrollable: true,
              labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              tabs: [
                Tab(height: 38, child: _TabLabel(Icons.pie_chart_outline, 'Exposure')),
                Tab(height: 38, child: _TabLabel(Icons.people_outline, 'Clients')),
                Tab(height: 38, child: _TabLabel(Icons.alt_route, 'Routing Rules')),
                Tab(height: 38, child: _TabLabel(Icons.swap_horiz, 'A-book Covers')),
                Tab(height: 38, child: _TabLabel(Icons.account_balance_outlined, 'Net Hedge')),
                Tab(height: 38, child: _TabLabel(Icons.hub_outlined, 'LP Venues')),
                Tab(height: 38, child: _TabLabel(Icons.newspaper_outlined, 'News')),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(children: [
              _ExposureTab(),
              _ClientsTab(),
              _RoutingTab(),
              _CoversTab(),
              _NetHedgeTab(),
              _LpBridgeTab(),
              _NewsTab(),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(label)]);
}

// ═══════════════════════════════════════════════════════════════════════════
//  MT5-style dense grid primitives
// ═══════════════════════════════════════════════════════════════════════════

/// A compact, terminal-style data grid with tight rows, zebra striping and a
/// tinted header — the MT5 Manager "blotter" look.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.rows});
  final List<DataColumn> columns;
  final List<DataRow> rows;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerBg = isDark ? const Color(0xFF131C2E) : const Color(0xFFEDF1F7);
    final line = Theme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 30,
          dataRowMaxHeight: 34,
          horizontalMargin: 12,
          columnSpacing: 26,
          dividerThickness: 0.4,
          headingRowColor: WidgetStateProperty.all(headerBg),
          headingTextStyle: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: Theme.of(context).hintColor,
          ),
          dataTextStyle: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
          columns: columns,
          rows: rows,
        ),
      ),
    );
  }
}

DataRow _zebra(int i, BuildContext context, List<DataCell> cells) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final alt = isDark ? const Color(0x0AFFFFFF) : const Color(0x05000000);
  return DataRow(
    color: WidgetStateProperty.all(i.isOdd ? alt : null),
    cells: cells,
  );
}

/// Small KPI tile — MT5 status-strip style.
class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.color, this.alert = false});
  final String label;
  final String value;
  final Color? color;
  final bool alert;
  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).dividerColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: alert ? const Color(0x14E5484D) : Theme.of(context).cardColor,
        border: Border.all(color: alert ? const Color(0x55E5484D) : line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label.toUpperCase(),
            style: TextStyle(fontSize: 10, letterSpacing: 0.4, color: Theme.of(context).hintColor)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

/// Compact inline error — replaces the giant Dio stack trace.
class _MiniError extends StatelessWidget {
  const _MiniError(this.error, {this.onRetry});
  final Object error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tc.loss.withValues(alpha: 0.08),
        border: Border.all(color: tc.loss.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, size: 16, color: tc.loss),
        const SizedBox(width: 8),
        Expanded(child: Text(_short(error), style: TextStyle(fontSize: 12.5, color: tc.loss))),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]),
    );
  }
}

String _short(Object e) {
  final s = e.toString();
  final m = RegExp(r'status code of (\d{3})').firstMatch(s);
  if (m != null) {
    final code = m.group(1);
    return switch (code) {
      '401' => 'Session expired — sign out and back in.',
      '403' => 'Not permitted for this role.',
      '404' => 'Endpoint not found — backend may need a redeploy.',
      _ => 'Request failed (HTTP $code).',
    };
  }
  if (s.contains('SocketException') || s.contains('Connection')) return 'Cannot reach the server.';
  return 'Could not load data.';
}

double _d(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 1 — Exposure
// ═══════════════════════════════════════════════════════════════════════════
class _ExposureTab extends ConsumerWidget {
  const _ExposureTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exposure = ref.watch(bookExposureProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    return exposure.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: _MiniError(e, onRetry: () => ref.invalidate(bookExposureProvider)),
      ),
      data: (data) {
        final symbols = (data['symbols'] ?? []) as List;
        final housePL = _d(data['totalFloatingPL']);
        final pending = (data['hedgePending'] ?? 0) as int;
        final rejected = (data['hedgeRejected'] ?? 0) as int;
        return ListView(padding: const EdgeInsets.symmetric(vertical: 14), children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            _Kpi(label: 'Net notional (B)', value: money(_d(data['totalNetNotional']))),
            _Kpi(label: 'House floating P/L', value: money(housePL), color: housePL >= 0 ? tc.profit : tc.loss),
            _Kpi(label: 'A-book pos', value: '${data['aBookPositions'] ?? 0}', color: tc.up),
            _Kpi(label: 'B-book pos', value: '${data['bBookPositions'] ?? 0}'),
            _Kpi(label: 'Covers pending', value: '$pending', color: pending > 0 ? Colors.orange : null),
            _Kpi(label: 'Covers rejected', value: '$rejected', color: rejected > 0 ? tc.loss : null, alert: rejected > 0),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Text('WAREHOUSE (B) vs COVERED (A) EXPOSURE',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Theme.of(context).hintColor)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(context: context, builder: (_) => const _CoverMoreDialog());
                if (ok == true) {
                  ref.invalidate(bookExposureProvider);
                  ref.invalidate(hedgeBlotterProvider);
                }
              },
              icon: const Icon(Icons.shield_outlined, size: 16),
              label: const Text('Cover more (B → A)'),
            ),
          ]),
          const SizedBox(height: 8),
          if (symbols.isEmpty)
            _empty(context, 'No open exposure.')
          else
            _Grid(
              columns: const [
                DataColumn(label: Text('SYMBOL')),
                DataColumn(label: Text('LONG (B)'), numeric: true),
                DataColumn(label: Text('SHORT (B)'), numeric: true),
                DataColumn(label: Text('NET (B)'), numeric: true),
                DataColumn(label: Text('COVERED (A)'), numeric: true),
                DataColumn(label: Text('NET NOTIONAL'), numeric: true),
                DataColumn(label: Text('HOUSE P/L'), numeric: true),
              ],
              rows: [
                for (var i = 0; i < symbols.length; i++)
                  _exposureRow(context, i, symbols[i] as Map, tc),
              ],
            ),
        ]);
      },
    );
  }

  DataRow _exposureRow(BuildContext context, int i, Map s, TradeColors tc) {
    final net = _d(s['netLots']);
    final pl = _d(s['floatingPL']);
    return _zebra(i, context, [
      DataCell(Text('${s['symbol']}', style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text(_d(s['longLots']).toStringAsFixed(2))),
      DataCell(Text(_d(s['shortLots']).toStringAsFixed(2))),
      DataCell(Text(net.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.w700, color: net >= 0 ? tc.up : tc.down))),
      DataCell(Text(_d(s['coveredLots']).toStringAsFixed(2), style: TextStyle(color: tc.up))),
      DataCell(Text(money(_d(s['netNotional'])))),
      DataCell(Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss))),
    ]);
  }
}

/// Cover more lots of an open position (move warehoused B-book lots to A-book).
class _CoverMoreDialog extends ConsumerStatefulWidget {
  const _CoverMoreDialog();
  @override
  ConsumerState<_CoverMoreDialog> createState() => _CoverMoreDialogState();
}

class _CoverMoreDialogState extends ConsumerState<_CoverMoreDialog> {
  List<Map<String, dynamic>> _positions = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(apiClientProvider).get('/accounts/positions/all') as List;
      final rows = <Map<String, dynamic>>[];
      for (final p in list) {
        final m = Map<String, dynamic>.from(p as Map);
        final vol = _d(m['volume']);
        final cov = _d(m['coveredVolume']);
        if (vol - cov > 0.00001) rows.add(m); // only positions with warehoused lots
      }
      if (mounted) setState(() { _positions = rows; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cover(Map<String, dynamic> p, double lots) async {
    setState(() => _busyId = p['id'] as String);
    try {
      final res = await ref.read(apiClientProvider).put('/admin/book/positions/${p['id']}/cover', {'lots': lots});
      if (res is Map && res['error'] != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
      } else {
        await _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cover more (B → A)'),
      content: SizedBox(
        width: 520,
        height: 460,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _positions.isEmpty
                ? const Center(child: Text('No positions with warehoused (uncovered) lots.'))
                : ListView.separated(
                    itemCount: _positions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = _positions[i];
                      final vol = _d(p['volume']);
                      final cov = _d(p['coveredVolume']);
                      final wh = vol - cov;
                      final sym = (p['symbol'] is Map) ? (p['symbol'] as Map)['symbol'] : p['symbolName'];
                      final ctrl = TextEditingController(text: wh.toStringAsFixed(2));
                      return ListTile(
                        dense: true,
                        title: Text('$sym  ·  ${p['side']}  ${vol.toStringAsFixed(2)} lots'),
                        subtitle: Text('A ${cov.toStringAsFixed(2)} / B ${wh.toStringAsFixed(2)}'),
                        trailing: SizedBox(
                          width: 150,
                          child: Row(children: [
                            SizedBox(width: 64, child: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, labelText: 'lots'))),
                            const SizedBox(width: 6),
                            _busyId == p['id']
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : FilledButton(
                                    onPressed: () => _cover(p, double.tryParse(ctrl.text) ?? wh),
                                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                                    child: const Text('Cover'),
                                  ),
                          ]),
                        ),
                      );
                    },
                  ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 2 — Clients (book assignment)
// ═══════════════════════════════════════════════════════════════════════════
class _ClientsTab extends ConsumerWidget {
  const _ClientsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = ref.watch(clientsProvider);
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    Future<void> setBook(String accountId, String? book) async {
      try {
        await api.patch('/admin/book/accounts/$accountId', {'book': book});
        ref.invalidate(clientsProvider);
        ref.invalidate(bookExposureProvider);
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
      }
    }

    return clients.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: _MiniError(e, onRetry: () => ref.invalidate(clientsProvider))),
      data: (list) {
        final rows = <DataRow>[];
        var i = 0;
        for (final c in list) {
          for (final a in c.accounts) {
            rows.add(_zebra(i++, context, [
              DataCell(Text('#${a.login}', style: const TextStyle(fontWeight: FontWeight.w600))),
              DataCell(Text(c.name.isEmpty ? c.email : c.name)),
              DataCell(Text(money(a.balance))),
              DataCell(Text(money(a.liveEquity))),
              DataCell(_BookPicker(book: a.book, tc: tc, onSet: (b) => setBook(a.id, b))),
            ]));
          }
        }
        return ListView(padding: const EdgeInsets.symmetric(vertical: 14), children: [
          Text('CLIENT BOOK ASSIGNMENT',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Theme.of(context).hintColor)),
          const SizedBox(height: 8),
          rows.isEmpty
              ? _empty(context, 'No client accounts.')
              : _Grid(
                  columns: const [
                    DataColumn(label: Text('LOGIN')),
                    DataColumn(label: Text('CLIENT')),
                    DataColumn(label: Text('BALANCE'), numeric: true),
                    DataColumn(label: Text('EQUITY'), numeric: true),
                    DataColumn(label: Text('BOOK')),
                  ],
                  rows: rows,
                ),
        ]);
      },
    );
  }
}

/// Compact A / B / Inherit selector coloured like MT5 (A=blue, B=amber).
class _BookPicker extends StatelessWidget {
  const _BookPicker({required this.book, required this.tc, required this.onSet});
  final String? book;
  final TradeColors tc;
  final void Function(String? book) onSet;

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, String? value, Color active) {
      final selected = (book ?? 'INHERIT') == (value ?? 'INHERIT');
      return InkWell(
        onTap: () => onSet(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          color: selected ? active.withValues(alpha: 0.16) : Colors.transparent,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? active : Theme.of(context).hintColor)),
        ),
      );
    }

    final line = Theme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: line), borderRadius: BorderRadius.circular(5)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('A', 'A', tc.up),
        Container(width: 0.5, height: 22, color: line),
        seg('B', 'B', Colors.orange.shade700),
        Container(width: 0.5, height: 22, color: line),
        seg('Inherit', null, Theme.of(context).colorScheme.primary),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 3 — A-book covers (hedge blotter)
// ═══════════════════════════════════════════════════════════════════════════
class _CoversTab extends ConsumerWidget {
  const _CoversTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blotter = ref.watch(hedgeBlotterProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Color statusColor(String s) => switch (s) {
          'FILLED' => tc.profit,
          'CLOSED' => Theme.of(context).hintColor,
          'PENDING' => Colors.orange,
          _ => tc.loss,
        };

    return blotter.when(
      // Keep the table rendered during the 2s live reload — only the values
      // refresh in place (no full-page spinner flicker).
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: _MiniError(e, onRetry: () => ref.invalidate(hedgeBlotterProvider))),
      data: (rows) => ListView(padding: const EdgeInsets.symmetric(vertical: 14), children: [
        Text('A-BOOK COVER BLOTTER',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Theme.of(context).hintColor)),
        const SizedBox(height: 8),
        rows.isEmpty
            ? _empty(context, 'No A-book covers yet. Set a client to book A and trade.')
            : _Grid(
                columns: const [
                  DataColumn(label: Text('SYMBOL')),
                  DataColumn(label: Text('SIDE')),
                  DataColumn(label: Text('VOL'), numeric: true),
                  DataColumn(label: Text('REQ PX'), numeric: true),
                  DataColumn(label: Text('FILL PX'), numeric: true),
                  DataColumn(label: Text('SLIP'), numeric: true),
                  DataColumn(label: Text('LP')),
                  DataColumn(label: Text('DRIVER')),
                  DataColumn(label: Text('STATUS')),
                ],
                rows: [
                  for (var i = 0; i < rows.length; i++)
                    _coverRow(context, i, rows[i] as Map, tc, statusColor),
                ],
              ),
      ]),
    );
  }

  DataRow _coverRow(BuildContext context, int i, Map h, TradeColors tc, Color Function(String) statusColor) {
    final side = '${h['side']}';
    final st = '${h['status']}';
    return _zebra(i, context, [
      DataCell(Text('${h['symbol']}', style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text(side, style: TextStyle(fontWeight: FontWeight.w600, color: side == 'BUY' ? tc.up : tc.down))),
      DataCell(Text(_d(h['volume']).toStringAsFixed(2))),
      DataCell(Text('${h['requestPrice'] ?? '—'}')),
      DataCell(Text('${h['fillPrice'] ?? '—'}')),
      DataCell(Text(_d(h['slippage']).toStringAsFixed(5))),
      DataCell(Text('${h['lpProviderCode'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text('${h['driver']}', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor))),
      DataCell(_pill(st, statusColor(st))),
    ]);
  }

  Widget _pill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Shared LP-venue helpers
// ═══════════════════════════════════════════════════════════════════════════
const List<String> _lpDrivers = ['MT5', 'PRIMEXM', 'CENTROID', 'ONEZERO', 'MOCK'];
String _driverLabel(String d) {
  switch (d) {
    case 'MT5':
      return 'MT5 Manager bridge';
    case 'PRIMEXM':
      return 'PrimeXM (FIX)';
    case 'CENTROID':
      return 'Centroid';
    case 'ONEZERO':
      return 'oneZero (FIX)';
    case 'MOCK':
      return 'Mock (simulated)';
    default:
      return d;
  }
}

const List<String> _instrumentClasses = [
  'FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM',
];

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 3 — Routing Rules (Group × Symbol/Class → book + LP venue)
// ═══════════════════════════════════════════════════════════════════════════
class _RoutingTab extends ConsumerWidget {
  const _RoutingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(routingRulesProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    return rules.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: _MiniError(e, onRetry: () => ref.invalidate(routingRulesProvider)),
      ),
      data: (list) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.alt_route, size: 18),
            const SizedBox(width: 8),
            const Text('Routing Rules', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => _openRuleDialog(context, ref, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add rule'),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Most-specific rule wins: symbol > trading group > class, ties broken by priority. '
            'Resolved book still yields to a symbol force-book; an A-book rule with no venue uses the tenant default.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 14),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No routing rules yet — orders fall back to account/group book + tenant default venue.',
                  style: TextStyle(color: Theme.of(context).hintColor)),
            )
          else
            _Grid(
              columns: const [
                DataColumn(label: Text('SCOPE — GROUP')),
                DataColumn(label: Text('INSTRUMENT')),
                DataColumn(label: Text('BOOK')),
                DataColumn(label: Text('LP VENUE')),
                DataColumn(label: Text('PRIORITY')),
                DataColumn(label: Text('STATUS')),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (var i = 0; i < list.length; i++)
                  _ruleRow(context, ref, i, list[i] as Map<String, dynamic>, tc),
              ],
            ),
          const SizedBox(height: 24),
          const _RoutingTestPanel(),
        ]),
      ),
    );
  }

  DataRow _ruleRow(BuildContext context, WidgetRef ref, int i, Map<String, dynamic> r, TradeColors tc) {
    final book = (r['book'] ?? 'B').toString();
    final enabled = r['enabled'] == true;
    return _zebra(i, context, [
      DataCell(Text((r['tradingGroupName'] ?? 'Any group').toString())),
      DataCell(Text(_instrumentLabel(r))),
      DataCell(Text(book, style: TextStyle(fontWeight: FontWeight.w700, color: book == 'A' ? tc.profit : tc.loss))),
      DataCell(Text(_venueLabel(r, book))),
      DataCell(Text('${r['priority'] ?? 0}')),
      DataCell(_pill(enabled ? 'ON' : 'OFF', enabled ? tc.profit : Theme.of(context).hintColor)),
      DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Edit',
          icon: const Icon(Icons.edit_outlined, size: 17),
          onPressed: () => _openRuleDialog(context, ref, r),
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline, size: 17),
          onPressed: () => _deleteRule(context, ref, r),
        ),
      ])),
    ]);
  }

  static String _instrumentLabel(Map<String, dynamic> r) {
    if (r['symbolName'] != null) return r['symbolName'].toString();
    if (r['instrumentClass'] != null) return 'Class: ${r['instrumentClass']}';
    return 'Any instrument';
  }

  static String _venueLabel(Map<String, dynamic> r, String book) {
    if (book != 'A') return '—';
    if ((r['venueMode'] ?? 'FIXED') == 'BEST_PRICE') return 'Best price';
    if (r['lpProviderCode'] != null) return r['lpProviderCode'].toString();
    if (r['lpDriver'] != null) return _driverLabel(r['lpDriver'].toString());
    return 'Tenant default';
  }

  static Widget _pill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Future<void> _openRuleDialog(BuildContext context, WidgetRef ref, Map<String, dynamic>? existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RuleDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(routingRulesProvider);
  }

  Future<void> _deleteRule(BuildContext context, WidgetRef ref, Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete routing rule?'),
        content: Text('Remove the rule for "${_instrumentLabel(r)}"? Orders will fall back to the next matching rule.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).delete('/admin/book/routing-rules/${r['id']}');
      ref.invalidate(routingRulesProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rule deleted')));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    }
  }
}

/// Add/edit dialog for a routing rule.
class _RuleDialog extends ConsumerStatefulWidget {
  const _RuleDialog({this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends ConsumerState<_RuleDialog> {
  String? _groupId;            // null = any group
  String _instrumentMode = 'ANY'; // ANY | CLASS | SYMBOL
  String? _symbolId;
  String _class = 'FOREX';
  String _book = 'B';
  String _venueMode = 'FIXED';   // FIXED | BEST_PRICE
  String? _lpProviderId;         // FIXED: specific provider; null = tenant default
  late final _coverage = TextEditingController(text: '100'); // % covered to LP (A-book partial)
  late final _priority = TextEditingController(text: '0');
  late final _desc = TextEditingController();
  bool _enabled = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _groupId = e['tradingGroupId'] as String?;
      if (e['symbolId'] != null) {
        _instrumentMode = 'SYMBOL';
        _symbolId = e['symbolId'] as String?;
      } else if (e['instrumentClass'] != null) {
        _instrumentMode = 'CLASS';
        _class = e['instrumentClass'].toString();
      }
      _book = (e['book'] ?? 'B').toString();
      _venueMode = (e['venueMode'] ?? 'FIXED').toString();
      _lpProviderId = e['lpProviderId'] as String?;
      _coverage.text = (e['coverageRatio'] ?? 100).toString();
      _priority.text = (e['priority'] ?? 0).toString();
      _desc.text = (e['description'] ?? '').toString();
      _enabled = e['enabled'] != false;
    }
  }

  @override
  void dispose() {
    _coverage.dispose();
    _priority.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(tradingGroupsProvider);
    final symbols = ref.watch(adminSymbolsProvider);
    InputDecoration dec(String l, {String? help}) =>
        InputDecoration(labelText: l, helperText: help, border: const OutlineInputBorder(), isDense: true);

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add routing rule' : 'Edit routing rule'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Trading group scope
            groups.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(_short(e), style: const TextStyle(fontSize: 12)),
              data: (list) => DropdownButtonFormField<String?>(
                initialValue: _groupId,
                decoration: dec('Trading group', help: 'Scope — leave as Any to match all groups'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Any group')),
                  for (final g in list)
                    DropdownMenuItem<String?>(value: (g as Map)['id'] as String, child: Text(g['name'].toString())),
                ],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ),
            const SizedBox(height: 14),
            // Instrument scope mode
            DropdownButtonFormField<String>(
              initialValue: _instrumentMode,
              decoration: dec('Instrument scope'),
              items: const [
                DropdownMenuItem(value: 'ANY', child: Text('Any instrument')),
                DropdownMenuItem(value: 'CLASS', child: Text('By class (e.g. METALS)')),
                DropdownMenuItem(value: 'SYMBOL', child: Text('Specific symbol')),
              ],
              onChanged: (v) => setState(() => _instrumentMode = v ?? 'ANY'),
            ),
            if (_instrumentMode == 'CLASS') ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _class,
                decoration: dec('Instrument class'),
                items: [for (final c in _instrumentClasses) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setState(() => _class = v ?? 'FOREX'),
              ),
            ],
            if (_instrumentMode == 'SYMBOL') ...[
              const SizedBox(height: 14),
              symbols.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text(_short(e), style: const TextStyle(fontSize: 12)),
                data: (list) => DropdownButtonFormField<String>(
                  initialValue: _symbolId,
                  isExpanded: true,
                  decoration: dec('Symbol'),
                  items: [
                    for (final s in list)
                      DropdownMenuItem(value: s.id, child: Text('${s.symbol}  ·  ${s.klass}')),
                  ],
                  onChanged: (v) => setState(() => _symbolId = v),
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Book
            Row(children: [
              const Text('Book', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'A', label: Text('A (cover to LP)')),
                  ButtonSegment(value: 'B', label: Text('B (warehouse)')),
                ],
                selected: {_book},
                onSelectionChanged: (s) => setState(() => _book = s.first),
              ),
            ]),
            const SizedBox(height: 14),
            // LP venue (only meaningful for A-book) — independent of pricing.
            if (_book == 'A') ...[
              Row(children: [
                const Text('Cover venue', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'FIXED', label: Text('Fixed LP')),
                    ButtonSegment(value: 'BEST_PRICE', label: Text('Best price')),
                  ],
                  selected: {_venueMode},
                  onSelectionChanged: (s) => setState(() => _venueMode = s.first),
                ),
              ]),
              if (_venueMode == 'FIXED') ...[
                const SizedBox(height: 12),
                Consumer(builder: (context, ref, _) {
                  final provs = ref.watch(liquidityProvidersProvider);
                  return provs.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text(_short(e), style: const TextStyle(fontSize: 12)),
                    data: (list) => DropdownButtonFormField<String?>(
                      initialValue: _lpProviderId,
                      isExpanded: true,
                      decoration: dec('Cover at provider', help: 'Where the A-book cover executes (can differ from the priced LP)'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('Tenant default venue')),
                        for (final p in list)
                          DropdownMenuItem<String?>(
                            value: (p as Map)['id'] as String,
                            child: Text('${p['code']} · ${p['name']}'),
                          ),
                      ],
                      onChanged: (v) => setState(() => _lpProviderId = v),
                    ),
                  );
                }),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Covers route to whichever LP is currently pricing the symbol (active source).',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _coverage,
                keyboardType: TextInputType.number,
                decoration: dec('Coverage %',
                    help: '% of each A-book order covered to the LP at open (100 = full STP; e.g. 70 → 70% A, 30% warehoused). Cover the rest later from the Exposure tab.'),
              ),
              const SizedBox(height: 14),
            ],
            Row(children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _priority,
                  keyboardType: TextInputType.number,
                  decoration: dec('Priority'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Enabled'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(controller: _desc, decoration: dec('Description (optional)')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_instrumentMode == 'SYMBOL' && _symbolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a symbol')));
      return;
    }
    setState(() => _busy = true);
    final body = {
      'tradingGroupId': _groupId,
      'symbolId': _instrumentMode == 'SYMBOL' ? _symbolId : null,
      'instrumentClass': _instrumentMode == 'CLASS' ? _class : null,
      'book': _book,
      'venueMode': _book == 'A' ? _venueMode : 'FIXED',
      'lpProviderId': _book == 'A' && _venueMode == 'FIXED' ? _lpProviderId : null,
      'coverageRatio': _book == 'A' ? (int.tryParse(_coverage.text) ?? 100) : 100,
      'priority': int.tryParse(_priority.text) ?? 0,
      'enabled': _enabled,
      'description': _desc.text.isEmpty ? null : _desc.text,
    };
    try {
      final api = ref.read(apiClientProvider);
      final id = widget.existing?['id'];
      final res = id == null
          ? await api.post('/admin/book/routing-rules', body)
          : await api.put('/admin/book/routing-rules/$id', body);
      if (res is Map && res['error'] != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
        setState(() => _busy = false);
        return;
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
      setState(() => _busy = false);
    }
  }
}

/// "Which rule applies" preview: pick a group + symbol, resolve book + venue.
class _RoutingTestPanel extends ConsumerStatefulWidget {
  const _RoutingTestPanel();
  @override
  ConsumerState<_RoutingTestPanel> createState() => _RoutingTestPanelState();
}

class _RoutingTestPanelState extends ConsumerState<_RoutingTestPanel> {
  String? _groupId;
  String? _symbolId;
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(tradingGroupsProvider);
    final symbols = ref.watch(adminSymbolsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final line = Theme.of(context).dividerColor;
    InputDecoration dec(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder(), isDense: true);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.science_outlined, size: 18),
          SizedBox(width: 8),
          Text('Test which rule applies', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 220,
            child: groups.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(_short(e), style: const TextStyle(fontSize: 12)),
              data: (list) => DropdownButtonFormField<String?>(
                initialValue: _groupId,
                decoration: dec('Trading group'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Any / none')),
                  for (final g in list)
                    DropdownMenuItem<String?>(value: (g as Map)['id'] as String, child: Text(g['name'].toString())),
                ],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ),
          ),
          SizedBox(
            width: 240,
            child: symbols.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(_short(e), style: const TextStyle(fontSize: 12)),
              data: (list) => DropdownButtonFormField<String>(
                initialValue: _symbolId,
                isExpanded: true,
                decoration: dec('Symbol'),
                items: [
                  for (final s in list) DropdownMenuItem(value: s.id, child: Text('${s.symbol}  ·  ${s.klass}')),
                ],
                onChanged: (v) => setState(() => _symbolId = v),
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: _busy || _symbolId == null ? null : _run,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow, size: 18),
            label: const Text('Resolve'),
          ),
        ]),
        if (_result != null) ...[
          const SizedBox(height: 14),
          Builder(builder: (context) {
            final r = _result!;
            final book = (r['book'] ?? 'B').toString();
            final venueCode = r['lpProviderCode'];
            final venueDriver = r['lpDriver'];
            final venueStr = venueCode != null
                ? venueCode.toString()
                : venueDriver != null
                    ? _driverLabel(venueDriver.toString())
                    : 'none (broker exposed)';
            final matched = r['matchedRuleId'];
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (book == 'A' ? tc.profit : tc.loss).withValues(alpha: 0.06),
                border: Border.all(color: (book == 'A' ? tc.profit : tc.loss).withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('Book $book',
                      style: TextStyle(fontWeight: FontWeight.w700, color: book == 'A' ? tc.profit : tc.loss)),
                  const SizedBox(width: 18),
                  Text(book == 'A' ? 'Cover: $venueStr' : 'Cover: — (warehoused)'),
                  const Spacer(),
                  Text(matched == null ? 'no rule matched' : 'matched rule',
                      style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
                ]),
                const SizedBox(height: 6),
                Text((r['reason'] ?? '').toString(), style: const TextStyle(fontSize: 12.5)),
              ]),
            );
          }),
        ],
      ]),
    );
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).post('/admin/book/routing-rules/test', {
        'tradingGroupId': _groupId,
        'symbolId': _symbolId,
      });
      if (mounted) {
        setState(() => _result = res is Map ? Map<String, dynamic>.from(res) : null);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 6 — LP venues (multi-venue config)
// ═══════════════════════════════════════════════════════════════════════════
class _LpBridgeTab extends ConsumerWidget {
  const _LpBridgeTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venues = ref.watch(lpVenuesProvider);
    return venues.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: _MiniError(e, onRetry: () => ref.invalidate(lpVenuesProvider)),
      ),
      data: (list) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.hub_outlined, size: 18),
              const SizedBox(width: 8),
              const Text('A-book LP venues', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _addVenue(context, ref, list),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add venue'),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              'Configure one venue per LP driver. Routing rules pick which venue covers an A-book order; '
              'the venue marked default covers any A-book order whose rule sets no venue. '
              'No enabled venue for a flow = broker exposed (alerts raised).',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 16),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('No LP venues configured yet.', style: TextStyle(color: Theme.of(context).hintColor)),
              )
            else
              for (final v in list) ...[
                _LpForm(initial: Map<String, dynamic>.from(v as Map), isNew: false),
                const SizedBox(height: 16),
              ],
          ]),
        ),
      ),
    );
  }

  Future<void> _addVenue(BuildContext context, WidgetRef ref, List<dynamic> existing) async {
    // Multiple same-driver venues are allowed (distinguished by provider), so
    // every driver stays selectable.
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _LpForm(initial: const {'driver': 'MT5'}, isNew: true, availableDrivers: _lpDrivers.toList()),
          ),
        ),
      ),
    );
  }
}

class _LpForm extends ConsumerStatefulWidget {
  const _LpForm({required this.initial, required this.isNew, this.availableDrivers});
  final Map<String, dynamic> initial;
  final bool isNew;
  final List<String>? availableDrivers; // selectable drivers when adding a new venue
  @override
  ConsumerState<_LpForm> createState() => _LpFormState();
}

class _LpFormState extends ConsumerState<_LpForm> {
  late String _driver = (widget.initial['driver'] ?? 'MOCK').toString();
  late bool _enabled = widget.initial['enabled'] == true;
  late bool _isDefault = widget.initial['isDefault'] == true;
  late String? _lpProviderId = widget.initial['lpProviderId'] as String?;
  late final _label = TextEditingController(text: widget.initial['label']?.toString() ?? '');
  late final _coverLogin = TextEditingController(text: widget.initial['coverLogin']?.toString() ?? '');
  late final _endpoint = TextEditingController(text: widget.initial['endpoint']?.toString() ?? '');
  late final _sender = TextEditingController(text: widget.initial['senderCompId']?.toString() ?? '');
  late final _target = TextEditingController(text: widget.initial['targetCompId']?.toString() ?? '');
  late final _credRef = TextEditingController(text: widget.initial['credentialRef']?.toString() ?? '');
  late final _slip = TextEditingController(text: (widget.initial['simSlippageBps'] ?? 0).toString());
  late final _reject = TextEditingController(text: (widget.initial['simRejectPct'] ?? 0).toString());
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    _coverLogin.dispose();
    _endpoint.dispose();
    _sender.dispose();
    _target.dispose();
    _credRef.dispose();
    _slip.dispose();
    _reject.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMock = _driver == 'MOCK';
    final isMt5 = _driver == 'MT5';
    final tc = Theme.of(context).extension<TradeColors>()!;
    final line = Theme.of(context).dividerColor;
    InputDecoration dec(String l, {String? help}) =>
        InputDecoration(labelText: l, helperText: help, border: const OutlineInputBorder(), isDense: true);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.hub_outlined, size: 18),
          const SizedBox(width: 8),
          Text(widget.isNew ? 'New LP venue' : _driverLabel(_driver),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          if (_isDefault) ...[
            const SizedBox(width: 8),
            _statusPill('DEFAULT', Theme.of(context).colorScheme.primary),
          ],
          const Spacer(),
          _statusPill(_enabled ? 'ENABLED' : 'DISABLED', _enabled ? tc.profit : tc.loss),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              initialValue: _driver,
              decoration: dec('Driver'),
              items: [
                for (final d in (widget.isNew ? (widget.availableDrivers ?? _lpDrivers) : [_driver]))
                  DropdownMenuItem(value: d, child: Text(_driverLabel(d))),
              ],
              onChanged: widget.isNew ? (v) => setState(() => _driver = v ?? 'MOCK') : null,
            ),
          ),
          SizedBox(width: 220, child: TextField(controller: _label, decoration: dec('Label (optional)'))),
          SizedBox(
            width: 200,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Routing enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ),
          SizedBox(
            width: 200,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Default venue'),
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        // Link this execution venue to a liquidity provider so routing rules can
        // fix covers to it (two same-driver LPs stay distinct).
        Consumer(builder: (context, ref, _) {
          final provs = ref.watch(liquidityProvidersProvider);
          return provs.when(
            loading: () => const SizedBox.shrink(),
            error: (e, _) => const SizedBox.shrink(),
            data: (list) => SizedBox(
              width: 460,
              child: DropdownButtonFormField<String?>(
                initialValue: _lpProviderId,
                isExpanded: true,
                decoration: dec('Liquidity provider', help: 'Which LP this venue executes for (optional for legacy driver-level venues)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('None (tenant-level, by driver)')),
                  for (final p in list)
                    DropdownMenuItem<String?>(value: (p as Map)['id'] as String, child: Text('${p['code']} · ${p['name']}')),
                ],
                onChanged: (v) => setState(() => _lpProviderId = v),
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        if (isMt5) ...[
          SizedBox(width: 280, child: TextField(controller: _coverLogin, keyboardType: TextInputType.number, decoration: dec('MT5 cover login (optional)', help: 'Display only — the bridge config Mt5CoverLogin is authoritative'))),
          const SizedBox(height: 12),
        ],
        if (isMt5)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tc.profit.withValues(alpha: 0.08),
              border: Border.all(color: tc.profit.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 18, color: tc.profit),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'A-book covers route to your MT5 cover account via the MT5 Manager bridge (async). '
                  'Set the cover account login (Mt5CoverLogin) and HedgeEnabled=true in the bridge config on the VPS. '
                  'No FIX endpoint needed here — just enable routing and Save.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ]),
          )
        else if (isMock)
          Wrap(spacing: 14, runSpacing: 12, children: [
            SizedBox(width: 220, child: TextField(controller: _slip, keyboardType: TextInputType.number, decoration: dec('Sim slippage (bps)'))),
            SizedBox(width: 220, child: TextField(controller: _reject, keyboardType: TextInputType.number, decoration: dec('Sim reject (%)'))),
          ])
        else
          Wrap(spacing: 14, runSpacing: 12, children: [
            SizedBox(width: 300, child: TextField(controller: _endpoint, decoration: dec('Endpoint (host:port / URL)'))),
            SizedBox(width: 220, child: TextField(controller: _sender, decoration: dec('SenderCompID / login'))),
            SizedBox(width: 220, child: TextField(controller: _target, decoration: dec('TargetCompID'))),
            SizedBox(width: 220, child: TextField(controller: _credRef, decoration: dec('Credential ref', help: 'Secret read from LP_SECRET_<ref>'))),
          ]),
        const SizedBox(height: 16),
        Row(children: [
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save, size: 18),
            label: const Text('Save & reload'),
          ),
          if (!widget.isNew) ...[
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove venue'),
            ),
          ],
        ]),
      ]),
    );
  }

  Widget _statusPill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).put('/admin/book/lp-venues', {
        if (widget.initial['id'] != null) 'id': widget.initial['id'],
        'driver': _driver,
        'enabled': _enabled,
        'isDefault': _isDefault,
        'lpProviderId': _lpProviderId,
        'label': _label.text.isEmpty ? null : _label.text,
        'coverLogin': _coverLogin.text.isEmpty ? null : _coverLogin.text,
        'endpoint': _endpoint.text.isEmpty ? null : _endpoint.text,
        'senderCompId': _sender.text.isEmpty ? null : _sender.text,
        'targetCompId': _target.text.isEmpty ? null : _target.text,
        'credentialRef': _credRef.text.isEmpty ? null : _credRef.text,
        'simSlippageBps': int.tryParse(_slip.text) ?? 0,
        'simRejectPct': int.tryParse(_reject.text) ?? 0,
      });
      ref.invalidate(lpVenuesProvider);
      ref.invalidate(lpConfigProvider);
      if (mounted) {
        if (res is Map && res['error'] != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
        } else {
          final active = res is Map && res['bridgeActive'] == true;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(active ? 'Venue active' : 'Saved (bridge not connected)')));
          if (widget.isNew) Navigator.of(context).maybePop();
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove LP venue?'),
        content: Text('Remove the ${_driverLabel(_driver)} venue? Rules pointing at it will fall back to the tenant default.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      // Delete by row id when known, else by driver (legacy null-provider venue).
      final key = widget.initial['id'] ?? _driver;
      await ref.read(apiClientProvider).delete('/admin/book/lp-venues/$key');
      ref.invalidate(lpVenuesProvider);
      ref.invalidate(lpConfigProvider);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Venue removed')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 4 — Net Hedge (manual desk cover + auto net-hedge rules + blotter)
// ═══════════════════════════════════════════════════════════════════════════
class _NetHedgeTab extends ConsumerStatefulWidget {
  const _NetHedgeTab();
  @override
  ConsumerState<_NetHedgeTab> createState() => _NetHedgeTabState();
}

class _NetHedgeTabState extends ConsumerState<_NetHedgeTab> {
  final _mSymbol = TextEditingController();
  final _mVolume = TextEditingController(text: '0.10');
  String _mSide = 'BUY';
  final _aSymbol = TextEditingController();
  final _aThreshold = TextEditingController(text: '0');
  bool _busy = false;
  Future<List<dynamic>>? _hedges;
  Future<List<dynamic>>? _rules;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final api = ref.read(apiClientProvider);
    setState(() {
      _hedges = api.get('/admin/book/broker-hedges').then((r) => (r as List).cast<dynamic>());
      _rules = api.get('/admin/book/autohedge').then((r) => (r as List).cast<dynamic>());
    });
  }

  Future<void> _send(Future<dynamic> Function() call, String okMsg) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final res = await call();
      if (res is Map && res['error'] != null) {
        messenger.showSnackBar(SnackBar(content: Text('${res['error']}')));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(okMsg)));
        _reload();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final hint = Theme.of(context).hintColor;
    TextStyle head() => TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: hint);

    return ListView(padding: const EdgeInsets.symmetric(vertical: 14), children: [
      // ── Manual desk cover ──
      Text('MANUAL COVER  (send any lots to MT5 from the B-book)', style: head()),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 150, child: TextField(controller: _mSymbol, textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Symbol', isDense: true, border: OutlineInputBorder()))),
        ToggleButtons(
          isSelected: [_mSide == 'BUY', _mSide == 'SELL'],
          onPressed: (i) => setState(() => _mSide = i == 0 ? 'BUY' : 'SELL'),
          borderRadius: BorderRadius.circular(6),
          constraints: const BoxConstraints(minHeight: 38, minWidth: 60),
          children: [
            Text('BUY', style: TextStyle(color: _mSide == 'BUY' ? tc.up : null, fontWeight: FontWeight.w700)),
            Text('SELL', style: TextStyle(color: _mSide == 'SELL' ? tc.down : null, fontWeight: FontWeight.w700)),
          ],
        ),
        SizedBox(width: 110, child: TextField(controller: _mVolume, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Lots', isDense: true, border: OutlineInputBorder()))),
        FilledButton.icon(
          onPressed: _busy ? null : () => _send(
            () => api.put('/admin/book/hedge', {
              'symbol': _mSymbol.text.trim(),
              'side': _mSide,
              'volume': double.tryParse(_mVolume.text.trim()) ?? 0,
            }),
            'Cover sent — executing on MT5.',
          ),
          icon: const Icon(Icons.send, size: 16),
          label: const Text('Send cover'),
        ),
      ]),
      const SizedBox(height: 8),
      Text('Tip: to reduce a net-long B-book, SELL on MT5; to reduce net-short, BUY. The cover account nets it.',
          style: TextStyle(fontSize: 11, color: hint)),
      const Divider(height: 32),

      // ── Auto net-hedge rule ──
      Text('AUTO NET-HEDGE  (auto-cover the excess above a per-symbol threshold)', style: head()),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 150, child: TextField(controller: _aSymbol, textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Symbol', isDense: true, border: OutlineInputBorder()))),
        SizedBox(width: 150, child: TextField(controller: _aThreshold, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Threshold (lots)', isDense: true, border: OutlineInputBorder()))),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _send(
            () => api.put('/admin/book/autohedge', {
              'symbol': _aSymbol.text.trim(),
              'enabled': true,
              'thresholdLots': double.tryParse(_aThreshold.text.trim()) ?? 0,
            }),
            'Auto-hedge rule enabled.',
          ),
          icon: const Icon(Icons.bolt, size: 16),
          label: const Text('Enable rule'),
        ),
      ]),
      const SizedBox(height: 14),
      FutureBuilder<List<dynamic>>(
        future: _rules,
        builder: (ctx, snap) {
          final rules = snap.data ?? const [];
          if (rules.isEmpty) return _empty(context, 'No auto-hedge rules. Add one above (threshold 0 = keep flat).');
          return Column(children: [
            for (final r in rules)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(r['enabled'] == true ? Icons.bolt : Icons.bolt_outlined,
                    color: r['enabled'] == true ? tc.profit : hint, size: 20),
                title: Text('${r['symbol']}  ·  threshold ${r['thresholdLots']} lots',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _send(
                    () => api.put('/admin/book/autohedge', {
                      'symbol': r['symbol'],
                      'enabled': !(r['enabled'] == true),
                      'thresholdLots': r['thresholdLots'],
                    }),
                    'Rule updated.',
                  ),
                  child: Text(r['enabled'] == true ? 'Disable' : 'Enable'),
                ),
              ),
          ]);
        },
      ),
      const Divider(height: 32),

      // ── Broker hedge blotter ──
      Row(children: [
        Text('BROKER HEDGE BLOTTER  (manual + auto)', style: head()),
        const Spacer(),
        IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _reload, tooltip: 'Refresh'),
      ]),
      const SizedBox(height: 8),
      FutureBuilder<List<dynamic>>(
        future: _hedges,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) return _empty(context, 'No broker hedges yet.');
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('KIND')),
                DataColumn(label: Text('SYMBOL')),
                DataColumn(label: Text('SIDE')),
                DataColumn(label: Text('VOL'), numeric: true),
                DataColumn(label: Text('FILL PX'), numeric: true),
                DataColumn(label: Text('STATUS')),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (final h in rows)
                  DataRow(cells: [
                    DataCell(Text('${h['kind']}'.replaceFirst('BROKER_', ''), style: TextStyle(fontSize: 11, color: hint))),
                    DataCell(Text('${h['symbol']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text('${h['side']}',
                        style: TextStyle(fontWeight: FontWeight.w700, color: '${h['side']}' == 'BUY' ? tc.up : tc.down))),
                    DataCell(Text('${h['volume']}')),
                    DataCell(Text('${h['fillPrice'] ?? '—'}')),
                    DataCell(Text('${h['status']}')),
                    DataCell(h['status'] == 'FILLED'
                        ? TextButton(
                            onPressed: _busy ? null : () => _send(
                              () => api.patch('/admin/book/hedge/${h['id']}/close', {}),
                              'Closing on MT5…',
                            ),
                            child: const Text('Close'))
                        : const SizedBox.shrink()),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}

Widget _empty(BuildContext context, String msg) => Container(
      padding: const EdgeInsets.all(28),
      alignment: Alignment.center,
      child: Text(msg, style: TextStyle(color: Theme.of(context).hintColor)),
    );

// ═══════════════════════════════════════════════════════════════════════════
//  Tab 7 — News mode (disclosed volatility control: widen spread + pause opens)
// ═══════════════════════════════════════════════════════════════════════════
class _NewsTab extends ConsumerStatefulWidget {
  const _NewsTab();
  @override
  ConsumerState<_NewsTab> createState() => _NewsTabState();
}

class _NewsTabState extends ConsumerState<_NewsTab> {
  final _search = TextEditingController();
  String? _busyId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _set(String symbolId, {bool? mode, int? points, bool? halt}) async {
    setState(() => _busyId = symbolId);
    try {
      await ref.read(apiClientProvider).put('/admin/book/news', {
        'symbolId': symbolId,
        if (mode != null) 'newsMode': mode,
        if (points != null) 'newsSpreadPoints': points,
        if (halt != null) 'newsHaltOpens': halt,
      });
      ref.invalidate(newsModeProvider);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_short(e))));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _edit(Map<String, dynamic> s) async {
    final points = TextEditingController(text: '${s['newsSpreadPoints'] ?? 0}');
    bool halt = s['newsHaltOpens'] != false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text('News settings — ${s['symbol']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: points, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Widen spread (points)', helperText: 'Added to BOTH sides — a real, wider price')),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pause new opens'),
              subtitle: const Text('Clients can still close; only opening is halted', style: TextStyle(fontSize: 11)),
              value: halt,
              onChanged: (v) => setSt(() => halt = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _set(s['id'] as String, points: int.tryParse(points.text) ?? 0, halt: halt);
    }
  }

  @override
  Widget build(BuildContext context) {
    final news = ref.watch(newsModeProvider);
    return news.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: _MiniError(e, onRetry: () => ref.invalidate(newsModeProvider))),
      data: (list) {
        final q = _search.text.trim().toUpperCase();
        final rows = q.isEmpty ? list : list.where((s) => '${(s as Map)['symbol']}'.toUpperCase().contains(q)).toList();
        final active = list.where((s) => (s as Map)['newsMode'] == true).length;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            const Icon(Icons.newspaper_outlined, size: 18),
            const SizedBox(width: 8),
            const Text('News mode', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const Spacer(),
            if (active > 0) _NewsTabState._pill('$active ACTIVE', Colors.orange),
          ]),
          const SizedBox(height: 6),
          Text(
            'Disclosed volatility control — NOT price faking. While ON, a symbol\'s client price is '
            'widened symmetrically by the set points (still a REAL price) and, if enabled, opening new '
            'positions is paused (clients can still close). Flip it around high-impact news.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Filter symbols', isDense: true, border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          for (final s0 in rows)
            () {
              final s = s0 as Map<String, dynamic>;
              final on = s['newsMode'] == true;
              final id = s['id'] as String;
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                color: on ? Colors.orange.withValues(alpha: 0.08) : null,
                child: ListTile(
                  dense: true,
                  leading: _busyId == id
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Switch(value: on, onChanged: (v) => _set(id, mode: v)),
                  title: Text('${s['symbol']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(on
                      ? 'ON · widen ${s['newsSpreadPoints'] ?? 0} pts${s['newsHaltOpens'] != false ? ' · opens paused' : ''}'
                      : '${s['class']}'),
                  trailing: IconButton(
                    tooltip: 'Settings',
                    icon: Icon(Icons.tune, size: 18, color: on ? Colors.orange : Theme.of(context).hintColor),
                    onPressed: () => _edit(s),
                  ),
                ),
              );
            }(),
        ]);
      },
    );
  }

  static Widget _pill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}
