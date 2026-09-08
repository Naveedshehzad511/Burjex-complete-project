import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/adaptive_table.dart';
import '../widgets/stat_card.dart';
import 'groups_screen.dart' show groupsProvider;

double _n(dynamic v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

final accountDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  ref.watch(adminLiveTicker);
  final api = ref.watch(apiClientProvider);
  return (await api.get('/accounts/$id')) as Map<String, dynamic>;
});

final accountPositionsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  ref.watch(adminLiveTicker);
  final api = ref.watch(apiClientProvider);
  return (await api.get('/positions?accountId=$id&status=OPEN')) as List;
});

final accountDealsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  final api = ref.watch(apiClientProvider);
  return (await api.get('/history/deals?accountId=$id')) as List;
});

/// Subscribe THIS account to the live WS feed so its per-position P/L frames
/// flow reliably (otherwise live P/L only shows when another screen happened to
/// subscribe it). watchAccount is idempotent and re-subscribes on reconnect.
final accountLiveWatchProvider = Provider.autoDispose.family<void, String>((ref, id) {
  final sock = ref.watch(marketSocketProvider);
  sock?.watchAccount(id);
});

/// Full account console: header + money, admin actions (group / leverage /
/// trading / password / balance / delete), plus Active Trades and History tabs.
class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(accountLiveWatchProvider(accountId)); // subscribe live position P/L for this account
    final detail = ref.watch(accountDetailProvider(accountId));
    final tc = Theme.of(context).extension<TradeColors>()!;

    Future<void> refreshAll() async {
      ref.invalidate(accountDetailProvider(accountId));
      ref.invalidate(accountPositionsProvider(accountId));
      ref.invalidate(accountDealsProvider(accountId));
    }

    return detail.when(
      skipLoadingOnReload: true, // don't flash a spinner on every 1s live refetch
      loading: () => const AdminPage(title: 'Account', child: Center(child: CircularProgressIndicator())),
      error: (e, _) => AdminPage(title: 'Account', child: Center(child: Text('$e'))),
      data: (a) {
        final user = (a['user'] as Map?) ?? const {};
        final name = [user['firstName'], user['lastName']].where((x) => x != null && '$x'.trim().isNotEmpty).join(' ').trim();
        final fpl = _n(a['floatingPL']);
        return AdminPage(
          title: 'Account ${a['login']}',
          actions: [
            TextButton.icon(onPressed: () => context.go('/accounts'), icon: const Icon(Icons.arrow_back, size: 18), label: const Text('Back')),
            IconButton(onPressed: refreshAll, icon: const Icon(Icons.refresh)),
          ],
          child: DefaultTabController(
            length: 2,
            child: ListView(children: [
              // ── Header card ──────────────────────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(name.isEmpty ? '${user['email'] ?? '—'}' : name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                      StatusChip('${a['status']}', color: '${a['status']}' == 'ACTIVE' ? tc.profit : tc.loss),
                    ]),
                    Text('${user['email'] ?? ''}  ·  #${a['login']}  ·  ${a['type']} ${a['currency']}  ·  1:${a['leverage']}',
                        style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 14),
                    Wrap(spacing: 24, runSpacing: 8, children: [
                      _kv('Balance', money(_n(a['balance'])), null),
                      _kv('Equity', money(_n(a['equity'])), null),
                      _kv('Floating P/L', money(fpl), fpl > 0 ? tc.profit : (fpl < 0 ? tc.loss : null)),
                      _kv('Used margin', money(_n(a['margin'])), null),
                    ]),
                    const SizedBox(height: 16),
                    // ── Action buttons ─────────────────────────────────────
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(onPressed: () => _changeGroup(context, ref, a, refreshAll), icon: const Icon(Icons.groups_outlined, size: 18), label: const Text('Change group')),
                      OutlinedButton.icon(onPressed: () => _changeLeverage(context, ref, a, refreshAll), icon: const Icon(Icons.speed, size: 18), label: const Text('Change leverage')),
                      OutlinedButton.icon(onPressed: () => _adjustBalance(context, ref, a, refreshAll), icon: const Icon(Icons.payments_outlined, size: 18), label: const Text('Balance')),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final enable = '${a['status']}' != 'ACTIVE';
                          await ref.read(apiClientProvider).patch('/accounts/$accountId/trading', {'enabled': enable});
                          await refreshAll();
                        },
                        icon: Icon('${a['status']}' == 'ACTIVE' ? Icons.block : Icons.play_arrow, size: 18),
                        label: Text('${a['status']}' == 'ACTIVE' ? 'Disable trading' : 'Enable trading'),
                      ),
                      OutlinedButton.icon(onPressed: () => _resetPassword(context, ref, refreshAll), icon: const Icon(Icons.password, size: 18), label: const Text('Password')),
                      OutlinedButton.icon(
                        onPressed: () => _deleteAccount(context, ref, a, refreshAll),
                        icon: Icon(Icons.delete_outline, size: 18, color: tc.loss),
                        label: Text('Delete', style: TextStyle(color: tc.loss)),
                      ),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              const TabBar(tabs: [Tab(text: 'Active Trades'), Tab(text: 'History')]),
              SizedBox(
                height: 460,
                child: TabBarView(children: [
                  _ActiveTrades(accountId: accountId, onChanged: refreshAll),
                  _History(accountId: accountId),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  static Widget _kv(String label, String value, Color? color) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
      ]);

  Future<void> _changeGroup(BuildContext context, WidgetRef ref, Map<String, dynamic> a, Future<void> Function() refresh) async {
    final groups = await ref.read(groupsProvider.future);
    String? sel = a['groupId']?.toString();
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Change trading group'),
        content: DropdownButtonFormField<String?>(
          initialValue: sel,
          decoration: const InputDecoration(labelText: 'Group'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
            ...groups.map((g) => DropdownMenuItem<String?>(value: g['id'] as String, child: Text('${g['name']}'))),
          ],
          onChanged: (v) => setLocal(() => sel = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () async {
            await ref.read(apiClientProvider).patch('/accounts/${a['id']}/group', {'groupId': sel});
            if (ctx.mounted) Navigator.pop(ctx);
            await refresh();
          }, child: const Text('Save')),
        ],
      )),
    );
  }

  Future<void> _changeLeverage(BuildContext context, WidgetRef ref, Map<String, dynamic> a, Future<void> Function() refresh) async {
    final c = TextEditingController(text: '${a['leverage'] ?? 100}');
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Change leverage'),
      content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Leverage (1:x)', prefixText: '1:')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          final lev = int.tryParse(c.text.trim());
          if (lev != null && lev > 0) {
            await ref.read(apiClientProvider).patch('/accounts/${a['id']}/leverage', {'leverage': lev});
          }
          if (ctx.mounted) Navigator.pop(ctx);
          await refresh();
        }, child: const Text('Save')),
      ],
    ));
  }

  Future<void> _adjustBalance(BuildContext context, WidgetRef ref, Map<String, dynamic> a, Future<void> Function() refresh) async {
    final amt = TextEditingController();
    final comment = TextEditingController();
    String type = 'DEPOSIT';
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
      title: Text('Balance — #${a['login']}'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(
          initialValue: type,
          decoration: const InputDecoration(labelText: 'Type'),
          items: const ['DEPOSIT', 'WITHDRAW', 'BONUS', 'DIVIDEND', 'MANUAL'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
          onChanged: (v) => setLocal(() => type = v ?? 'DEPOSIT'),
        ),
        const SizedBox(height: 10),
        TextField(controller: amt, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount', helperText: 'Positive credits, negative debits')),
        const SizedBox(height: 10),
        TextField(controller: comment, decoration: const InputDecoration(labelText: 'Comment (optional)')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          final v = double.tryParse(amt.text.trim());
          if (v != null && v != 0) {
            await ref.read(apiClientProvider).post('/financial/adjust', {
              'accountId': a['id'], 'type': type, 'amount': v, 'comment': comment.text.trim(),
            });
          }
          if (ctx.mounted) Navigator.pop(ctx);
          await refresh();
        }, child: const Text('Apply')),
      ],
    )));
  }

  Future<void> _resetPassword(BuildContext context, WidgetRef ref, Future<void> Function() refresh) async {
    final c = TextEditingController();
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Set trading password'),
      content: TextField(controller: c, decoration: const InputDecoration(labelText: 'New password', helperText: 'Min 6 chars')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          if (c.text.trim().length >= 6) {
            await ref.read(apiClientProvider).post('/accounts/$accountId/password', {'password': c.text.trim()});
          }
          if (ctx.mounted) Navigator.pop(ctx);
        }, child: const Text('Set')),
      ],
    ));
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref, Map<String, dynamic> a, Future<void> Function() refresh) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Delete account #${a['login']}?'),
      content: const Text('Empty accounts are removed permanently. Accounts with trade history are archived (kept for audit). Refused while positions are open.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    final res = await ref.read(apiClientProvider).delete('/accounts/$accountId') as Map<String, dynamic>?;
    if (!context.mounted) return;
    if (res?['error'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${res!['error']}')));
      await refresh();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res?['deleted'] == true ? 'Account deleted.' : 'Account archived (had history).')));
      context.go('/accounts');
    }
  }
}

