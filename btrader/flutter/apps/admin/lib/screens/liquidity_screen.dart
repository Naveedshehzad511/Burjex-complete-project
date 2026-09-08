import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

/// Liquidity providers + live multi-source spread monitor. Each provider is a
/// "company" feeding prices; market-data keeps their quotes separate so the desk
/// can compare spreads side-by-side (foundation for best-spread routing).
class LiquidityScreen extends ConsumerWidget {
  const LiquidityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminPage(
      title: 'Liquidity — Providers & Spreads',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: () {
            ref.invalidate(liquidityProvidersProvider);
            ref.invalidate(liquidityMonitorProvider);
          },
        ),
      ],
      child: DefaultTabController(
        length: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: const TabBar(
              isScrollable: true,
              labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              tabs: [
                Tab(height: 38, child: _TabLabel(Icons.hub_outlined, 'Providers')),
                Tab(height: 38, child: _TabLabel(Icons.speed_outlined, 'Spread Monitor')),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(children: [_ProvidersTab(), _MonitorTab()]),
          ),
        ]),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(label)]);
}

String _shortErr(Object e) {
  final s = e.toString();
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

const List<String> _transports = ['MT5_PUSH', 'WS_PULL', 'FIX_PULL'];
const List<String> _drivers = ['MT5', 'PRIMEXM', 'CENTROID', 'ONEZERO', 'MOCK'];
const List<String> _instrumentClasses = ['FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM'];
String _transportLabel(String t) => switch (t) {
      'MT5_PUSH' => 'MT5 push (bridge → /ingest)',
      'WS_PULL' => 'WebSocket / REST pull',
      'FIX_PULL' => 'FIX session (connector pending)',
      _ => t,
    };

// ═══════════════════════════════════════════════════════════════════════════
//  Providers tab
// ═══════════════════════════════════════════════════════════════════════════
class _ProvidersTab extends ConsumerWidget {
  const _ProvidersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(liquidityProvidersProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    return providers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load providers: ${_shortErr(e)}'),
      ),
      data: (list) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.hub_outlined, size: 18),
            const SizedBox(width: 8),
            const Text('Liquidity providers', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => _openDialog(context, ref, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add provider'),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Each provider feeds prices independently. In PRIMARY mode the provider marked primary (or the legacy feed) '
            'drives client pricing; in BEST-SPREAD mode the narrowest fresh spread per symbol wins. Others are captured '
            'for the monitor. MT5 providers post to the feed endpoint with their own token.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 14),
          const _PricingPolicyCard(),
          const SizedBox(height: 14),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No providers yet — add one per LP/company.', style: TextStyle(color: Theme.of(context).hintColor)),
            )
          else
            for (final p in list) ...[
              _providerCard(context, ref, Map<String, dynamic>.from(p as Map), tc),
              const SizedBox(height: 12),
            ],
        ]),
      ),
    );
  }

  Widget _providerCard(BuildContext context, WidgetRef ref, Map<String, dynamic> p, TradeColors tc) {
    final line = Theme.of(context).dividerColor;
    final enabled = p['enabled'] == true;
    final primary = p['isPrimaryFeed'] == true;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${p['name']}  ·  ${p['code']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(width: 10),
          if (primary) _pill('PRIMARY', Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          _pill(enabled ? 'ENABLED' : 'DISABLED', enabled ? tc.profit : tc.loss),
          const Spacer(),
          IconButton(
            tooltip: 'Symbol map',
            icon: const Icon(Icons.swap_horiz, size: 18),
            onPressed: () => showDialog<void>(context: context, builder: (_) => _SymbolMapDialog(provider: p)),
          ),
          IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _openDialog(context, ref, p)),
          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _delete(context, ref, p)),
        ]),
        const SizedBox(height: 4),
        Text('${_transportLabel(p['transport']?.toString() ?? '')}  ·  execution driver ${p['driver']}  ·  stale > ${p['staleMs']}ms',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        if ((p['transport']?.toString() ?? '') == 'MT5_PUSH' && p['feedToken'] != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Text('Feed token: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Expanded(
              child: SelectableText(
                p['feedToken'].toString(),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                maxLines: 1,
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 15),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: p['feedToken'].toString()));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token copied')));
              },
            ),
          ]),
          Text('Set this as FeedToken (X-Feed-Token) in the bridge config.json on this LP\'s MT5 VPS.',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        ],
        if ((p['transport']?.toString() ?? '') != 'MT5_PUSH' && p['feedEndpoint'] != null) ...[
          const SizedBox(height: 6),
          Text('Endpoint: ${p['feedEndpoint']}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ],
      ]),
    );
  }

  static Widget _pill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Future<void> _openDialog(BuildContext context, WidgetRef ref, Map<String, dynamic>? existing) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _ProviderDialog(existing: existing));
    if (saved == true) {
      ref.invalidate(liquidityProvidersProvider);
      ref.invalidate(liquidityMonitorProvider);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete provider?'),
        content: Text('Remove "${p['name']}" (${p['code']})? Its feed will stop being captured.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).delete('/admin/liquidity/${p['id']}');
      ref.invalidate(liquidityProvidersProvider);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Provider deleted')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_shortErr(e))));
    }
  }
}

