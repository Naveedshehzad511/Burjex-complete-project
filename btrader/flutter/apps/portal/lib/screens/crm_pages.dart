import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

/// One menu destination backed by a CRM GET endpoint.
class CrmPageDef {
  const CrmPageDef(this.title, this.path, {this.action});
  final String title;
  final String path;

  /// Optional POST action shown as a button (e.g. apply to become an IB).
  final ({String label, String path})? action;
}

/// Every CRM-backed page reachable from the side menu, keyed by route segment.
const Map<String, CrmPageDef> kCrmPages = {
  'transactions': CrmPageDef('Transactions', '/transactions/'),
  'ib-dashboard': CrmPageDef('IB Dashboard', '/ib/dashboard/'),
  'ib-progress': CrmPageDef('IB Progress', '/ib/progress/'),
  'ib-request': CrmPageDef('IB Request', '/ib/apply/', action: (label: 'Apply to become an IB', path: '/ib/apply/')),
  'ib-clients': CrmPageDef('My Clients', '/ib/clients/'),
  'ib-commission': CrmPageDef('My Commission', '/ib/commission/'),
  'ib-tree': CrmPageDef('IB Tree Chart', '/ib/tree/'),
  'ib-withdraw': CrmPageDef('IB Withdraw', '/ib/withdraw/'),
  'team-deposits': CrmPageDef('Team Deposits', '/ib/team-report/deposits/'),
  'team-withdrawals': CrmPageDef('Team Withdrawals', '/ib/team-report/withdrawals/'),
  'report-deposits': CrmPageDef('Deposit Report', '/reports/deposits/'),
  'report-withdrawals': CrmPageDef('Withdraw Report', '/reports/withdrawals/'),
  'report-transfers': CrmPageDef('Internal Transfers', '/reports/transfers/'),
  'report-deals': CrmPageDef('Deal Report', '/reports/deals/'),
  'report-summary': CrmPageDef('Summary Report', '/reports/summary/'),
  'security': CrmPageDef('Security / 2FA', '/me/security/totp/'),
  'account-history': CrmPageDef('Account History', '/accounts/history/'),
  'notifications': CrmPageDef('Notifications', '/notifications/'),
  'platform': CrmPageDef('Trading Platform', '/trading-platforms/'),
  'legal': CrmPageDef('Legal Agreements', '/legal/'),
  'support': CrmPageDef('Need Help?', '/support/tickets/'),
};

String _pretty(String k) {
  final s = k.replaceAll('_', ' ').trim();
  return s.isEmpty ? k : s[0].toUpperCase() + s.substring(1);
}

bool _scalar(dynamic v) => v == null || v is num || v is String || v is bool;

String _show(dynamic v) {
  if (v == null) return '—';
  if (v is bool) return v ? 'Yes' : 'No';
  final s = '$v';
  return s.isEmpty ? '—' : s;
}

final _crmPageProvider = FutureProvider.autoDispose.family<dynamic, String>((ref, key) async {
  final def = kCrmPages[key];
  if (def == null) throw StateError('Unknown page');
  ref.watch(crmSessionProvider.select((s) => s.token));
  final res = await ref.watch(crmDioProvider).get(def.path);
  final body = res.data;
  return body is Map && body.containsKey('data') ? body['data'] : body;
});

/// Renders whatever the endpoint returns: scalar fields as label/value rows, and the
/// lists of records as cards. Real data only — nothing is invented client-side.
class CrmDataScreen extends ConsumerWidget {
  const CrmDataScreen({super.key, required this.pageKey});
  final String pageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final def = kCrmPages[pageKey];
    if (def == null) return const ComingSoonScreen(title: 'Page');
    final data = ref.watch(_crmPageProvider(pageKey));
    return PortalPage(
      title: def.title,
      actions: [IconButton(onPressed: () => ref.invalidate(_crmPageProvider(pageKey)), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [
          ErrorBox(e is DioException && e.response?.statusCode == 403
              ? 'This section is not available for your account yet.'
              : crmMessage(e, 'Could not load this page.')),
          if (def.action != null) _ActionButton(def.action!),
        ]),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_crmPageProvider(pageKey)),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              ..._body(context, d),
              if (def.action != null) _ActionButton(def.action!),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, dynamic d) {
    if (d is List) return _cards(context, d);
    if (d is! Map) return [InfoCard(child: Text(_show(d)))];
    final m = d.cast<String, dynamic>();
    final rows = <Widget>[];
    final lists = <String, List>{};
    final maps = <String, Map>{};
    for (final e in m.entries) {
      if (_scalar(e.value)) {
        rows.add(_row(e.key, _show(e.value)));
      } else if (e.value is List && (e.value as List).isNotEmpty) {
        lists[e.key] = e.value as List;
      } else if (e.value is Map && (e.value as Map).isNotEmpty) {
        maps[e.key] = e.value as Map;
      }
    }
    final out = <Widget>[];
    if (rows.isNotEmpty) out.add(InfoCard(child: Column(children: rows)));
    for (final e in maps.entries) {
      final inner = [
        for (final x in e.value.entries)
          if (_scalar(x.value)) _row('${x.key}', _show(x.value)),
      ];
      if (inner.isEmpty) continue;
      out
        ..add(const SizedBox(height: 14))
        ..add(Text(_pretty(e.key), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)))
        ..add(const SizedBox(height: 8))
        ..add(InfoCard(child: Column(children: inner)));
    }
    for (final e in lists.entries) {
      out
        ..add(const SizedBox(height: 14))
        ..add(Text(_pretty(e.key), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)))
        ..add(const SizedBox(height: 8))
        ..addAll(_cards(context, e.value));
    }
    if (out.isEmpty) out.add(const InfoCard(child: Text('Nothing to show yet.')));
    return out;
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 4, child: Text(_pretty(k), style: const TextStyle(color: Colors.grey, fontSize: 13.5))),
          const SizedBox(width: 8),
          Expanded(flex: 5, child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
        ]),
      );

  List<Widget> _cards(BuildContext context, List items) {
    if (items.isEmpty) return const [InfoCard(child: Text('No records yet.'))];
    return [
      for (final it in items.take(200))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InfoCard(
            child: it is Map
                ? Column(children: [
                    for (final e in it.entries)
                      if (_scalar(e.value) && '${e.value}'.isNotEmpty) _row('${e.key}', _show(e.value)),
                  ])
                : Text(_show(it)),
          ),
        ),
    ];
  }
}

