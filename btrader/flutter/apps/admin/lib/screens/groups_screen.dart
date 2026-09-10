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

final lpSymbolsProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiClientProvider);
  try {
    return (await api.get('/admin/groups/lp-symbols') as List).cast<Map<String, dynamic>>();
  } catch (_) {
    // Fallback: enabled symbols from the book if Market Watch endpoint is unavailable.
    final syms = await ref.watch(adminSymbolsProvider.future);
    return syms
        .map((s) => <String, dynamic>{
              'id': s.id,
              'symbol': s.symbol,
              'class': s.klass,
              'live': false,
            })
        .toList();
  }
});

const _commissionTypes = ['NONE', 'PER_LOT', 'PER_SIDE', 'ROUND_TURN', 'PERCENT'];
const _pricingMethods = ['SPREAD_ONLY', 'COMMISSION_ONLY', 'SPREAD_AND_COMMISSION'];
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

String _pricingMethodLabel(String m) => switch (m) {
      'COMMISSION_ONLY' => 'Commission Only',
      'SPREAD_AND_COMMISSION' => 'Spread + Commission',
      _ => 'Spread Only',
    };

/// Client trading groups (Standard / Raw / ECN / STP …). Each group sets
/// Symbol Mappings (LP → Client + per-symbol pricing), plus default leverage
/// and book. Group names must match the CRM account-type group names.
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
                    'Mappings',
                    'Commission',
                    'Leverage',
                    'Book',
                    'Accounts',
                    'Status',
                  ],
                  rows: list.map((g) {
                    final enabled = g['enabled'] == true;
                    final mapCount = (g['symbolMappings'] as List?)?.length ??
                        (g['_count']?['symbolMappings'] as num?)?.toInt() ??
                        0;
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
                              onPressed: () => _edit(context, ref, g, refresh),
                              child: const Text('Symbol Mapping'),
                            ),
                            TextButton(
                              onPressed: () => _rules(context, ref, g, refresh),
                              child: const Text('Overrides'),
                            ),
                          ],
                        ),
                        Text('$mapCount'),
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
    };

    final mappings = <_MappingRow>[
      for (final m in ((g?['symbolMappings'] as List?) ?? []))
        _MappingRow.fromJson(Map<String, dynamic>.from(m as Map)),
    ];

    final lpAsync = ref.read(lpSymbolsProvider.future);

    await showDialog(
      context: context,
      builder: (ctx) => FutureBuilder<List<Map<String, dynamic>>>(
        future: lpAsync,
        builder: (ctx, snap) {
          final lpSymbols = snap.data ?? const <Map<String, dynamic>>[];
          return StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
              title: Text(isNew ? 'New Trading Group' : 'Edit ${g['name']}'),
              content: SizedBox(
                width: 720,
                height: 720,
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
                              helperText: 'Used when a mapping inherits / has no commission',
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
                        'Only checked types use Instant honour or Market delay. Unchecked types fill immediately at market.',
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
                      Text('Symbol Mapping', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'Map LP Market Watch symbols to client symbols and set per-symbol pricing. '
                        'Clients on this group (e.g. Standard) automatically get these symbols — no manual Add Symbols.',
                        style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                      ),
                      const SizedBox(height: 12),
                      if (snap.connectionState != ConnectionState.done)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else ...[
                        _AddMappingRow(
                          lpSymbols: lpSymbols,
                          onAdd: (row) => setState(() => mappings.add(row)),
                        ),
                        const SizedBox(height: 8),
                        if (mappings.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              'No mappings yet — add LP → Client symbols above.',
                              style: TextStyle(color: Theme.of(ctx).hintColor),
                            ),
                          ),
                        ...mappings.asMap().entries.map((e) {
                          final i = e.key;
                          final m = e.value;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${m.lpSymbol}  →  ${m.clientSymbol}',
                                          style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Remove',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: () => setState(() => mappings.removeAt(i)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  DropdownButtonFormField<String>(
                                    initialValue: m.pricingMethod,
                                    decoration: const InputDecoration(labelText: 'Pricing Method', isDense: true),
                                    items: _pricingMethods
                                        .map((p) => DropdownMenuItem(value: p, child: Text(_pricingMethodLabel(p))))
                                        .toList(),
                                    onChanged: (v) => setState(() => m.pricingMethod = v ?? 'SPREAD_ONLY'),
                                  ),
                                  if (m.pricingMethod != 'COMMISSION_ONLY') ...[
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      Expanded(
                                        child: TextField(
                                          controller: m.minSpread,
                                          keyboardType: TextInputType.number,
                                          decoration: const InputDecoration(
                                            labelText: 'Min Spread (points)',
                                            isDense: true,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: m.maxSpread,
                                          keyboardType: TextInputType.number,
                                          decoration: const InputDecoration(
                                            labelText: 'Max Spread (points)',
                                            isDense: true,
                                            helperText: '0 = no cap',
                                          ),
                                        ),
                                      ),
                                    ]),
                                  ],
                                  if (m.pricingMethod != 'SPREAD_ONLY') ...[
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: m.commissionType == 'NONE' ? 'PER_LOT' : m.commissionType,
                                          decoration: const InputDecoration(labelText: 'Commission Type', isDense: true),
                                          items: const [
                                            DropdownMenuItem(value: 'PER_LOT', child: Text('Per Lot')),
                                            DropdownMenuItem(value: 'PER_SIDE', child: Text('Per Side')),
                                            DropdownMenuItem(value: 'ROUND_TURN', child: Text('Round Turn')),
                                          ],
                                          onChanged: (v) => setState(() => m.commissionType = v ?? 'PER_LOT'),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: m.commissionValue,
                                          keyboardType: TextInputType.number,
                                          decoration: const InputDecoration(
                                            labelText: 'Commission Value',
                                            isDense: true,
                                          ),
                                        ),
                                      ),
                                    ]),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
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
                      'symbolMappings': mappings.map((m) => m.toJson()).toList(),
                    };
                    final api = ref.read(apiClientProvider);
                    try {
                      if (isNew) {
                        await api.post('/admin/groups', payload);
                      } else {
                        await api.patch('/admin/groups/${g['id']}', payload);
                      }
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
                'Legacy per-class / per-symbol markup. Prefer Symbol Mapping for new groups. '
                'A per-symbol rule wins over a per-class rule, which wins over the group default.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (rules.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No overrides — Symbol Mapping / group default applies.'),
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