/// Client-pricing policy: PRIMARY (single feed) vs BEST_SPREAD (+hysteresis).
class _PricingPolicyCard extends ConsumerStatefulWidget {
  const _PricingPolicyCard();
  @override
  ConsumerState<_PricingPolicyCard> createState() => _PricingPolicyCardState();
}

class _PricingPolicyCardState extends ConsumerState<_PricingPolicyCard> {
  String? _mode;
  final _margin = TextEditingController();
  bool _busy = false;
  bool _seeded = false;

  @override
  void dispose() {
    _margin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final policy = ref.watch(liquidityPricingProvider);
    final line = Theme.of(context).dividerColor;

    return policy.when(
      loading: () => const SizedBox(height: 2, child: LinearProgressIndicator()),
      error: (e, _) => Text('Pricing policy unavailable: ${_shortErr(e)}', style: const TextStyle(fontSize: 12)),
      data: (p) {
        if (!_seeded) {
          _mode = (p['pricingMode'] ?? 'PRIMARY').toString();
          _margin.text = (p['bestSpreadMarginPoints'] ?? 0).toString();
          _seeded = true;
        }
        final isBest = _mode == 'BEST_SPREAD';
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.tune, size: 18),
            const SizedBox(width: 10),
            const Text('Client pricing', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 18),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'PRIMARY', label: Text('Primary feed')),
                ButtonSegment(value: 'BEST_SPREAD', label: Text('Best spread')),
              ],
              selected: {_mode ?? 'PRIMARY'},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(width: 18),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _margin,
                enabled: isBest,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Switch margin (pts)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).put('/admin/liquidity/pricing', {
        'pricingMode': _mode,
        'bestSpreadMarginPoints': int.tryParse(_margin.text) ?? 0,
      });
      ref.invalidate(liquidityPricingProvider);
      ref.invalidate(liquidityMonitorProvider);
      if (mounted) {
        if (res is Map && res['error'] != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pricing policy saved')));
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_shortErr(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ProviderDialog extends ConsumerStatefulWidget {
  const _ProviderDialog({this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<_ProviderDialog> {
  late final _name = TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final _code = TextEditingController(text: widget.existing?['code']?.toString() ?? '');
  late final _stale = TextEditingController(text: (widget.existing?['staleMs'] ?? 2000).toString());
  late final _endpoint = TextEditingController(text: widget.existing?['feedEndpoint']?.toString() ?? '');
  late final _sender = TextEditingController(text: widget.existing?['senderCompId']?.toString() ?? '');
  late final _target = TextEditingController(text: widget.existing?['targetCompId']?.toString() ?? '');
  late final _credRef = TextEditingController(text: widget.existing?['credentialRef']?.toString() ?? '');
  late final _suffix = TextEditingController(text: widget.existing?['symbolSuffix']?.toString() ?? '');
  late final Map<String, TextEditingController> _classSuffix = {
    for (final c in _instrumentClasses)
      c: TextEditingController(
        text: ((widget.existing?['suffixByClass'] as Map?)?[c] ?? '').toString(),
      ),
  };
  late String _transport = widget.existing?['transport']?.toString() ?? 'MT5_PUSH';
  late String _driver = widget.existing?['driver']?.toString() ?? 'MT5';
  late bool _enabled = widget.existing?['enabled'] != false;
  late bool _primary = widget.existing?['isPrimaryFeed'] == true;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _stale.dispose();
    _endpoint.dispose();
    _sender.dispose();
    _target.dispose();
    _credRef.dispose();
    _suffix.dispose();
    for (final c in _classSuffix.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPush = _transport == 'MT5_PUSH';
    InputDecoration dec(String l, {String? help}) =>
        InputDecoration(labelText: l, helperText: help, border: const OutlineInputBorder(), isDense: true);

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add provider' : 'Edit provider'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: TextField(controller: _name, decoration: dec('Name'))),
              const SizedBox(width: 12),
              SizedBox(width: 140, child: TextField(controller: _code, decoration: dec('Code', help: 'A-Z 0-9 _ -'))),
            ]),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _transport,
              decoration: dec('Feed transport'),
              items: [for (final t in _transports) DropdownMenuItem(value: t, child: Text(_transportLabel(t)))],
              onChanged: (v) => setState(() => _transport = v ?? 'MT5_PUSH'),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _driver,
              decoration: dec('Execution driver', help: 'How covers execute on this LP (used later for routing)'),
              items: [for (final d in _drivers) DropdownMenuItem(value: d, child: Text(d))],
              onChanged: (v) => setState(() => _driver = v ?? 'MT5'),
            ),
            if (isPush)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.existing == null
                      ? 'A feed token will be generated on save — put it in this LP\'s bridge config.json.'
                      : 'Feed token is shown on the provider card after saving.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              )
            else ...[
              const SizedBox(height: 14),
              TextField(controller: _endpoint, decoration: dec('Feed endpoint (WS/REST URL or FIX host:port)')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(controller: _sender, decoration: dec('SenderCompID'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _target, decoration: dec('TargetCompID'))),
              ]),
              const SizedBox(height: 12),
              TextField(controller: _credRef, decoration: dec('Credential ref', help: 'Secret read from LP_SECRET_<ref>')),
            ],
            const SizedBox(height: 14),
            Row(children: [
              SizedBox(width: 150, child: TextField(controller: _stale, keyboardType: TextInputType.number, decoration: dec('Stale (ms)'))),
              const SizedBox(width: 12),
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Enabled'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Primary feed'),
              subtitle: const Text('Drives client pricing (only one provider)', style: TextStyle(fontSize: 11)),
              value: _primary,
              onChanged: (v) => setState(() => _primary = v),
            ),
            const Divider(height: 24),
            const Row(children: [
              Icon(Icons.swap_horiz, size: 16),
              SizedBox(width: 6),
              Text('Symbol mapping', style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text('Strip this LP\'s suffix so its names match yours (e.g. ".a" → EURUSD.a becomes EURUSD). '
                'Per-class overrides win for that class; explicit per-symbol maps are on the provider card.',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 10),
            SizedBox(width: 220, child: TextField(controller: _suffix, decoration: dec('Default suffix', help: 'e.g. .a'))),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in _instrumentClasses)
                SizedBox(
                  width: 140,
                  child: TextField(controller: _classSuffix[c], decoration: dec('$c suffix')),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _code.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and code required')));
      return;
    }
    setState(() => _busy = true);
    final body = {
      'name': _name.text.trim(),
      'code': _code.text.trim().toUpperCase(),
      'transport': _transport,
      'driver': _driver,
      'enabled': _enabled,
      'isPrimaryFeed': _primary,
      'staleMs': int.tryParse(_stale.text) ?? 2000,
      'feedEndpoint': _endpoint.text.isEmpty ? null : _endpoint.text,
      'senderCompId': _sender.text.isEmpty ? null : _sender.text,
      'targetCompId': _target.text.isEmpty ? null : _target.text,
      'credentialRef': _credRef.text.isEmpty ? null : _credRef.text,
      'symbolSuffix': _suffix.text.trim().isEmpty ? null : _suffix.text.trim(),
      'suffixByClass': {
        for (final e in _classSuffix.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      },
    };
    try {
      final api = ref.read(apiClientProvider);
      final id = widget.existing?['id'];
      final res = id == null ? await api.post('/admin/liquidity', body) : await api.put('/admin/liquidity/$id', body);
      if (res is Map && res['error'] != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
        setState(() => _busy = false);
        return;
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_shortErr(e))));
      setState(() => _busy = false);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Explicit symbol-map editor (per provider) + unmapped helper
// ═══════════════════════════════════════════════════════════════════════════
class _SymbolMapDialog extends ConsumerStatefulWidget {
  const _SymbolMapDialog({required this.provider});
  final Map<String, dynamic> provider;
  @override
  ConsumerState<_SymbolMapDialog> createState() => _SymbolMapDialogState();
}

class _SymbolMapDialogState extends ConsumerState<_SymbolMapDialog> {
  final _raw = TextEditingController();
  String? _symbolId;
  bool _busy = false;

  String get _pid => widget.provider['id'].toString();
  String get _code => widget.provider['code'].toString();

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maps = ref.watch(liquiditySymbolMapsProvider(_pid));
    final symbols = ref.watch(adminSymbolsProvider);
    final unmapped = ref.watch(liquidityUnmappedProvider);
    final hint = Theme.of(context).hintColor;

    return AlertDialog(
      title: Text('Symbol map · ${widget.provider['code']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Explicit overrides for names a suffix can\'t fix (e.g. GOLD → XAUUSD). Checked before suffixes.',
                style: TextStyle(fontSize: 12, color: hint)),
            const SizedBox(height: 12),
            // Add row
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 150,
                child: TextField(controller: _raw, decoration: const InputDecoration(labelText: 'LP raw symbol', border: OutlineInputBorder(), isDense: true)),
              ),
              const SizedBox(width: 8),
              const Padding(padding: EdgeInsets.only(top: 12), child: Icon(Icons.arrow_forward, size: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: symbols.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text(_shortErr(e), style: const TextStyle(fontSize: 12)),
                  data: (list) => DropdownButtonFormField<String>(
                    initialValue: _symbolId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Your symbol', border: OutlineInputBorder(), isDense: true),
                    items: [for (final s in list) DropdownMenuItem(value: s.id, child: Text(s.symbol))],
                    onChanged: (v) => setState(() => _symbolId = v),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FilledButton(onPressed: _busy ? null : _add, child: const Text('Add')),
              ),
            ]),
            const SizedBox(height: 16),
            maps.when(
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              error: (e, _) => Text(_shortErr(e), style: const TextStyle(fontSize: 12)),
              data: (list) => list.isEmpty
                  ? Text('No explicit mappings.', style: TextStyle(color: hint))
                  : Column(children: [
                      for (final m in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${(m as Map)['rawSymbol']}  →  ${m['symbolName'] ?? m['symbolId']}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _remove(m['id'].toString()),
                          ),
                        ),
                    ]),
            ),
            const Divider(height: 24),
            const Text('Unmapped seen (from this LP) — click to prefill', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
            const SizedBox(height: 6),
            unmapped.when(
              loading: () => const SizedBox.shrink(),
              error: (e, _) => const SizedBox.shrink(),
              data: (list) {
                final mine = list.where((u) => (u as Map)['code'].toString() == _code).toList();
                if (mine.isEmpty) return Text('None — everything is matching. 🎉', style: TextStyle(color: hint, fontSize: 12));
                return Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final u in mine)
                    ActionChip(
                      label: Text((u as Map)['rawSymbol'].toString()),
                      onPressed: () => setState(() => _raw.text = u['rawSymbol'].toString()),
                    ),
                ]);
              },
            ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }

  Future<void> _add() async {
    final raw = _raw.text.trim().toUpperCase();
    if (raw.isEmpty || _symbolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the raw symbol and pick yours')));
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).post('/admin/liquidity/$_pid/symbol-maps', {
        'lpProviderId': _pid,
        'rawSymbol': raw,
        'symbolId': _symbolId,
      });
      if (res is Map && res['error'] != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error'].toString())));
      } else {
        _raw.clear();
        ref.invalidate(liquiditySymbolMapsProvider(_pid));
        ref.invalidate(liquidityUnmappedProvider);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_shortErr(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String mapId) async {
    try {
      await ref.read(apiClientProvider).delete('/admin/liquidity/symbol-maps/$mapId');
      ref.invalidate(liquiditySymbolMapsProvider(_pid));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_shortErr(e))));
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Spread monitor tab
// ═══════════════════════════════════════════════════════════════════════════
class _MonitorTab extends ConsumerWidget {
  const _MonitorTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mon = ref.watch(liquidityMonitorProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    return mon.when(
      // Keep the table rendered during the 2s live reload (update values in place).
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('Monitor unavailable: ${_shortErr(e)}')),
      data: (m) {
        final symbols = (m['symbols'] as List?) ?? const [];
        if (symbols.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No live quotes captured yet. Add providers and point their feeds at the ingest endpoint;\n'
                'each provider\'s quotes will appear here for spread comparison.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: symbols.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _symbolCard(context, Map<String, dynamic>.from(symbols[i] as Map), tc),
        );
      },
    );
  }

  Widget _symbolCard(BuildContext context, Map<String, dynamic> s, TradeColors tc) {
    final line = Theme.of(context).dividerColor;
    final digits = (s['digits'] ?? 5) as int;
    final quotes = (s['quotes'] as List?) ?? const [];
    final best = s['bestCode']?.toString();
    final active = s['activeCode']?.toString();
    String fmt(num? v) => v == null ? '—' : v.toDouble().toStringAsFixed(digits);
    String spread(num? v) => v == null ? '—' : (v.toDouble() * _pow10(digits)).toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(s['symbol']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const Spacer(),
          if (active != null) ...[
            Icon(Icons.bolt, size: 14, color: Theme.of(context).colorScheme.primary),
            Text('live: $active',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
            const SizedBox(width: 14),
          ],
          if (best != null) ...[
            Icon(Icons.star, size: 13, color: tc.profit),
            Text('best: $best', style: TextStyle(fontSize: 12, color: tc.profit, fontWeight: FontWeight.w700)),
          ],
        ]),
        const SizedBox(height: 8),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(2),
            1: FlexColumnWidth(2),
            2: FlexColumnWidth(2),
            3: FlexColumnWidth(2),
            4: FlexColumnWidth(2),
          },
          children: [
            TableRow(
              decoration: BoxDecoration(color: Theme.of(context).hoverColor),
              children: [
                _th(context, 'PROVIDER'),
                _th(context, 'BID'),
                _th(context, 'ASK'),
                _th(context, 'SPREAD (pts)'),
                _th(context, 'AGE'),
              ],
            ),
            for (final q in quotes)
              _quoteRow(context, Map<String, dynamic>.from(q as Map), best, active, tc, fmt, spread),
          ],
        ),
      ]),
    );
  }

  TableRow _quoteRow(
    BuildContext context,
    Map<String, dynamic> q,
    String? best,
    String? active,
    TradeColors tc,
    String Function(num?) fmt,
    String Function(num?) spread,
  ) {
    final code = q['code']?.toString() ?? '';
    final stale = q['stale'] == true;
    final isBest = code == best;
    final isActive = code == active;
    final age = (q['ageMs'] as num?)?.toDouble() ?? 0;
    final primary = Theme.of(context).colorScheme.primary;
    final color = stale ? Theme.of(context).disabledColor : null;
    Widget cell(String v, {Color? c, FontWeight? w}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Text(v, style: TextStyle(fontSize: 12.5, color: c ?? color, fontWeight: w, fontFeatures: const [FontFeature.tabularFigures()])),
        );
    return TableRow(
      // Active source (driving client price) tinted with the brand colour; the
      // narrowest-spread source is starred (may differ from active under hysteresis).
      decoration: isActive
          ? BoxDecoration(color: primary.withValues(alpha: 0.12))
          : isBest
              ? BoxDecoration(color: tc.profit.withValues(alpha: 0.08))
              : null,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Row(children: [
            if (isActive) Icon(Icons.bolt, size: 13, color: primary),
            if (isBest) Icon(Icons.star, size: 13, color: tc.profit),
            if (isActive || isBest) const SizedBox(width: 4),
            Text(code, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
            if (stale) Text('  (stale)', style: TextStyle(fontSize: 10.5, color: Theme.of(context).disabledColor)),
          ]),
        ),
        cell(fmt(q['bid'] as num?)),
        cell(fmt(q['ask'] as num?)),
        cell(spread(q['spread'] as num?), c: isBest ? tc.profit : color, w: isBest ? FontWeight.w700 : null),
        cell('${(age / 1000).toStringAsFixed(1)}s'),
      ],
    );
  }

  Widget _th(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(s, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
      );

  double _pow10(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