// ── Active Trades tab ──────────────────────────────────────────────────────
class _ActiveTrades extends ConsumerWidget {
  const _ActiveTrades({required this.accountId, required this.onChanged});
  final String accountId;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions = ref.watch(accountPositionsProvider(accountId));
    final livePL = ref.watch(livePositionProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final api = ref.read(apiClientProvider);

    return positions.when(
      skipLoadingOnReload: true, // keep the table steady across live refetches
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        if (list.isEmpty) return const Center(child: Text('No open trades.'));
        return SingleChildScrollView(
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async { await api.post('/accounts/$accountId/close-all'); await onChanged(); ref.invalidate(accountPositionsProvider(accountId)); },
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Close all'),
              ),
            ),
            AdaptiveTable(
              columns: const ['Symbol', 'Side', 'Volume', 'Open', 'SL', 'TP', 'P/L'],
              rows: list.map((p) {
                final sym = (p['symbol'] is Map) ? p['symbol']['symbol'] : p['symbol'];
                final digits = (p['symbol'] is Map) ? (p['symbol']['digits'] ?? 5) as int : 5;
                final pl = livePL[p['id']] ?? _n(p['profit']);
                return AdaptiveRow(
                  cells: [
                    Text('$sym'),
                    Text('${p['side']}', style: TextStyle(color: p['side'] == 'BUY' ? tc.buy : tc.sell)),
                    Text(_n(p['volume']).toStringAsFixed(2)),
                    Text(price(_n(p['openPrice']), digits)),
                    Text(p['slPrice'] == null ? '—' : price(_n(p['slPrice']), digits)),
                    Text(p['tpPrice'] == null ? '—' : price(_n(p['tpPrice']), digits)),
                    Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss)),
                  ],
                  actions: [
                    TextButton(onPressed: () => _modify(context, ref, p, digits), child: const Text('Modify')),
                    TextButton(
                      onPressed: () => _close(context, ref, p, digits),
                      child: Text('Close', style: TextStyle(color: tc.loss)),
                    ),
                  ],
                );
              }).toList(),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref, dynamic p, int digits) async {
    final symName = (p['symbol'] is Map) ? p['symbol']['symbol'] : p['symbol'];
    final openVol = _n(p['volume']);
    final priceCtrl = TextEditingController();
    final volCtrl = TextEditingController();
    final api = ref.read(apiClientProvider);
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('Close $symName  ($openVol lots)'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: priceCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Close price (blank = market)',
            helperText: 'Manual price = dealer close for slippage / compensation',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: volCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Volume (blank = full)'),
        ),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          final vol = double.tryParse(volCtrl.text.trim());
          final price = double.tryParse(priceCtrl.text.trim());
          if (price != null && price > 0) {
            await api.post('/positions/${p['id']}/close-at', {'price': price, if (vol != null) 'volume': vol});
          } else {
            await api.post('/positions/${p['id']}/close', {if (vol != null) 'volume': vol});
          }
          if (ctx.mounted) Navigator.pop(ctx);
          ref.invalidate(accountPositionsProvider(accountId));
          ref.invalidate(accountDetailProvider(accountId));
        }, child: const Text('Close')),
      ],
    ));
  }

  Future<void> _modify(BuildContext context, WidgetRef ref, dynamic p, int digits) async {
    final openOriginal = price(_n(p['openPrice']), digits);
    final open = TextEditingController(text: openOriginal);
    final sl = TextEditingController(text: p['slPrice'] == null ? '' : price(_n(p['slPrice']), digits));
    final tp = TextEditingController(text: p['tpPrice'] == null ? '' : price(_n(p['tpPrice']), digits));
    final api = ref.read(apiClientProvider);
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('Modify ${(p['symbol'] is Map) ? p['symbol']['symbol'] : p['symbol']}'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: open,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Open price (dealer edit)',
            helperText: 'Adjusts entry for slippage / compensation — changes P/L',
          ),
        ),
        const SizedBox(height: 10),
        TextField(controller: sl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stop Loss (blank = none)')),
        const SizedBox(height: 10),
        TextField(controller: tp, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Take Profit (blank = none)')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          // Only call the dealer open-price endpoint if it actually changed.
          final newOpen = double.tryParse(open.text.trim());
          if (newOpen != null && open.text.trim() != openOriginal) {
            await api.patch('/positions/${p['id']}/open-price', {'openPrice': newOpen});
          }
          await api.patch('/positions/${p['id']}', {
            'slPrice': sl.text.trim().isEmpty ? null : double.tryParse(sl.text.trim()),
            'tpPrice': tp.text.trim().isEmpty ? null : double.tryParse(tp.text.trim()),
          });
          if (ctx.mounted) Navigator.pop(ctx);
          ref.invalidate(accountPositionsProvider(accountId));
          ref.invalidate(accountDetailProvider(accountId));
        }, child: const Text('Save')),
      ],
    ));
  }
}

