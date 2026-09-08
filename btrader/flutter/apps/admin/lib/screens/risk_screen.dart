import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';

class RiskScreen extends ConsumerStatefulWidget {
  const RiskScreen({super.key});
  @override
  ConsumerState<RiskScreen> createState() => _RiskScreenState();
}

class _RiskScreenState extends ConsumerState<RiskScreen> {
  final _scope = TextEditingController(text: 'tenant');
  final _maxLot = TextEditingController();
  final _maxOpenLots = TextEditingController();
  final _maxPos = TextEditingController();
  final _maxExp = TextEditingController();

  Future<void> _save() async {
    final body = <String, dynamic>{'scope': _scope.text, 'enabled': true};
    if (_maxLot.text.isNotEmpty) body['maxLotPerOrder'] = double.tryParse(_maxLot.text);
    if (_maxOpenLots.text.isNotEmpty) body['maxOpenLots'] = double.tryParse(_maxOpenLots.text);
    if (_maxPos.text.isNotEmpty) body['maxOpenPositions'] = int.tryParse(_maxPos.text);
    if (_maxExp.text.isNotEmpty) body['maxNetExposure'] = double.tryParse(_maxExp.text);
    await ref.read(apiClientProvider).post('/risk/limits', body);
    ref.invalidate(riskLimitsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final limits = ref.watch(riskLimitsProvider);
    final alerts = ref.watch(marginAlertsProvider);
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    return AdminPage(
      title: 'Risk Management',
      child: ListView(children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Text('Live margin alerts', style: TextStyle(fontWeight: FontWeight.w500)), const Spacer(),
            alerts.maybeWhen(data: (a) => StatusChip('${a.length}', color: a.isEmpty ? tc.profit : tc.loss), orElse: () => const SizedBox.shrink())]),
          const SizedBox(height: 8),
          alerts.maybeWhen(
            skipLoadingOnReload: true,
            data: (a) => a.isEmpty ? const Text('All accounts healthy.') : Column(children: a.map((m) => ListTile(dense: true, title: Text('#${m.login}'),
                trailing: Text('${m.marginLevel.toStringAsFixed(0)}%', style: TextStyle(color: tc.loss)))).toList()),
            orElse: () => const SizedBox.shrink()),
        ]))),
        const SizedBox(height: 16),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Add / update limit', style: TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          TextField(controller: _scope, decoration: const InputDecoration(labelText: 'Scope (tenant | account:<id> | symbol:<id>)', border: OutlineInputBorder(), isDense: true)),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            // Two columns on phones, four on wide screens.
            final cols = c.maxWidth < 520 ? 2 : 4;
            final w = (c.maxWidth - (cols - 1) * 10) / cols;
            Widget f(TextEditingController ctrl, String label) => SizedBox(
                  width: w,
                  child: TextField(controller: ctrl, keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true)),
                );
            return Wrap(spacing: 10, runSpacing: 10, children: [
              f(_maxLot, 'Max lot/order'),
              f(_maxOpenLots, 'Max open lots'),
              f(_maxPos, 'Max positions'),
              f(_maxExp, 'Max exposure'),
            ]);
          }),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _save, child: const Text('Save limit'))),
        ]))),
        const SizedBox(height: 16),
        limits.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) => Card(child: list.isEmpty
              ? const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No limits set.')))
              : Column(children: list.map((l) => ListTile(
                  title: Text(l.scope, style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text('per order ${l.maxLotPerOrder ?? '—'} · open lots ${l.maxOpenLots ?? '—'} · positions ${l.maxOpenPositions ?? '—'} · exposure ${l.maxNetExposure ?? '—'}'),
                  trailing: IconButton(icon: Icon(Icons.delete_outline, color: tc.loss),
                    onPressed: () async { await api.delete('/risk/limits/${Uri.encodeComponent(l.scope)}'); ref.invalidate(riskLimitsProvider); }),
                )).toList())),
        ),
      ]),
    );
  }
}
