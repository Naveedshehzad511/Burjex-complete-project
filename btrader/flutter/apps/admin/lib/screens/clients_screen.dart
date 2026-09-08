import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';

class ClientsScreen extends ConsumerWidget {
  const ClientsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = ref.watch(clientsProvider);
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(clientsProvider);

    return AdminPage(
      title: 'Clients & Accounts',
      actions: [
        FilledButton.icon(
          onPressed: () => _createClient(context, ref, refresh),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New client'),
        ),
      ],
      child: clients.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No clients yet.'))
            : ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                for (final c in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: CircleAvatar(child: Text((c.name.isNotEmpty ? c.name[0] : c.email[0]).toUpperCase())),
                      // Name + status chip on top, email below — both ellipsised
                      // so they never wrap to vertical text on narrow screens.
                      title: Row(children: [
                        Expanded(
                          child: Text(c.name.isEmpty ? c.email : c.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 8),
                        StatusChip(c.isActive ? 'Active' : 'Disabled', color: c.isActive ? tc.profit : tc.loss),
                      ]),
                      subtitle: Text(c.email, maxLines: 1, overflow: TextOverflow.ellipsis),
                      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      children: [
                        // Client-level actions (wrap on narrow screens)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(spacing: 6, runSpacing: 4, children: [
                            OutlinedButton(
                              onPressed: () async {
                                await api.patch('/accounts/clients/${c.id}/active', {'isActive': !c.isActive});
                                await refresh();
                              },
                              child: Text(c.isActive ? 'Disable' : 'Enable'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await api.post('/accounts/clients/${c.id}/force-logout');
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sessions revoked')));
                              },
                              child: const Text('Force logout'),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 4),
                        // Trading accounts
                        for (final a in c.accounts)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              border: Border.all(color: Theme.of(context).dividerColor),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Expanded(
                                  child: Text('#${a.login} · ${a.type}',
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                                ),
                                StatusChip(a.status == 'ACTIVE' ? 'Trading' : a.status, color: a.status == 'ACTIVE' ? tc.profit : null),
                              ]),
                              const SizedBox(height: 4),
                              Text('Bal ${money(a.balance)} · Eq ${money(a.equity)} · P/L ${money(a.floatingPL)}',
                                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                              const SizedBox(height: 6),
                              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                OutlinedButton(
                                  onPressed: () async {
                                    await api.patch('/accounts/${a.id}/trading', {'enabled': a.status != 'ACTIVE'});
                                    await refresh();
                                  },
                                  child: Text(a.status == 'ACTIVE' ? 'Disable trading' : 'Enable trading'),
                                ),
                                DropdownButton<int>(
                                  value: a.leverage,
                                  isDense: true,
                                  items: const [1, 10, 20, 50, 100, 200, 500, 1000].map((l) => DropdownMenuItem(value: l, child: Text('1:$l'))).toList(),
                                  onChanged: (v) async {
                                    if (v == null) return;
                                    await api.patch('/accounts/${a.id}/leverage', {'leverage': v});
                                    await refresh();
                                  },
                                ),
                                OutlinedButton(
                                  onPressed: () => context.go('/journal?account=${a.id}&login=${a.login}'),
                                  child: const Text('Journal'),
                                ),
                                OutlinedButton(
                                  onPressed: () => context.go('/financial?account=${a.id}'),
                                  child: const Text('Funds'),
                                ),
                                OutlinedButton(
                                  onPressed: () => _setPassword(context, api, a.id, a.login),
                                  child: const Text('Password'),
                                ),
                              ]),
                            ]),
                          ),
                      ],
                    ),
                  ),
              ]),
      ),
    );
  }

  Future<void> _createClient(BuildContext context, WidgetRef ref, Future<void> Function() refresh) async {
    final first = TextEditingController();
    final last = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    String type = 'STANDARD';
    int leverage = 100;
    final api = ref.read(apiClientProvider);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New client + account'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: first, decoration: const InputDecoration(labelText: 'First name'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: last, decoration: const InputDecoration(labelText: 'Last name'))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: type,
                items: const ['STANDARD', 'ECN', 'RAW', 'ISLAMIC', 'DEMO'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (v) => type = v ?? 'STANDARD',
                decoration: const InputDecoration(labelText: 'Type'),
              )),
              const SizedBox(width: 8),
              Expanded(child: DropdownButtonFormField<int>(
                initialValue: leverage,
                items: const [10, 50, 100, 200, 500, 1000].map((l) => DropdownMenuItem(value: l, child: Text('1:$l'))).toList(),
                onChanged: (v) => leverage = v ?? 100,
                decoration: const InputDecoration(labelText: 'Leverage'),
              )),
            ]),
            const SizedBox(height: 10),
            TextField(controller: password, decoration: const InputDecoration(labelText: 'Password (blank = auto-generate)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final res = await api.post('/accounts/clients', {
                'firstName': first.text, 'lastName': last.text, 'email': email.text, 'type': type, 'leverage': leverage,
                if (password.text.trim().isNotEmpty) 'password': password.text.trim(),
              });
              if (ctx.mounted) Navigator.pop(ctx);
              await refresh();
              final login = (res['login'] ?? '').toString();
              final pw = (res['password'] ?? '').toString();
              if (context.mounted && pw.isNotEmpty) _showCredentials(context, login, pw);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// Set / reset an account's login password, then show it once.
  Future<void> _setPassword(BuildContext context, ApiClient api, String accountId, String login) async {
    final pw = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set password — #$login'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Set the login password for this account (min 6 characters). The client signs in with the account number + this password.',
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor)),
            const SizedBox(height: 12),
            TextField(controller: pw, decoration: const InputDecoration(labelText: 'New password')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (pw.text.trim().length < 6) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('At least 6 characters')));
                return;
              }
              try {
                await api.post('/accounts/$accountId/password', {'password': pw.text.trim()});
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) _showCredentials(context, login, pw.text.trim());
              } catch (e) {
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
              }
            },
            child: const Text('Set password'),
          ),
        ],
      ),
    );
  }

  /// Show the account number + password (copyable). Password is shown once.
  void _showCredentials(BuildContext context, String login, String password) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Account credentials'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Share these with the client. The password is not stored in readable form and cannot be shown again.',
              style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor)),
          const SizedBox(height: 12),
          _CredRow(label: 'Account', value: login),
          const SizedBox(height: 8),
          _CredRow(label: 'Password', value: password),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }
}

class _CredRow extends StatelessWidget {
  const _CredRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 76, child: Text(label, style: TextStyle(color: Theme.of(context).hintColor))),
        Expanded(child: SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w700))),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1)));
          },
        ),
      ]);
}
