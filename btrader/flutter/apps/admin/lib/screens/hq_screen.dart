import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';
import '../widgets/adaptive_table.dart';

/// Central HQ dashboard: every separately-deployed company server, polled via
/// its read-only /hq/overview token. Super-admin only.
final hqCompaniesProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/hq/servers/companies') as List;
});

class HqScreen extends ConsumerWidget {
  const HqScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).role;
    if (role != 'SUPER_ADMIN') {
      return const AdminPage(title: 'Companies (HQ)', child: Center(child: Text('Super-admin only.')));
    }
    final companies = ref.watch(hqCompaniesProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(hqCompaniesProvider);

    return AdminPage(
      title: 'Companies (HQ)',
      actions: [
        IconButton(onPressed: refresh, icon: const Icon(Icons.refresh), tooltip: 'Poll all servers'),
        FilledButton.icon(
          onPressed: () => _editServer(context, ref, null, refresh),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add company server'),
        ),
      ],
      child: companies.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                'No company servers registered.\nEach separate deployment exposes a read-only\n/hq/overview — add its URL + HQ token here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            );
          }
          return SingleChildScrollView(
            child: AdaptiveTable(
              columns: const ['Company', 'Server', 'Status', 'Clients', 'Accounts', 'Balance Σ', 'Open pos', 'Covers pend.', 'Vol today'],
              rows: list.map((c) {
                final ok = c['ok'] == true;
                final tenants = (c['overview']?['tenants'] as List?) ?? const [];
                num sumI(String k) => tenants.fold<num>(0, (a, t) => a + ((t[k] ?? 0) as num));
                double sumD(String k) => tenants.fold<double>(0, (a, t) => a + (double.tryParse('${t[k] ?? '0'}') ?? 0));
                final label = tenants.length > 1 ? '${c['name']} (${tenants.length} tenants)' : '${c['name']}';
                return AdaptiveRow(
                  cells: [
                    Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('${c['baseUrl']}', overflow: TextOverflow.ellipsis),
                    StatusChip(ok ? 'ONLINE' : '${c['error'] ?? 'OFFLINE'}'.toUpperCase(), color: ok ? tc.profit : tc.loss),
                    Text(ok ? '${sumI('clients')}' : '—'),
                    Text(ok ? '${sumI('accounts')}' : '—'),
                    Text(ok ? sumD('balanceSum').toStringAsFixed(2) : '—'),
                    Text(ok ? '${sumI('openPositions')}' : '—'),
                    Text(ok ? '${sumI('pendingCovers')}' : '—'),
                    Text(ok ? sumD('volumeToday').toStringAsFixed(2) : '—'),
                  ],
                  actions: [
                    TextButton(onPressed: () => _editServer(context, ref, c, refresh), child: const Text('Edit')),
                    TextButton(
                      onPressed: () => _removeServer(context, ref, c, refresh),
                      child: Text('Remove', style: TextStyle(color: tc.loss)),
                    ),
                  ],
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editServer(BuildContext context, WidgetRef ref, dynamic existing, Future<void> Function() refresh) async {
    final name = TextEditingController(text: existing?['name'] ?? '');
    final baseUrl = TextEditingController(text: existing?['baseUrl'] ?? '');
    final token = TextEditingController();
    final api = ref.read(apiClientProvider);
    bool enabled = existing?['enabled'] ?? true;
    bool busy = false;
    String? error;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Add company server' : 'Edit — ${existing['name']}'),
          content: SizedBox(
            width: 430,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Company name')),
              const SizedBox(height: 10),
              TextField(
                controller: baseUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'API base URL', hintText: 'https://api.company.com'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: existing == null ? 'HQ token (that server\'s HQ_TOKEN)' : 'HQ token (empty = keep current)',
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled (poll this server)'),
                value: enabled,
                onChanged: (v) => setLocal(() => enabled = v),
              ),
              if (error != null) Text(error!, style: const TextStyle(color: Color(0xFFE5484D))),
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() { busy = true; error = null; });
                      try {
                        final body = {
                          'name': name.text.trim(),
                          'baseUrl': baseUrl.text.trim(),
                          if (token.text.trim().isNotEmpty) 'token': token.text.trim(),
                          'enabled': enabled,
                        };
                        if (existing == null) {
                          await api.post('/hq/servers', body);
                        } else {
                          await api.patch('/hq/servers/${existing['id']}', body);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        await refresh();
                      } catch (_) {
                        setLocal(() { busy = false; error = 'Save failed — check the URL and token.'; });
                      }
                    },
              child: Text(busy ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeServer(BuildContext context, WidgetRef ref, dynamic c, Future<void> Function() refresh) async {
    final api = ref.read(apiClientProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${c['name']}?'),
        content: const Text('Removes it from the HQ dashboard only — the company server itself is untouched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await api.delete('/hq/servers/${c['id']}');
      await refresh();
    }
  }
}