class _MappingRow {
  String lpSymbol;
  String clientSymbol;
  String pricingMethod;
  final TextEditingController minSpread;
  final TextEditingController maxSpread;
  String commissionType;
  final TextEditingController commissionValue;

  _MappingRow({
    required this.lpSymbol,
    required this.clientSymbol,
    this.pricingMethod = 'SPREAD_ONLY',
    int minSpreadPoints = 0,
    int maxSpreadPoints = 0,
    this.commissionType = 'NONE',
    num commissionValue = 0,
  })  : minSpread = TextEditingController(text: '$minSpreadPoints'),
        maxSpread = TextEditingController(text: '$maxSpreadPoints'),
        commissionValue = TextEditingController(text: '$commissionValue');

  factory _MappingRow.fromJson(Map<String, dynamic> j) => _MappingRow(
        lpSymbol: '${j['lpSymbol'] ?? ''}',
        clientSymbol: '${j['clientSymbol'] ?? ''}',
        pricingMethod: '${j['pricingMethod'] ?? 'SPREAD_ONLY'}',
        minSpreadPoints: (j['minSpreadPoints'] as num?)?.toInt() ?? 0,
        maxSpreadPoints: (j['maxSpreadPoints'] as num?)?.toInt() ?? 0,
        commissionType: '${j['commissionType'] ?? 'NONE'}',
        commissionValue: _num(j['commissionValue']),
      );

  Map<String, dynamic> toJson() => {
        'lpSymbol': lpSymbol.trim().toUpperCase(),
        'clientSymbol': clientSymbol.trim(),
        'pricingMethod': pricingMethod,
        'minSpreadPoints': int.tryParse(minSpread.text) ?? 0,
        'maxSpreadPoints': int.tryParse(maxSpread.text) ?? 0,
        'commissionType': pricingMethod == 'SPREAD_ONLY' ? 'NONE' : commissionType,
        'commissionValue': double.tryParse(commissionValue.text) ?? 0,
        'enabled': true,
      };
}

