import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';
import '../widgets/adaptive_table.dart';

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});
  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  String _action = '';
  static const _actions = ['', 'ORDER_PLACE', 'ORDER_CANCEL', 'POSITION_CLOSE', 'POSITION_MODIFY', 'BALANCE_ADJUST', 'LEVERAGE_CHANGE', 'SYMBOL_CHANGE', 'TENANT_CHANGE', 'FORCE_LOGOUT', 'CREATE', 'UPDATE'];

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(auditProvider(_action));
    return AdminPage(
      title: 'Audit Log',
      actions: [
        DropdownButton<String>(
          value: _action,
          items: _actions.map((a) => DropdownMenuItem(value: a, child: Text(a.isEmpty ? 'All actions' : a))).toList(),
          onChanged: (v) => setState(() => _action = v ?? ''),
        ),
      ],
      child: logs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No audit entries.'))
            : SingleChildScrollView(child: AdaptiveTable(
                columns: const ['Time', 'Action', 'Entity', 'Actor', 'IP'],
                rows: list.map((l) => AdaptiveRow(cells: [
                  Text(dateTime(l.createdAt)),
                  StatusChip(l.action),
                  Text('${l.entity ?? '—'}${l.entityId != null ? ' · ${l.entityId!.substring(0, l.entityId!.length.clamp(0, 8))}' : ''}'),
                  Text('${l.actorType ?? ''}:${(l.actorId ?? '').substring(0, (l.actorId ?? '').length.clamp(0, 8))}'),
                  Text(l.ip ?? '—'),
                ])).toList(),
              )),
      ),
    );
  }
}
