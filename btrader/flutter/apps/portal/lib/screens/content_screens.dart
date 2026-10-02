import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

/// Legal Agreements and Trading Platform pages, built from the CRM's
/// admin-managed content (Settings → Legal Agreements / Trading Platform).
/// Replaces the generic label/value dump these two menu items used to show,
/// where every document or download link was plain text you could not open.

/// Open an admin-supplied document / download link outside the app (a new tab
/// on the web). Returns false when it could not be opened.
Future<bool> _openLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return false;
  try {
    return kIsWeb
        ? await launchUrl(uri, webOnlyWindowName: '_blank')
        : await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> _open(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!await _openLink(url)) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not open this link.')));
  }
}

String _s(dynamic v) => v == null ? '' : '$v'.trim();

Widget _empty(BuildContext context, IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(children: [
        Icon(icon, size: 48, color: Theme.of(context).hintColor),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
      ]),
    );

/// Small square logo from an admin-uploaded image, with an icon fallback when
/// none is set or it fails to load.
Widget _logo(String url, IconData fallback) {
  final placeholder = Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: kNavy.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
    child: Icon(fallback, color: kNavy),
  );
  if (url.isEmpty) return placeholder;
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.network(url, width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder),
  );
}

// ── Legal Agreements ─────────────────────────────────────────────────────────

final _legalProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/legal/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

/// Section order and headings match the CRM web portal's legal page.
const _kLegalSections = [
  ('ESSENTIAL', 'Essential Documents'),
  ('TRADING', 'Trading Policies'),
  ('REGIONAL', 'Regional Policies'),
  ('ADDITIONAL', 'Additional Policies'),
  ('CUSTOM', 'Other Documents'),
];

class LegalAgreementsScreen extends ConsumerWidget {
  const LegalAgreementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_legalProvider);
    return PortalPage(
      title: 'Legal Agreements',
      actions: [IconButton(onPressed: () => ref.invalidate(_legalProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load the legal documents.'))]),
        data: (d) {
          final byCat = (d['documents_by_category'] as Map?)?.cast<String, dynamic>() ?? const {};
          final sections = <Widget>[];
          for (final (key, fallbackLabel) in _kLegalSections) {
            final docs = (byCat[key] as List? ?? const []).whereType<Map>().where((x) => _s(x['link']).isNotEmpty).toList();
            if (docs.isEmpty) continue;
            final label = key == 'CUSTOM' ? fallbackLabel : (_s(docs.first['category_label']).isEmpty ? fallbackLabel : _s(docs.first['category_label']));
            sections
              ..add(Padding(
                padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
                child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ))
              ..add(InfoCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (var i = 0; i < docs.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.description_outlined, color: kNavy),
                      title: Text(_s(docs[i]['title']), style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => _open(context, _s(docs[i]['link'])),
                    ),
                  ],
                ]),
              ));
          }
          final tagline = _s(d['tagline']);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_legalProvider);
              await ref.read(_legalProvider.future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Row(children: [
                  _logo(_s(d['icon']), Icons.gavel_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_s(d['name']).isEmpty ? 'Legal Agreements' : _s(d['name']),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      if (tagline.isNotEmpty)
                        Text(tagline, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                    ]),
                  ),
                ]),
                if (sections.isEmpty)
                  _empty(context, Icons.gavel_outlined, 'No legal documents have been published yet.')
                else
                  ...sections,
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Trading Platform ─────────────────────────────────────────────────────────

final _platformsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/trading-platforms/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class _PlatformView {
  const _PlatformView(this.name, this.tagline, this.icon, this.links);
  final String name;
  final String tagline;
  final String icon;
  final List<(IconData, String, String)> links; // icon, label, url — only non-empty

  bool get hasLinks => links.isNotEmpty;
}

_PlatformView _platform(Map p, {String nameKey = 'name', Map<String, String>? keys}) {
  final k = keys ??
      const {
        'web': 'web_terminal_link',
        'windows': 'windows_link',
        'mac': 'mac_link',
        'ios': 'ios_link',
        'android': 'android_link',
      };
  final links = <(IconData, String, String)>[
    (Icons.language, 'Web Terminal', _s(p[k['web']])),
    (Icons.desktop_windows_outlined, 'Windows', _s(p[k['windows']])),
    (Icons.laptop_mac, 'macOS', _s(p[k['mac']])),
    (Icons.phone_iphone, 'iOS', _s(p[k['ios']])),
    (Icons.android, 'Android', _s(p[k['android']])),
  ].where((l) => l.$3.isNotEmpty).toList();
  return _PlatformView(_s(p[nameKey]), _s(p['tagline']), _s(p['icon']), links);
}

class TradingPlatformScreen extends ConsumerWidget {
  const TradingPlatformScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_platformsProvider);
    return PortalPage(
      title: 'Trading Platform',
      actions: [IconButton(onPressed: () => ref.invalidate(_platformsProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load the trading platforms.'))]),
        data: (d) {
          // The admin-managed platform list is the source of truth (same as the
          // web portal). The single-settings block is only a fallback, and only
          // when it actually carries a link — its default name is not admin data.
          final platforms = [
            for (final p in (d['platforms'] as List? ?? const []).whereType<Map>()) _platform(p),
          ].where((p) => p.hasLinks).toList();
          if (platforms.isEmpty && d['settings'] is Map) {
            final s = _platform(d['settings'] as Map, nameKey: 'platform_name', keys: const {
              'web': 'web_terminal_link',
              'windows': 'windows_download_link',
              'mac': 'macos_download_link',
              'ios': 'ios_download_link',
              'android': 'android_download_link',
            });
            if (s.hasLinks) platforms.add(s);
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_platformsProvider);
              await ref.read(_platformsProvider.future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (platforms.isEmpty)
                  _empty(context, Icons.desktop_windows_outlined, 'No trading platforms have been published yet.')
                else
                  for (final p in platforms) _PlatformCard(p: p),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PlatformCard extends StatelessWidget {
  const _PlatformCard({required this.p});
  final _PlatformView p;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InfoCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _logo(p.icon, Icons.candlestick_chart_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name.isEmpty ? 'Trading Platform' : p.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  if (p.tagline.isNotEmpty)
                    Text(p.tagline, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (icon, label, url) in p.links)
                label == 'Web Terminal'
                    ? FilledButton.icon(
                        onPressed: () => _open(context, url),
                        icon: Icon(icon, size: 18),
                        label: Text(label),
                        style: FilledButton.styleFrom(backgroundColor: kNavy, foregroundColor: Colors.white),
                      )
                    : OutlinedButton.icon(
                        onPressed: () => _open(context, url),
                        icon: Icon(icon, size: 18),
                        label: Text(label),
                      ),
            ]),
          ]),
        ),
      );
}
