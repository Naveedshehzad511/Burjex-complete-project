import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';
import '../widgets/adaptive_table.dart';

/// Symbol management — full contract spec CRUD, enable/disable (no hardcoded instruments).
class SymbolsScreen extends ConsumerWidget {
  const SymbolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbols = ref.watch(adminSymbolsProvider);
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(adminSymbolsProvider);

    return AdminPage(
      title: 'Symbols',
      actions: [
        OutlinedButton.icon(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await api.post('/symbols/sync-now', {});
              messenger.showSnackBar(const SnackBar(
                content: Text('Sync requested — MT5 symbols & groups refresh within ~10s.'),
              ));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('Sync request failed: $e')));
            }
          },
          icon: const Icon(Icons.sync, size: 18),
          label: const Text('Sync from MT5 now'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(onPressed: () => _edit(context, ref, null, refresh), icon: const Icon(Icons.add, size: 18), label: const Text('Add symbol')),
      ],
      child: symbols.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => SingleChildScrollView(
          child: AdaptiveTable(
            columns: const ['Symbol', 'Class', 'Lots (min/max/step)', 'State'],
            rows: list.map((s) => AdaptiveRow(
                  cells: [
                    Text(s.symbol, style: const TextStyle(fontWeight: FontWeight.w500)),
                    StatusChip(s.klass),
                    Text('${s.minLot}/${s.maxLot}/${s.lotStep}'),
                    StatusChip(s.enabled ? 'Enabled' : 'Off', color: s.enabled ? tc.profit : null),
                  ],
                  actions: [
                    TextButton(onPressed: () => _edit(context, ref, s, refresh), child: const Text('Edit')),
                    TextButton(
                      onPressed: () async { await api.patch('/symbols/${s.id}/enabled', {'enabled': !s.enabled}); await refresh(); },
                      child: Text(s.enabled ? 'Disable' : 'Enable'),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: tc.loss, size: 18),
                      onPressed: () async { await api.delete('/symbols/${s.id}'); await refresh(); },
                    ),
                  ],
                )).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, TradeSymbol? s, Future<void> Function() refresh) async {
    final api = ref.read(apiClientProvider);
    final symbol = TextEditingController(text: s?.symbol ?? '');
    final desc = TextEditingController(text: s?.description ?? '');
    final base = TextEditingController();
    final quote = TextEditingController();
    final contract = TextEditingController(text: '100000');
    final minLot = TextEditingController(text: '${s?.minLot ?? 0.01}');
    final maxLot = TextEditingController(text: '${s?.maxLot ?? 100}');
    final lotStep = TextEditingController(text: '${s?.lotStep ?? 0.01}');
    final slippage = TextEditingController(text: '0');
    String klass = s?.klass ?? 'FOREX';
    final isEdit = s != null;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit ${s.symbol}' : 'Add symbol'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: TextField(controller: symbol, enabled: !isEdit, decoration: const InputDecoration(labelText: 'Symbol'))),
                const SizedBox(width: 8),
                Expanded(child: DropdownButtonFormField<String>(
                  initialValue: klass,
                  items: const ['FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => klass = v ?? 'FOREX',
                  decoration: const InputDecoration(labelText: 'Class'),
                )),
              ]),
              const SizedBox(height: 8),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: base, decoration: const InputDecoration(labelText: 'Base ccy'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: quote, decoration: const InputDecoration(labelText: 'Quote ccy'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: contract, decoration: const InputDecoration(labelText: 'Contract size'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: minLot, decoration: const InputDecoration(labelText: 'Min lot'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: maxLot, decoration: const InputDecoration(labelText: 'Max lot'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: lotStep, decoration: const InputDecoration(labelText: 'Lot step'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: slippage, decoration: const InputDecoration(labelText: 'Slippage pts'))),
              ]),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final body = {
                'symbol': symbol.text, 'description': desc.text, 'class': klass,
                'baseCurrency': base.text, 'quoteCurrency': quote.text,
                'contractSize': double.tryParse(contract.text) ?? 100000,
                'minLot': double.tryParse(minLot.text) ?? 0.01,
                'maxLot': double.tryParse(maxLot.text) ?? 100,
                'lotStep': double.tryParse(lotStep.text) ?? 0.01,
                'slippagePoints': int.tryParse(slippage.text) ?? 0,
              };
              if (isEdit) {
                await api.patch('/symbols/${s.id}', body);
              } else {
                await api.post('/symbols', body);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              await refresh();
            },
            child: Text(isEdit ? 'Save' : 'Create'),
          ),
        ],
      ),
    );
  }
}
