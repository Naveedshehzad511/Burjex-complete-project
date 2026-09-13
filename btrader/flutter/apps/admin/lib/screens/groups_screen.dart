import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/adaptive_table.dart';

final groupsProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiClientProvider);
  return (await api.get('/admin/groups') as List).cast<Map<String, dynamic>>();
});

const _commissionTypes = ['NONE', 'PER_LOT', 'PER_SIDE', 'ROUND_TURN', 'PERCENT'];
const _instrumentClasses = ['FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM'];

String _commissionLabel(String type, num value) {
  switch (type) {
    case 'PER_LOT':
      return '\$${value.toStringAsFixed(2)} / lot';
    case 'PER_SIDE':
      return '\$${value.toStringAsFixed(2)} / side';
    case 'ROUND_TURN':
      return '\$${value.toStringAsFixed(2)} / round-turn';
    case 'PERCENT':
      return '${value.toStringAsFixed(3)}% notional';
    default:
      return 'None';
  }
}

/// Client trading groups (Standard / Raw / ECN / STP …). Assign one Symbols
/// Group (alias pack). CRM account types still map to this name.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(groupsProvider);

    return AdminPage(
      title: 'Trading Groups',
      actions: [
        FilledButton.icon(
          onPressed: () => _edit(context, ref, null, refresh),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New group'),
        ),
      ],
      child: groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const _Empty()
            : SingleChildScrollView(
                child: AdaptiveTable(
                  columns: const [
                    'Name',
                    'Symbols Group',
                    'Commission',
                    'Leverage',
                    'Book',
                    'Accounts',
                    'Status',
                  ],
                  rows: list.map((g) {
                    final enabled = g['enabled'] == true;
                    final packName = '${g['clientSymbolGroup']?['name'] ?? ''}'.trim();
                    Future<void> deleteGroup() async {
                      final ok = await _confirm(
                        context,
                        'Delete group "${g['name']}"? Accounts in it fall back to no group.',
                      );
                      if (!ok) return;
                      try {
                        await ref.read(apiClientProvider).delete('/admin/groups/${g['id']}');
                        await refresh();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Deleted "${g['name']}"')),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Delete failed: $e')),
                          );
                        }
                      }
                    }

                    return AdaptiveRow(
                      cells: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${g['name']}'.isEmpty ? '(unnamed)' : '${g['name']}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Edit',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _edit(context, ref, g, refresh),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.delete_outline, size: 18, color: tc.loss),
                              onPressed: deleteGroup,
                            ),
                            TextButton(
                              onPressed: () => _rules(context, ref, g, refresh),
                              child: const Text('Overrides'),
                            ),
                          ],
                        ),
                        Text(packName.isEmpty ? '—' : packName),
                        Text(_commissionLabel('${g['commissionType']}', _num(g['commissionValue']))),
                        Text('1:${g['defaultLeverage'] ?? 100}'),
                        Text('${g['defaultBook']}'),
                        Text('${g['_count']?['accounts'] ?? 0}'),
                        Text(enabled ? 'Active' : 'Disabled', style: TextStyle(color: enabled ? tc.profit : tc.loss)),
                      ],
                    );
                  }).toList(),
                ),
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic>? g, Future<void> Function() refresh) async {
    final isNew = g == null;
    final name = TextEditingController(text: g?['name']?.toString() ?? '');
    final desc = TextEditingController(text: g?['description']?.toString() ?? '');
    final slippage = TextEditingController(text: '${g?['slippagePoints'] ?? 0}');
    final commVal = TextEditingController(text: '${_num(g?['commissionValue'])}');
    final leverage = TextEditingController(text: '${g?['defaultLeverage'] ?? 100}');
    String commType = '${g?['commissionType'] ?? 'NONE'}';
    String book = '${g?['defaultBook'] ?? 'B'}';
    bool enabled = g?['enabled'] != false;
    String executionMode = '${g?['executionMode'] ?? 'MARKET'}' == 'INSTANT' ? 'INSTANT' : 'MARKET';
    final delayMs = TextEditingController(text: '${g?['executionDelayMs'] ?? 0}');
    final applyRaw = (g?['executionApplyTo'] is Map)
        ? Map<String, dynamic>.from(g!['executionApplyTo'] as Map)
        : <String, dynamic>{};
    bool applyFlag(String k) => applyRaw[k] != false; // missing ⇒ true
    final applyTo = <String, bool>{
      'marketBuy': applyFlag('marketBuy'),
      'marketSell': applyFlag('marketSell'),
      'buyLimit': applyFlag('buyLimit'),
      'sellLimit': applyFlag('sellLimit'),
      'buyStop': applyFlag('buyStop'),
      'sellStop': applyFlag('sellStop'),
      'sl': applyFlag('sl'),
      'tp': applyFlag('tp'),
      'manualClose': applyFlag('manualClose'),
      'closeAll': applyFlag('closeAll'),
    };

    String packId = '${g?['clientSymbolGroupId'] ?? g?['clientSymbolGroup']?['id'] ?? ''}';
    final packsAsync = ref.read(apiClientProvider).get('/admin/symbol-groups').then(
          (v) => (v as List).cast<Map<String, dynamic>>(),
        );

    await showDialog(
      context: context,
      builder: (ctx) => FutureBuilder<List<Map<String, dynamic>>>(
        future: packsAsync,
        builder: (ctx, snap) {
          final packs = snap.data ?? const <Map<String, dynamic>>[];
          return StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
              title: Text(isNew ? 'New Trading Group' : 'Edit ${g['name']}'),
              content: SizedBox(
                width: 560,
                height: 640,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'Group Name (Must Match CRM)',
                          helperText: 'e.g. Standard, Raw Spread, ECN — CRM account types use this exact name',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: leverage,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Default Leverage (1:x)'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: book,
                            decoration: const InputDecoration(labelText: 'Default Book'),
                            items: const [
                              DropdownMenuItem(value: 'B', child: Text('B (warehouse)')),
                              DropdownMenuItem(value: 'A', child: Text('A (STP / cover)')),
                            ],
                            onChanged: (v) => setState(() => book = v ?? 'B'),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: commType,
                            decoration: const InputDecoration(
                              labelText: 'Commission Type (group default)',
                              helperText: 'Legacy default — per-symbol commission is set on the Symbols Group',
                            ),
                            items: _commissionTypes
                                .map((t) => DropdownMenuItem(value: t, child: Text(_commissionTypeLabel(t))))
                                .toList(),
                            onChanged: (v) => setState(() => commType = v ?? 'NONE'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: commVal,
                            keyboardType: TextInputType.number,
                            enabled: commType != 'NONE',
                            decoration: InputDecoration(
                              labelText: 'Commission Value',
                              helperText: _commValueHint(commType),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      TextField(
                        controller: slippage,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Execution slippage (points)',
                          helperText: 'Anti-HFT: worsens every fill for this group. 0 = off.',
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: executionMode,
                        decoration: const InputDecoration(
                          labelText: 'Execution type',
                          helperText: 'Instant = fill at client click / level price. Market = delay then fill.',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'INSTANT', child: Text('Instant execution')),
                          DropdownMenuItem(value: 'MARKET', child: Text('Market execution')),
                        ],
                        onChanged: (v) => setState(() => executionMode = v ?? 'MARKET'),
                      ),
                      if (executionMode == 'MARKET') ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: delayMs,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Execution delay (ms)',
                            helperText: 'Order is placed after exactly this many milliseconds.',
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Apply execution to',
                        style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Only checked types use Instant honour or Market delay. Unchecked types fill immediately at market. Delay ms is the live group value (not hard-coded).',
                        style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 0,
                        children: [
                          for (final e in const [
                            ('marketBuy', 'Buy (market)'),
                            ('marketSell', 'Sell (market)'),
                            ('buyLimit', 'Buy Limit'),
                            ('sellLimit', 'Sell Limit'),
                            ('buyStop', 'Buy Stop'),
                            ('sellStop', 'Sell Stop'),
                            ('sl', 'SL'),
                            ('tp', 'TP'),
                            ('manualClose', 'Manual Close'),
                            ('closeAll', 'Close All'),
                          ])
                            FilterChip(
                              label: Text(e.$2, style: const TextStyle(fontSize: 12)),
                              selected: applyTo[e.$1] == true,
                              onSelected: (v) => setState(() => applyTo[e.$1] = v),
                            ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enable / Disable'),
                        value: enabled,
                        onChanged: (v) => setState(() => enabled = v),
                      ),
                      const Divider(height: 28),
                      Text('Symbols Group', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'Assign a pack from Symbols → Symbols Group. Clients on this trading group only see those aliases and their spread/commission. Create packs there first (feed XAUUSD → XAUUSD.s).',
                        style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                      ),
                      const SizedBox(height: 12),
                      if (snap.connectionState != ConnectionState.done)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else
                        DropdownButtonFormField<String>(
                          initialValue: packs.any((p) => '${p['id']}' == packId) ? packId : '',
                          decoration: InputDecoration(
                            labelText: 'Symbols Group',
                            helperText: packs.isEmpty
                                ? 'Create a pack under Symbols → Symbols Group first'
                                : 'Aliases + markup come from this pack',
                          ),
                          items: [
                            const DropdownMenuItem(value: '', child: Text('— None —')),
                            ...packs.map(
                              (p) => DropdownMenuItem(
                                value: '${p['id']}',
                                child: Text('${p['name']}'),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => packId = v ?? ''),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () async {
                    final payload = <String, dynamic>{
                      'name': name.text.trim(),
                      'description': desc.text.trim(),
                      'slippagePoints': int.tryParse(slippage.text) ?? 0,
                      'commissionType': commType,
                      'commissionValue': double.tryParse(commVal.text) ?? 0,
                      'defaultLeverage': int.tryParse(leverage.text) ?? 100,
                      'defaultBook': book,
                      'enabled': enabled,
                      'executionMode': executionMode,
                      'executionDelayMs': int.tryParse(delayMs.text) ?? 0,
                      'executionApplyTo': Map<String, bool>.from(applyTo),
                      'clientSymbolGroupId': packId.trim().isEmpty ? null : packId,
                    };
                    final api = ref.read(apiClientProvider);
                    try {
                      dynamic res;
                      if (isNew) {
                        res = await api.post('/admin/groups', payload);
                      } else {
                        res = await api.patch('/admin/groups/${g['id']}', payload);
                      }
                      if (res is Map && res['error'] != null) throw Exception(res['error']);
                      if (ctx.mounted) Navigator.pop(ctx);
                      await refresh();
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Save failed: $e')));
                      }
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _rules(BuildContext context, WidgetRef ref, Map<String, dynamic> g, Future<void> Function() refresh) async {
    final symbols = await ref.read(adminSymbolsProvider.future);
    final rules = ((g['rules'] as List?) ?? []).map((r) => <String, dynamic>{
          'instrumentClass': r['instrumentClass'],
          'symbolId': r['symbolId'],
          'markupPoints': r['markupPoints'] ?? 0,
          'commissionType': r['commissionType'],
          'commissionValue': r['commissionValue'],
        }).toList();

    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Overrides — ${g['name']}'),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Legacy per-class / per-symbol markup. Prefer a Symbols Group for new groups. '
                'A per-symbol rule wins over a per-class rule, which wins over the group default.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (rules.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No overrides — Symbols Group / group default applies.'),
                ),
              ...rules.asMap().entries.map((e) {
                final i = e.key;
                final r = e.value;
                final scope = r['symbolId'] != null
                    ? (symbols
                        .firstWhere((s) => s.id == r['symbolId'],
                            orElse: () => symbols.isNotEmpty ? symbols.first : throw 'no symbols')
                        .symbol)
                    : '${r['instrumentClass'] ?? 'FOREX'} (class)';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(scope),
                  subtitle: Text(
                    'markup ${r['markupPoints']} pts · ${r['commissionType'] == null ? 'inherit commission' : _commissionLabel('${r['commissionType']}', _num(r['commissionValue']))}',
                  ),
                  trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => rules.removeAt(i))),
                );
              }),
              const Divider(),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add override'),
                onPressed: () async {
                  final r = await _addRule(ctx, symbols);
                  if (r != null) setState(() => rules.add(r));
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                await ref.read(apiClientProvider).put('/admin/groups/${g['id']}/rules', {'rules': rules});
                if (ctx.mounted) Navigator.pop(ctx);
                await refresh();
              },
              child: const Text('Save overrides'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _addRule(BuildContext context, List<TradeSymbol> symbols) async {
    String scopeKind = 'class';
    String instClass = 'FOREX';
    String? symbolId = symbols.isNotEmpty ? symbols.first.id : null;
    final markup = TextEditingController(text: '0');
    String commType = 'INHERIT';
    final commVal = TextEditingController(text: '0');

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add override'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: scopeKind,
                decoration: const InputDecoration(labelText: 'Scope'),
                items: const [
                  DropdownMenuItem(value: 'class', child: Text('Instrument class')),
                  DropdownMenuItem(value: 'symbol', child: Text('Single symbol')),
                ],
                onChanged: (v) => setState(() => scopeKind = v ?? 'class'),
              ),
              const SizedBox(height: 10),
              if (scopeKind == 'class')
                DropdownButtonFormField<String>(
                  initialValue: instClass,
                  decoration: const InputDecoration(labelText: 'Instrument class'),
                  items: _instrumentClasses.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => setState(() => instClass = v ?? 'FOREX'),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: symbolId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Symbol'),
                  items: symbols.map((s) => DropdownMenuItem(value: s.id, child: Text(s.symbol))).toList(),
                  onChanged: (v) => setState(() => symbolId = v),
                ),
              const SizedBox(height: 10),
              TextField(controller: markup, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Markup (points)')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: commType,
                decoration: const InputDecoration(labelText: 'Commission'),
                items: const [
                  DropdownMenuItem(value: 'INHERIT', child: Text('Inherit group')),
                  DropdownMenuItem(value: 'NONE', child: Text('None')),
                  DropdownMenuItem(value: 'PER_LOT', child: Text('Per lot')),
                  DropdownMenuItem(value: 'PER_SIDE', child: Text('Per side')),
                  DropdownMenuItem(value: 'ROUND_TURN', child: Text('Round turn')),
                  DropdownMenuItem(value: 'PERCENT', child: Text('Percent')),
                ],
                onChanged: (v) => setState(() => commType = v ?? 'INHERIT'),
              ),
              if (commType != 'INHERIT' && commType != 'NONE')
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextField(controller: commVal, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Commission value')),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx, {
                  'instrumentClass': scopeKind == 'class' ? instClass : null,
                  'symbolId': scopeKind == 'symbol' ? symbolId : null,
                  'markupPoints': int.tryParse(markup.text) ?? 0,
                  'commissionType': commType == 'INHERIT' ? null : commType,
                  'commissionValue': (commType == 'INHERIT' || commType == 'NONE') ? null : (double.tryParse(commVal.text) ?? 0),
                });
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}


String _commissionTypeLabel(String t) => switch (t) {
      'PER_LOT' => 'Per Lot',
      'PER_SIDE' => 'Per Side',
      'ROUND_TURN' => 'Round Turn',
      'PERCENT' => 'Percent of notional',
      _ => 'None',
    };

String _commValueHint(String t) => switch (t) {
      'PER_LOT' => 'USD per 1.0 lot',
      'PER_SIDE' => 'USD per lot, each side',
      'ROUND_TURN' => 'USD per 1.0 lot round-turn',
      'PERCENT' => '% of notional, each side',
      _ => '—',
    };

num _num(dynamic v) => v == null ? 0 : (v is num ? v : num.tryParse('$v') ?? 0);

Future<bool> _confirm(BuildContext context, String message) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
          ],
        ),
      ) ??
      false;
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('No trading groups yet.', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Create Standard, Raw Spread, ECN, STP — names must match your CRM account types. '
              'Assign a Symbols Group so clients only receive those aliases.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ]),
        ),
      );
}