class _AddMappingRow extends StatefulWidget {
  const _AddMappingRow({required this.lpSymbols, required this.onAdd});
  final List<Map<String, dynamic>> lpSymbols;
  final void Function(_MappingRow row) onAdd;

  @override
  State<_AddMappingRow> createState() => _AddMappingRowState();
}

class _AddMappingRowState extends State<_AddMappingRow> {
  final _lpCtrl = TextEditingController();
  final _clientCtrl = TextEditingController();
  final _lpFocus = FocusNode();
  String? _selectedLp;

  @override
  void dispose() {
    _lpCtrl.dispose();
    _clientCtrl.dispose();
    _lpFocus.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _lpCtrl.text.trim().toUpperCase();
    if (q.isEmpty) return widget.lpSymbols.take(40).toList();
    return widget.lpSymbols
        .where((s) => '${s['symbol']}'.toUpperCase().contains(q))
        .take(40)
        .toList();
  }

  void _add() {
    final lp = (_selectedLp ?? _lpCtrl.text).trim().toUpperCase();
    final client = _clientCtrl.text.trim().isEmpty ? lp : _clientCtrl.text.trim();
    if (lp.isEmpty) return;
    widget.onAdd(_MappingRow(lpSymbol: lp, clientSymbol: client));
    setState(() {
      _lpCtrl.clear();
      _clientCtrl.clear();
      _selectedLp = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: RawAutocomplete<Map<String, dynamic>>(
                textEditingController: _lpCtrl,
                focusNode: _lpFocus,
                optionsBuilder: (v) {
                  final q = v.text.trim().toUpperCase();
                  if (q.isEmpty) return widget.lpSymbols.take(30);
                  return widget.lpSymbols.where((s) => '${s['symbol']}'.toUpperCase().contains(q)).take(30);
                },
                displayStringForOption: (o) => '${o['symbol']}',
                onSelected: (o) {
                  setState(() {
                    _selectedLp = '${o['symbol']}';
                    _lpCtrl.text = _selectedLp!;
                    if (_clientCtrl.text.trim().isEmpty) _clientCtrl.text = _selectedLp!;
                  });
                },
                fieldViewBuilder: (ctx, controller, focus, onSubmit) => TextField(
                  controller: controller,
                  focusNode: focus,
                  decoration: InputDecoration(
                    labelText: 'LP Symbol (Market Watch)',
                    hintText: widget.lpSymbols.isEmpty ? 'Connect LP / feed first' : 'Search EURUSD, XAUUSD…',
                    isDense: true,
                    suffixIcon: widget.lpSymbols.any((s) => s['live'] == true)
                        ? const Tooltip(message: 'Live feed symbols available', child: Icon(Icons.sensors, size: 18))
                        : null,
                  ),
                  onChanged: (_) => setState(() => _selectedLp = null),
                  onSubmitted: (_) => onSubmit(),
                ),
                optionsViewBuilder: (ctx, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (_, i) {
                          final o = options.elementAt(i);
                          final live = o['live'] == true;
                          return ListTile(
                            dense: true,
                            title: Text('${o['symbol']}'),
                            subtitle: Text('${o['class']}${live ? ' · live' : ''}'),
                            onTap: () => onSelected(o),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _clientCtrl,
                decoration: const InputDecoration(
                  labelText: 'Client Symbol',
                  hintText: 'e.g. XAUUSD.P or BURJ_GOLD',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonal(
                onPressed: _add,
                child: const Text('Add Symbol'),
              ),
            ),
          ],
        ),
        if (_lpCtrl.text.isNotEmpty && _filtered.isNotEmpty && _selectedLp == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Suggestions: ${_filtered.take(5).map((s) => s['symbol']).join(', ')}',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ),
      ],
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
              'Add Symbol Mappings so clients auto-receive those instruments.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ]),
        ),
      );
}
