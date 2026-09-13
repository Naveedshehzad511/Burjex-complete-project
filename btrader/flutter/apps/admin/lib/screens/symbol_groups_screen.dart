import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/adaptive_table.dart';
import '../widgets/symbol_mapping_editor.dart';

final symbolGroupsProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiClientProvider);
  return (await api.get('/admin/symbol-groups') as List).cast<Map<String, dynamic>>();
});

/// Reusable alias packs: feed XAUUSD → XAUUSD.s with spread and/or commission.
/// Assign a pack to a trading group; clients on that group only see these names.
class SymbolGroupsScreen extends ConsumerWidget {
  const SymbolGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.watch(symbolGroupsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(symbolGroupsProvider);

    return AdminPage(
      title: 'Symbols Group',
      actions: [
        FilledButton.icon(
          onPressed: () => _edit(context, ref, null, refresh),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New symbols group'),
        ),
      ],
      child: packs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const _Empty()
            : SingleChildScrollView(
                child: AdaptiveTable(
                  columns: const ['Name', 'Aliases', 'Trading groups', 'Status'],
                  rows: list.map((g) {
                    final enabled = g['enabled'] != false;
                    final itemCount = (g['items'] as List?)?.length ??
                        (g['_count']?['items'] as num?)?.toInt() ??
                        0;
                    final tgCount = (g['tradingGroups'] as List?)?.length ??
                        (g['_count']?['tradingGroups'] as num?)?.toInt() ??
                        0;
                    final tgNames = ((g['tradingGroups'] as List?) ?? [])
                        .map((t) => '${(t as Map)['name']}')
                        .where((n) => n.isNotEmpty)
                        .join(', ');
                    Future<void> deletePack() async {
                      final ok = await _confirm(
                        context,
                        'Delete symbols group "${g['name']}"? Trading groups using it will lose their aliases.',
                      );
                      if (!ok) return;
                      try {
                        await ref.read(apiClientProvider).delete('/admin/symbol-groups/${g['id']}');
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
                              onPressed: deletePack,
                            ),
                          ],
                        ),
                        Text('$itemCount'),
                        Text(tgNames.isEmpty ? '$tgCount' : tgNames),
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
    bool enabled = g?['enabled'] != false;
    final mappings = <SymbolMappingDraft>[
      for (final m in ((g?['items'] as List?) ?? []))
        SymbolMappingDraft.fromJson(Map<String, dynamic>.from(m as Map)),
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
              title: Text(isNew ? 'New Symbols Group' : 'Edit ${g['name']}'),
              content: SizedBox(
                width: 720,
                height: 640,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'Group name',
                          helperText: 'e.g. Standard symbols, Nano symbols',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enable / Disable'),
                        value: enabled,
                        onChanged: (v) => setState(() => enabled = v),
                      ),
                      const Divider(height: 28),
                      Text('Alias symbols', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'Take a feed symbol (XAUUSD) and give it your name (XAUUSD.s). '
                        'Then choose spread, commission, or both. These apply on live trades when this pack is assigned to a trading group.',
                        style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                      ),
                      const SizedBox(height: 12),
                      SymbolMappingEditor(
                        lpSymbols: lpSymbols,
                        mappings: mappings,
                        loading: snap.connectionState != ConnectionState.done,
                        onChanged: () => setState(() {}),
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
                      'enabled': enabled,
                      'items': mappings.map((m) => m.toJson()).toList(),
                    };
                    final api = ref.read(apiClientProvider);
                    try {
                      dynamic res;
                      if (isNew) {
                        res = await api.post('/admin/symbol-groups', payload);
                      } else {
                        res = await api.patch('/admin/symbol-groups/${g['id']}', payload);
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
}

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
            const Text('No symbols groups yet.', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Create Standard symbols, Nano symbols, … Map feed XAUUSD → XAUUSD.s and set spread, commission, or both. Then assign the pack on a trading group.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ]),
        ),
      );
}
