import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../util/logo_picker.dart';

import '../admin_providers.dart';
import '../shell.dart';
import '../widgets/stat_card.dart';
import '../widgets/adaptive_table.dart';

/// Super-admin tenant console: create (with branding), suspend, activate, delete.
class TenantsScreen extends ConsumerWidget {
  const TenantsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).role;
    if (role != 'SUPER_ADMIN') {
      return const AdminPage(title: 'Tenants', child: Center(child: Text('Super-admin only.')));
    }
    final tenants = ref.watch(tenantsProvider);
    final api = ref.read(apiClientProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    Future<void> refresh() async => ref.invalidate(tenantsProvider);

    Color statusColor(String s) =>
        s == 'ACTIVE' ? tc.profit : s == 'SUSPENDED' ? const Color(0xFFEF9F27) : tc.loss;

    return AdminPage(
      title: 'Tenants',
      actions: [
        FilledButton.icon(onPressed: () => _create(context, ref, refresh), icon: const Icon(Icons.add, size: 18), label: const Text('New tenant')),
      ],
      child: tenants.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => SingleChildScrollView(
          child: AdaptiveTable(
            columns: const ['Brand', 'Slug / Domain', 'Currency', 'Status'],
            rows: list.map((t) {
              final c = Color(int.parse('FF${t.primaryColor.replaceFirst('#', '')}', radix: 16));
              return AdaptiveRow(
                cells: [
                  Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 14, height: 14, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4))), const SizedBox(width: 8), Flexible(child: Text(t.appName))]),
                  Text('${t.slug}${t.domain != null ? ' · ${t.domain}' : ''}'),
                  Text(t.baseCurrency),
                  StatusChip(t.status, color: statusColor(t.status)),
                ],
                actions: [
                  TextButton(onPressed: () => _editBranding(context, ref, t, refresh), child: const Text('Branding')),
                  if (t.status == 'ACTIVE')
                    TextButton(onPressed: () async { await api.post('/tenants/${t.id}/suspend', {'reason': 'admin'}); await refresh(); }, child: const Text('Suspend'))
                  else
                    TextButton(onPressed: () async { await api.post('/tenants/${t.id}/activate'); await refresh(); }, child: const Text('Activate')),
                  TextButton(onPressed: () async { await api.delete('/tenants/${t.id}'); await refresh(); }, child: Text('Delete', style: TextStyle(color: tc.loss))),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref, Future<void> Function() refresh) async {
    final name = TextEditingController();
    final slug = TextEditingController();
    final appName = TextEditingController();
    final domain = TextEditingController();
    final api = ref.read(apiClientProvider);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New broker tenant'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: name, decoration: const InputDecoration(labelText: 'Legal name'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: slug, decoration: const InputDecoration(labelText: 'Slug'))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: appName, decoration: const InputDecoration(labelText: 'App name'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: domain, decoration: const InputDecoration(labelText: 'Domain'))),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await api.post('/tenants', {'name': name.text, 'slug': slug.text.toLowerCase(), 'appName': appName.text, 'domain': domain.text});
              if (ctx.mounted) Navigator.pop(ctx);
              await refresh();
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// Edit an existing tenant's white-label branding (drives BOTH apps) with a
  /// live preview, wired to PATCH /tenants/:id/branding.
  Future<void> _editBranding(BuildContext context, WidgetRef ref, Tenant t, Future<void> Function() refresh) async {
    final appName = TextEditingController(text: t.appName);
    final logoUrl = TextEditingController(text: t.logoUrl ?? '');
    final primary = TextEditingController(text: t.primaryColor);
    final accent = TextEditingController(text: t.accentColor);
    final api = ref.read(apiClientProvider);
    bool busy = false;
    String? error;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final preview = Branding(
            appName: appName.text.trim().isEmpty ? t.name : appName.text.trim(),
            logoUrl: logoUrl.text.trim().isEmpty ? null : logoUrl.text.trim(),
            primary: _parseHex(primary.text, const Color(0xFF1652F0)),
            accent: _parseHex(accent.text, const Color(0xFF0BB07B)),
          );
          Widget swatch(String hex) => Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _parseHex(hex, Theme.of(ctx).hintColor),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Theme.of(ctx).dividerColor),
                ),
              );
          Widget colorField(String label, TextEditingController c) => Row(children: [
                Expanded(
                  child: TextField(
                    controller: c,
                    decoration: InputDecoration(labelText: label, hintText: '#RRGGBB'),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                swatch(c.text),
              ]);

          return AlertDialog(
            title: Text('Branding — ${t.name}'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // Live preview of the logo + name + colors.
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: Theme.of(ctx).dividerColor)),
                    child: Row(children: [
                      BrandLogo(branding: preview, size: 44),
                      const SizedBox(width: 12),
                      Expanded(child: Text(preview.appName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                      swatch(primary.text),
                      const SizedBox(width: 6),
                      swatch(accent.text),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Applies to both the trader and admin apps for this tenant.', style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor)),
                  ),
                  const SizedBox(height: 14),
                  TextField(controller: appName, decoration: const InputDecoration(labelText: 'App name'), onChanged: (_) => setLocal(() {})),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(controller: logoUrl, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Logo URL (https://…) — or upload →'), onChanged: (_) => setLocal(() {})),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('Upload'),
                      onPressed: busy
                          ? null
                          : () async {
                              try {
                                final f = await pickLogo();
                                if (f == null) return; // user cancelled
                                if (f.bytes.isEmpty) {
                                  setLocal(() => error = 'Could not read the file — try again.');
                                  return;
                                }
                                if (f.bytes.length > 4 * 1024 * 1024) {
                                  setLocal(() => error = 'Logo too large (max 4 MB).');
                                  return;
                                }
                                setLocal(() { busy = true; error = null; });
                                final res = await api.post('/tenants/${t.id}/logo', {
                                  'filename': f.name,
                                  'dataBase64': base64Encode(f.bytes),
                                });
                                setLocal(() { logoUrl.text = '${res['logoUrl']}'; busy = false; });
                              } catch (e) {
                                setLocal(() { busy = false; error = 'Upload failed: $e'; });
                              }
                            },
                    ),
                  ]),
                  const SizedBox(height: 12),
                  colorField('Primary color', primary),
                  const SizedBox(height: 12),
                  colorField('Accent color', accent),
                  const SizedBox(height: 14),
                  Row(children: [
                    Text('Presets:', style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 12)),
                    const SizedBox(width: 8),
                    ActionChip(label: const Text('Example'), onPressed: () => setLocal(() { primary.text = '#C9A24C'; accent.text = '#0E4D35'; })),
                    const SizedBox(width: 6),
                    ActionChip(label: const Text('Blue'), onPressed: () => setLocal(() { primary.text = '#1652F0'; accent.text = '#0BB07B'; })),
                  ]),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Color(0xFFE5484D))),
                  ],
                ]),
              ),
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setLocal(() { busy = true; error = null; });
                        try {
                          await api.patch('/tenants/${t.id}/branding', {
                            'appName': appName.text.trim(),
                            'logoUrl': logoUrl.text.trim().isEmpty ? null : logoUrl.text.trim(),
                            'primaryColor': _normHex(primary.text),
                            'accentColor': _normHex(accent.text),
                          });
                          if (ctx.mounted) Navigator.pop(ctx);
                          await refresh();
                        } catch (_) {
                          setLocal(() { busy = false; error = 'Save failed. Check the values and try again.'; });
                        }
                      },
                child: Text(busy ? 'Saving…' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Parse a `#RRGGBB` (or `RRGGBB`) hex string into a Color; fallback if invalid.
Color _parseHex(String v, [Color fallback = const Color(0xFF888888)]) {
  var s = v.trim().replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  final n = int.tryParse(s, radix: 16);
  return (n == null || s.length != 8) ? fallback : Color(n);
}

/// Normalize user input to a `#RRGGBB` string for the API.
String _normHex(String v) => '#${v.trim().replaceFirst('#', '').toUpperCase()}';