// ── History tab ────────────────────────────────────────────────────────────
class _History extends ConsumerWidget {
  const _History({required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deals = ref.watch(accountDealsProvider(accountId));
    final tc = Theme.of(context).extension<TradeColors>()!;
    return deals.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        if (list.isEmpty) return const Center(child: Text('No history.'));
        return SingleChildScrollView(
          child: AdaptiveTable(
            columns: const ['Time', 'Type', 'Symbol', 'Side', 'Volume', 'Price', 'Profit', 'Balance'],
            rows: list.map((d) {
              final sym = (d['symbol'] is Map) ? d['symbol']['symbol'] : (d['symbol'] ?? '—');
              final profit = _n(d['profit']);
              final t = DateTime.tryParse('${d['createdAt'] ?? ''}');
              return AdaptiveRow(cells: [
                Text(t == null ? '—' : '${t.toLocal()}'.split('.').first),
                Text('${d['type'] ?? ''}'),
                Text('$sym'),
                Text('${d['side'] ?? '—'}'),
                Text(d['volume'] == null ? '—' : _n(d['volume']).toStringAsFixed(2)),
                Text(d['price'] == null ? '—' : '${d['price']}'),
                Text(money(profit), style: TextStyle(color: profit > 0 ? tc.profit : (profit < 0 ? tc.loss : null))),
                Text(money(_n(d['balanceAfter']))),
              ]);
            }).toList(),
          ),
        );
      },
    );
  }
}
