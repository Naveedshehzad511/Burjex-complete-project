import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../shell.dart';
import '../widgets/adaptive_table.dart';

/// CRM webhook config for this tenant.
final crmConfigProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/crm/config') as Map<String, dynamic>;
});

/// Inbound API keys this tenant's CRM uses to call B-Trader.
final crmKeysProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiClientProvider);
  return (await api.get('/admin/crm/keys') as List).cast<Map<String, dynamic>>();
});

/// CRM / Integrations console: configure the tenant's outbound webhook and
/// mint the inbound API keys their CRM uses to push deposits/withdrawals and
/// read balances. Each broker plugs in their own CRM here — fully isolated.
class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(crmConfigProvider);
    final keys = ref.watch(crmKeysProvider);

    return AdminPage(
      title: 'CRM / Integrations',
      child: ListView(children: [
        const _SectionTitle('Outbound webhook', 'B-Trader pushes signed trading events to your CRM.'),
        cfg.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _ErrorCard('$e'),
          data: (c) => _WebhookCard(config: c),
        ),
        const SizedBox(height: 28),
        Row(children: [
          const Expanded(child: _SectionTitle('Inbound API keys', 'Your CRM uses these to call B-Trader (deposits, reads).')),
          FilledButton.icon(
            onPressed: () => _createKey(context, ref),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New key'),
          ),
        ]),
        const SizedBox(height: 8),
        keys.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _ErrorCard('$e'),
          data: (list) => _KeysTable(keys: list, onRevoke: (keyId) async {
            final api = ref.read(apiClientProvider);
            await api.delete('/admin/crm/keys/$keyId');
            ref.invalidate(crmKeysProvider);
          }),
        ),
      ]),
    );
  }

  Future<void> _createKey(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: 'CRM key');
    final ips = TextEditingController();
    final api = ref.read(apiClientProvider);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New inbound API key'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name / label')),
            const SizedBox(height: 10),
            TextField(controller: ips, decoration: const InputDecoration(labelText: 'IP allowlist (comma-separated, optional)', hintText: '203.0.113.5, 198.51.100.0')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final ipList = ips.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
              final res = await api.post('/admin/crm/keys', {'name': name.text, 'ipAllowlist': ipList}) as Map<String, dynamic>;
              if (ctx.mounted) Navigator.pop(ctx);
              ref.invalidate(crmKeysProvider);
              if (context.mounted) await _showSecret(context, res);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// The secret is shown exactly once — make the operator copy it now.
  Future<void> _showSecret(BuildContext context, Map<String, dynamic> res) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API key created'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Copy the secret now — it is shown only once and cannot be retrieved again.',
                style: TextStyle(color: Color(0xFFEF9F27))),
            const SizedBox(height: 16),
            _CopyField('Key ID', '${res['keyId']}'),
            const SizedBox(height: 10),
            _CopyField('Secret', '${res['secret']}'),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }
}

class _WebhookCard extends ConsumerStatefulWidget {
  const _WebhookCard({required this.config});
  final Map<String, dynamic> config;
  @override
  ConsumerState<_WebhookCard> createState() => _WebhookCardState();
}

class _WebhookCardState extends ConsumerState<_WebhookCard> {
  late final TextEditingController _url;
  late final TextEditingController _secret;
  late bool _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.config['webhookUrl']?.toString() ?? '');
    _secret = TextEditingController();
    _enabled = widget.config['enabled'] == true;
  }

  @override
  void dispose() {
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSecret = widget.config['hasSecret'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _url, decoration: const InputDecoration(labelText: 'Webhook URL', hintText: 'https://crm.example.com/btrader/webhook')),
          const SizedBox(height: 12),
          TextField(
            controller: _secret,
            decoration: InputDecoration(
              labelText: 'Signing secret',
              hintText: hasSecret ? '•••••• (leave blank to keep current)' : 'Set an HMAC signing secret',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Deliver events to this CRM endpoint'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final api = ref.read(apiClientProvider);
      await api.put('/admin/crm/config', {
        'webhookUrl': _url.text.trim().isEmpty ? null : _url.text.trim(),
        if (_secret.text.isNotEmpty) 'webhookSecret': _secret.text,
        'enabled': _enabled,
      });
      ref.invalidate(crmConfigProvider);
      if (mounted) {
        _secret.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Webhook saved')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _KeysTable extends StatelessWidget {
  const _KeysTable({required this.keys, required this.onRevoke});
  final List<Map<String, dynamic>> keys;
  final Future<void> Function(String keyId) onRevoke;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (keys.isEmpty) {
      return const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No API keys yet.')));
    }
    return AdaptiveTable(
      columns: const ['Name', 'Key ID', 'Scopes', 'IP allowlist', 'Status'],
      rows: keys.map((k) {
        final revoked = k['revokedAt'] != null;
        final scopes = (k['scopes'] as List?)?.join(', ') ?? '';
        final ips = (k['ipAllowlist'] as List?)?.join(', ') ?? '';
        return AdaptiveRow(
          cells: [
            Text('${k['name'] ?? ''}'),
            SelectableText('${k['keyId'] ?? ''}', style: const TextStyle(fontFamily: 'monospace')),
            Text(scopes),
            Text(ips.isEmpty ? 'any' : ips),
            Text(revoked ? 'Revoked' : 'Active', style: TextStyle(color: revoked ? tc.loss : tc.profit)),
          ],
          actions: revoked
              ? const []
              : [TextButton(onPressed: () => onRevoke('${k['keyId']}'), child: Text('Revoke', style: TextStyle(color: tc.loss)))],
        );
      }).toList(),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.subtitle);
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text(subtitle, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
      const SizedBox(height: 10),
    ]);
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace'))),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
          },
        ),
      ]),
    ]);
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;
  @override
  Widget build(BuildContext context) =>
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(message)));
}