class _ActionButton extends ConsumerStatefulWidget {
  const _ActionButton(this.def);
  final ({String label, String path}) def;
  @override
  ConsumerState<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends ConsumerState<_ActionButton> {
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final r = await ref.read(crmDioProvider).post(widget.def.path);
      _ok = true;
      _msg = crmMessage(r.data, 'Submitted.');
    } on DioException catch (e) {
      _ok = false;
      _msg = crmMessage(e, 'Request failed.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(children: [
          if (_msg != null) ...[
            _ok ? Text(_msg!, style: const TextStyle(color: Color(0xFF1B7A3B), fontWeight: FontWeight.w600)) : ErrorBox(_msg!),
            const SizedBox(height: 10),
          ],
          FilledButton(onPressed: _busy ? null : _go, style: navyButton(), child: Text(_busy ? 'Submitting…' : widget.def.label)),
        ]),
      );
}

class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({super.key, required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => PortalPage(
        title: title,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.hourglass_empty, size: 54, color: kNavy),
              const SizedBox(height: 14),
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('This section is coming soon.', style: TextStyle(color: Theme.of(context).hintColor)),
            ]),
          ),
        ),
      );
}

// ── Internal transfer ───────────────────────────────────────────────────────

final _transferProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/transfers/internal/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class InternalTransferScreen extends ConsumerStatefulWidget {
  const InternalTransferScreen({super.key});
  @override
  ConsumerState<InternalTransferScreen> createState() => _InternalTransferScreenState();
}

class _InternalTransferScreenState extends ConsumerState<InternalTransferScreen> {
  String? _type;
  String? _from;
  String? _to;
  final _amount = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit(Map<String, dynamic> o) async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final r = await ref.read(crmDioProvider).post('/transfers/internal/', data: {
        'transfer_type': _type ?? '',
        'from_account': _from,
        'to_account': _to,
        'amount': _amount.text.trim(),
        'request_uid': o['request_uid'],
      });
      _ok = true;
      _msg = crmMessage(r.data, 'Transfer submitted.');
      ref.invalidate(crmDashboardProvider);
    } on DioException catch (e) {
      _ok = false;
      _msg = crmMessage(e, 'Transfer failed.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(_transferProvider);
    return PortalPage(
      title: 'Internal Transfer',
      child: t.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (o) {
          if (o['allowed'] == false) {
            return Padding(padding: const EdgeInsets.all(16), child: ErrorBox('${o['block_reason'] ?? 'Transfers are not available right now.'}'));
          }
          final types = [for (final x in (o['transfer_types'] as List? ?? const [])) x];
          final accounts = [for (final x in (o['trading_accounts'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
          final choices = <(String, String)>[
            ('WALLET', 'Wallet (${o['wallet_balance']})'),
            for (final a in accounts) ('${a['from_account_key'] ?? a['login_id']}', '#${a['login_id'] ?? a['account_number']} · ${a['balance'] ?? ''}'),
          ];
          String? pick(String? v) => choices.any((c) => c.$1 == v) ? v : null;
          String tv(dynamic x) => '${x is Map ? (x['value'] ?? x['key'] ?? x['id']) : x}';
          String tl(dynamic x) => '${x is Map ? (x['label'] ?? x['name'] ?? x['value']) : x}';
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (types.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: types.any((x) => tv(x) == _type) ? _type : null,
                decoration: portalField(context, 'Transfer type'),
                items: [for (final x in types) DropdownMenuItem(value: tv(x), child: Text(tl(x)))],
                onChanged: (v) => setState(() => _type = v),
              ),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<String>(
              initialValue: pick(_from),
              decoration: portalField(context, 'From'),
              items: [for (final c in choices) DropdownMenuItem(value: c.$1, child: Text(c.$2, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _from = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: pick(_to),
              decoration: portalField(context, 'To'),
              items: [for (final c in choices) DropdownMenuItem(value: c.$1, child: Text(c.$2, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _to = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: portalField(context, 'Amount')),
            if (_msg != null) ...[
              const SizedBox(height: 12),
              _ok ? Text(_msg!, style: const TextStyle(color: Color(0xFF1B7A3B), fontWeight: FontWeight.w600)) : ErrorBox(_msg!),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: (_busy || _from == null || _to == null) ? null : () => _submit(o),
              style: navyButton(),
              child: Text(_busy ? 'Submitting…' : 'Transfer'),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: () => context.push('/p/report-transfers'), child: const Text('View transfer history')),
          ]);
        },
      ),
    );
  }
}
