import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

/// Purpose-built screens for the IB Programme, replacing the generic
/// label/value dump ([CrmDataScreen]) that showed every `/ib/*` endpoint as a
/// flat list. Each screen renders the real shape the CRM returns:
/// dashboard cards, a level-progress bar, the referral tree, a clients table,
/// the commission ledger, and the withdraw form — matching what the CRM's own
/// web `user_portal` templates show, so mobile and web are the same feature.

const _kGreen = Color(0xFF178F45);
const _kGreenBg = Color(0x1A22C55E);

String _money(dynamic v) {
  final n = v == null ? 0.0 : (double.tryParse('$v') ?? 0.0);
  return n.toStringAsFixed(2);
}

Widget _sectionTitle(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
    );

Widget _statTile(BuildContext context, String label, String value, {Color? valueColor, String? path}) {
  final tile = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
    const SizedBox(height: 3),
    Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: valueColor)),
  ]);
  // A tile with a [path] opens its detailed list (the menu no longer repeats it).
  return Expanded(
    child: path == null
        ? tile
        : InkWell(
            key: ValueKey('ib-stat-$path'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.push(path),
            child: tile,
          ),
  );
}

// ── Dashboard ────────────────────────────────────────────────────────────────

final _ibDashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/dashboard/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

/// Where the client stands with the IB programme: an approved IB (has a profile), an application
/// under review, or not applied. Drives the menu: only an approved IB sees the dashboard, only
/// someone who is not one needs the request page.
enum IbState { approved, pending, none }

final ibStateProvider = FutureProvider.autoDispose<IbState>((ref) async {
  final d = await ref.watch(_ibDashboardProvider.future);
  if (d['ib_profile'] != null) return IbState.approved;
  return d['pending_application'] == true ? IbState.pending : IbState.none;
});

final _ibProgressProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/progress/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbDashboardScreen extends ConsumerWidget {
  const IbDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(_ibDashboardProvider);
    return PortalPage(
      title: 'IB Dashboard',
      actions: [
        IconButton(
          onPressed: () {
            ref.invalidate(_ibDashboardProvider);
            ref.invalidate(_ibProgressProvider);
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: dash.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load your IB dashboard.'))]),
        data: (d) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(_ibDashboardProvider);
            ref.invalidate(_ibProgressProvider);
            await ref.read(_ibDashboardProvider.future);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _IbWalletCard(d: d),
              const SizedBox(height: 16),
              _sectionTitle('This month · ${d['month_name'] ?? ''}'),
              InfoCard(
                child: Row(children: [
                  _statTile(context, 'Monthly commission', '${_money(d['monthly_commission'])} USD'),
                  _statTile(context, 'Total commission', '${_money(d['total_commission'])} USD'),
                ]),
              ),
              const SizedBox(height: 10),
              InfoCard(
                child: Row(children: [
                  _statTile(context, 'Total clients', '${d['total_clients'] ?? 0}'),
                  _statTile(context, 'Live accounts', '${d['live_accounts_active'] ?? 0} / ${d['live_accounts_total'] ?? 0}'),
                ]),
              ),
              const SizedBox(height: 10),
              InfoCard(
                child: Column(children: [
                  Row(children: [
                    _statTile(context, 'Team deposits', '${_money(d['team_deposits'])} USD', valueColor: _kGreen, path: '/ib/team-deposits'),
                    _statTile(context, 'Team withdrawals', '${_money(d['team_withdrawals'])} USD', path: '/ib/team-withdrawals'),
                  ]),
                  const Divider(height: 22),
                  Row(children: [
                    _statTile(context, 'Team net', '${_money(d['team_net'])} USD'),
                    _statTile(context, 'Referral registrations', '${d['referral_registrations'] ?? 0}'),
                  ]),
                ]),
              ),
              const _IbProgressSection(),
              const SizedBox(height: 8),
              _sectionTitle('Manage'),
              Wrap(spacing: 10, runSpacing: 10, children: [
                _QuickLink(icon: Icons.people_outline, label: 'My Clients', path: '/ib/clients'),
                _QuickLink(icon: Icons.payments_outlined, label: 'My Commission', path: '/ib/commission'),
                _QuickLink(icon: Icons.account_tree_outlined, label: 'IB Tree', path: '/ib/tree'),
                _QuickLink(icon: Icons.account_balance_wallet_outlined, label: 'IB Withdraw', path: '/ib/withdraw'),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _IbWalletCard extends StatelessWidget {
  const _IbWalletCard({required this.d});
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final profile = d['ib_profile'] as Map?;
    final link = '${profile?['referral_link'] ?? ''}';
    final pending = d['pending_application'] == true;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF071A33), kNavy, Color(0xFF0B3F73)]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x33002D58), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('IB WALLET AVAILABLE', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_money(d['ib_wallet_available']), style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, height: 1.1)),
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(bottom: 5), child: Text('USD', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 14))),
        ]),
        if (crmNum(d['ib_wallet_pending']) > 0) ...[
          const SizedBox(height: 4),
          Text('${_money(d['ib_wallet_pending'])} USD pending', style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        if (profile != null) ...[
          if (link.isNotEmpty) ...[
            Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Referral link copied')));
                    }
                  },
                  child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.copy, size: 18, color: Colors.white)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text('${profile['link_clicks'] ?? 0} link clicks', style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12)),
          ],
        ] else
          Row(children: [
            Expanded(
              child: Text(
                pending ? 'Your IB application is under review.' : 'Apply to become an Introducing Broker and start earning commission.',
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
              ),
            ),
            if (!pending) ...[
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => context.push('/ib/apply'),
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: kNavy, minimumSize: const Size(0, 40)),
                child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
      ]),
    );
  }
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({required this.icon, required this.label, required this.path});
  final IconData icon;
  final String label;
  final String path;
  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push(path),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: kNavy),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ]),
          ),
        ),
      );
}

/// Level progress bar (lots / deposit / referrals, whichever the CRM's IB plan
/// is currently gating on), shown on both the dashboard and its own page.
class _IbProgressSection extends ConsumerWidget {
  const _IbProgressSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prog = ref.watch(_ibProgressProvider);
    return prog.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (p) {
        if (p['available'] != true) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionTitle('Level progress'),
          _IbProgressCard(p: p),
        ]);
      },
    );
  }
}

class _IbProgressCard extends StatelessWidget {
  const _IbProgressCard({required this.p});
  final Map<String, dynamic> p;

  Widget _bar(BuildContext context, String label, String cur, String req, num pct) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
            Text('$cur / $req', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: (pct.toDouble() / 100).clamp(0.0, 1.0),
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              valueColor: const AlwaysStoppedAnimation(_kGreen),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final atTop = p['at_top_tier'] == true;
    return InfoCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          tag(context, '${p['current_level'] ?? ''}', bg: _kGreenBg, fg: _kGreen),
          if (!atTop) ...[
            Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 14, color: Theme.of(context).hintColor)),
            tag(context, '${p['next_level'] ?? ''}'),
          ],
          const Spacer(),
          Text('${p['commission_rate'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ]),
        const SizedBox(height: 14),
        _bar(context, p['primary_label'] == 'Referrals' ? 'Referrals' : (p['primary_label'] ?? 'Progress'),
            '${p['current_value']}', '${p['required_value']}', p['progress_percent'] ?? 0),
        if (p['lots_req'] != null && crmNum(p['lots_req']) > 0)
          _bar(context, 'Lots traded', '${p['lots_cur']}', '${p['lots_req']}', p['lots_pct'] ?? 0),
        if (p['dep_req'] != null && crmNum(p['dep_req']) > 0)
          _bar(context, 'Team deposits', '${p['dep_cur']}', '${p['dep_req']}', p['dep_pct'] ?? 0),
        if (p['refs_req'] != null && crmNum(p['refs_req']) > 0)
          _bar(context, 'Referrals', '${p['refs_cur']}', '${p['refs_req']}', p['refs_pct'] ?? 0),
        if (!atTop && '${p['next_reward_title'] ?? ''}'.isNotEmpty) ...[
          const Divider(height: 22),
          Row(children: [
            const Icon(Icons.emoji_events_outlined, size: 16, color: Color(0xFFB7791F)),
            const SizedBox(width: 6),
            Expanded(child: Text('${p['next_reward_title']} · ${p['next_reward_remaining_label'] ?? ''}', style: const TextStyle(fontSize: 12.5))),
          ]),
        ],
      ]),
    );
  }

  Widget tag(BuildContext context, String t, {Color? bg, Color? fg}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg ?? Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
        child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
      );
}

/// Standalone page — the same progress data, full width, for when the client
/// wants only their level standing (drawer: "IB Progress").
class IbProgressScreen extends ConsumerWidget {
  const IbProgressScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prog = ref.watch(_ibProgressProvider);
    return PortalPage(
      title: 'IB Progress',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibProgressProvider), icon: const Icon(Icons.refresh))],
      child: prog.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load your progress.'))]),
        data: (p) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(_ibProgressProvider);
            await ref.read(_ibProgressProvider.future);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              if (p['available'] != true)
                const InfoCard(child: Text('Level progress is not available for your account yet.'))
              else
                _IbProgressCard(p: p),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Apply ────────────────────────────────────────────────────────────────────

final _ibApplyFormProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/apply/');
  final data = (((res.data as Map)['data']) as Map);
  return (data['questions'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
});

class IbApplyScreen extends ConsumerStatefulWidget {
  const IbApplyScreen({super.key});
  @override
  ConsumerState<IbApplyScreen> createState() => _IbApplyScreenState();
}

class _IbApplyScreenState extends ConsumerState<IbApplyScreen> {
  final _answers = <int, dynamic>{};
  final _controllers = <int, TextEditingController>{};
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers.values) c.dispose();
    super.dispose();
  }

  Future<void> _submit(List<Map<String, dynamic>> questions) async {
    for (final q in questions) {
      final id = q['id'] as int;
      final required = q['required'] == true;
      final v = _answers[id];
      final empty = v == null || (v is String && v.trim().isEmpty) || (v is List && v.isEmpty);
      if (required && empty) {
        setState(() => _error = 'Please complete "${q['label']}".');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {for (final e in _answers.entries) 'question_${e.key}': e.value};
      await ref.read(crmDioProvider).post('/ib/apply/', data: body);
      if (mounted) setState(() => _submitted = true);
    } on DioException catch (e) {
      if (mounted) setState(() => _error = crmMessage(e, 'Could not submit your application.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(Map<String, dynamic> q) {
    final id = q['id'] as int;
    final label = '${q['label']}${q['required'] == true ? ' *' : ''}';
    final type = '${q['input_type']}';
    final choices = (q['choices'] as List? ?? const []).map((e) => '$e').toList();
    switch (type) {
      case 'YES_NO':
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            ToggleButtons(
              borderRadius: BorderRadius.circular(10),
              isSelected: [_answers[id] == 'Yes', _answers[id] == 'No'],
              onPressed: (i) => setState(() => _answers[id] = i == 0 ? 'Yes' : 'No'),
              children: const [Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Text('Yes')), Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Text('No'))],
            ),
          ]),
        );
      case 'SELECT':
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: DropdownButtonFormField<String>(
            initialValue: _answers[id] as String?,
            decoration: portalField(context, label),
            items: [for (final c in choices) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (v) => setState(() => _answers[id] = v),
          ),
        );
      case 'MULTI':
        final sel = (_answers[id] as List?)?.cast<String>() ?? <String>[];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final c in choices)
                FilterChip(
                  label: Text(c),
                  selected: sel.contains(c),
                  onSelected: (v) => setState(() => _answers[id] = v ? [...sel, c] : sel.where((x) => x != c).toList()),
                ),
            ]),
          ]),
        );
      case 'NUMBER':
        _controllers.putIfAbsent(id, () => TextEditingController());
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: _controllers[id],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: portalField(context, label),
            onChanged: (v) => _answers[id] = v,
          ),
        );
      case 'TEXTAREA':
        _controllers.putIfAbsent(id, () => TextEditingController());
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: _controllers[id],
            maxLines: 4,
            decoration: portalField(context, label),
            onChanged: (v) => _answers[id] = v,
          ),
        );
      default: // TEXT
        _controllers.putIfAbsent(id, () => TextEditingController());
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(controller: _controllers[id], decoration: portalField(context, label), onChanged: (v) => _answers[id] = v),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final form = ref.watch(_ibApplyFormProvider);
    return PortalPage(
      title: 'IB Application',
      child: _submitted
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle_outline, size: 56, color: _kGreen),
                const SizedBox(height: 14),
                const Text('Application submitted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('Our team will review it shortly.', style: TextStyle(color: Theme.of(context).hintColor)),
              ]),
            )
          : form.when(
              loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [
                ErrorBox(e is DioException
                    ? crmMessage(e, 'You cannot apply right now.')
                    : 'You cannot apply right now.'),
              ]),
              data: (questions) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Tell us about your business so we can set up your IB profile.',
                      style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
                  const SizedBox(height: 18),
                  for (final q in questions) _field(q),
                  if (_error != null) ...[ErrorBox(_error!), const SizedBox(height: 10)],
                  FilledButton(
                    onPressed: _busy ? null : () => _submit(questions),
                    style: navyButton(),
                    child: Text(_busy ? 'Submitting…' : 'Submit application'),
                  ),
                ],
              ),
            ),
    );
  }
}

// ── Clients ──────────────────────────────────────────────────────────────────

final _ibClientsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/clients/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbClientsScreen extends ConsumerWidget {
  const IbClientsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_ibClientsProvider);
    return PortalPage(
      title: 'My Clients',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibClientsProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load your clients.'))]),
        data: (d) {
          final clients = (d['clients'] as List? ?? const []).cast<Map>();
          final summary = (d['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_ibClientsProvider);
              await ref.read(_ibClientsProvider.future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                InfoCard(
                  child: Column(children: [
                    Row(children: [
                      _statTile(context, 'Commission', '${_money(summary['commission'])} USD'),
                      _statTile(context, 'Lots', '${_money(summary['lot'])}'),
                    ]),
                    const Divider(height: 22),
                    Row(children: [
                      _statTile(context, 'Deposits', '${_money(summary['deposit'])} USD', valueColor: _kGreen),
                      _statTile(context, 'Withdrawals', '${_money(summary['withdraw'])} USD'),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),
                if (clients.isEmpty)
                  const InfoCard(child: Text('No clients yet. Share your referral link from the dashboard.'))
                else
                  for (final c in clients) _ClientCard(c: c.cast<String, dynamic>()),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ClientCard extends StatelessWidget {
  const _ClientCard({required this.c});
  final Map<String, dynamic> c;
  @override
  Widget build(BuildContext context) {
    final kyc = '${c['kyc_status'] ?? ''}'.toUpperCase();
    final approved = kyc == 'APPROVED';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InfoCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${c['name'] ?? c['email'] ?? 'Client'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5), overflow: TextOverflow.ellipsis),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: approved ? _kGreenBg : Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
              child: Text(kyc.isEmpty ? '—' : kyc, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: approved ? _kGreen : null)),
            ),
          ]),
          const SizedBox(height: 2),
          Text('${c['email'] ?? ''}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          if ('${c['mt5_login'] ?? ''}'.isNotEmpty && c['mt5_login'] != null) ...[
            const SizedBox(height: 2),
            Text('Account #${c['mt5_login']}${c['country'] != null && '${c['country']}'.isNotEmpty ? '  ·  ${c['country']}' : ''}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            _statTile(context, 'Commission', '${_money(c['commission'])} USD'),
            _statTile(context, 'Lots', '${_money(c['lots'])}'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _statTile(context, 'Deposit', '${_money(c['deposit'])} USD'),
            _statTile(context, 'Withdraw', '${_money(c['withdraw'])} USD'),
          ]),
        ]),
      ),
    );
  }
}

// ── Commission ───────────────────────────────────────────────────────────────

final _ibCommissionProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/commission/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbCommissionScreen extends ConsumerWidget {
  const IbCommissionScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_ibCommissionProvider);
    return PortalPage(
      title: 'My Commission',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibCommissionProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load your commission history.'))]),
        data: (d) {
          final txs = (d['transactions'] as List? ?? const []).cast<Map>();
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_ibCommissionProvider);
              await ref.read(_ibCommissionProvider.future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                InfoCard(
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('Total received', style: TextStyle(fontWeight: FontWeight.w700)),
                    Text('${_money(d['total'])} USD', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _kGreen)),
                  ]),
                ),
                const SizedBox(height: 16),
                if (txs.isEmpty)
                  const InfoCard(child: Text('No commission payouts yet.'))
                else
                  for (final t in txs) _TxCard(t: t.cast<String, dynamic>()),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TxCard extends StatelessWidget {
  const _TxCard({required this.t});
  final Map<String, dynamic> t;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InfoCard(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t['from_client_email'] ?? t['reference'] ?? 'Commission'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text('${t['created_at'] ?? ''}'.split('T').first, style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
                if ('${t['notes'] ?? ''}'.isNotEmpty) Text('${t['notes']}', style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
              ]),
            ),
            Text('+${_money(t['amount'])} ${t['currency'] ?? 'USD'}', style: const TextStyle(fontWeight: FontWeight.w800, color: _kGreen)),
          ]),
        ),
      );
}

// ── Tree ─────────────────────────────────────────────────────────────────────

final _ibTreeProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/tree/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbTreeScreen extends ConsumerWidget {
  const IbTreeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_ibTreeProvider);
    return PortalPage(
      title: 'IB Tree Chart',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibTreeProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load your referral tree.'))]),
        data: (d) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _TreeLevel(title: 'Level 1 · Direct referrals', users: (d['level1'] as List? ?? const []).cast<Map>(), color: kNavy),
            _TreeLevel(title: 'Level 2', users: (d['level2'] as List? ?? const []).cast<Map>(), color: const Color(0xFF3E7CB1)),
            _TreeLevel(title: 'Level 3', users: (d['level3'] as List? ?? const []).cast<Map>(), color: const Color(0xFF7BA7C9)),
          ],
        ),
      ),
    );
  }
}

class _TreeLevel extends StatelessWidget {
  const _TreeLevel({required this.title, required this.users, required this.color});
  final String title;
  final List<Map> users;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text('$title  (${users.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
          ]),
          const SizedBox(height: 8),
          if (users.isEmpty)
            const InfoCard(child: Text('No one here yet.'))
          else
            InfoCard(
              child: Column(
                children: [
                  for (var i = 0; i < users.length; i++) ...[
                    if (i > 0) const Divider(height: 18),
                    Row(children: [
                      CircleAvatar(radius: 14, backgroundColor: color.withValues(alpha: 0.15), child: Icon(Icons.person, size: 15, color: color)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${users[i]['name'] ?? users[i]['email'] ?? 'User'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                          Text('${users[i]['email'] ?? ''}', style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
                        ]),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
        ]),
      );
}

// ── Withdraw ─────────────────────────────────────────────────────────────────

final _ibWithdrawProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/withdraw/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbWithdrawScreen extends ConsumerStatefulWidget {
  const IbWithdrawScreen({super.key});
  @override
  ConsumerState<IbWithdrawScreen> createState() => _IbWithdrawScreenState();
}

class _IbWithdrawScreenState extends ConsumerState<IbWithdrawScreen> {
  String? _method;
  int? _bankId;
  int? _cryptoId;
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amount.text.trim()) ?? 0;
    if (_method == null) {
      setState(() {
        _ok = false;
        _msg = 'Choose a withdrawal method.';
      });
      return;
    }
    if (amt <= 0) {
      setState(() {
        _ok = false;
        _msg = 'Enter a valid amount.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final body = <String, dynamic>{'method': _method, 'amount': amt, 'notes': _notes.text.trim()};
      if (_method == 'bank' && _bankId != null) body['bank_id'] = _bankId;
      if (_method == 'crypto' && _cryptoId != null) body['crypto_id'] = _cryptoId;
      final res = await ref.read(crmDioProvider).post('/ib/withdraw/', data: body);
      _ok = true;
      _msg = crmMessage(res.data, 'Withdrawal request submitted.');
      _amount.clear();
      _notes.clear();
      ref.invalidate(_ibWithdrawProvider);
    } on DioException catch (e) {
      _ok = false;
      _msg = crmMessage(e, 'Could not submit the withdrawal.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_ibWithdrawProvider);
    return PortalPage(
      title: 'IB Withdraw',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibWithdrawProvider), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [
          ErrorBox(e is DioException ? crmMessage(e, 'You must be an approved IB to withdraw.') : 'You must be an approved IB to withdraw.'),
        ]),
        data: (d) {
          final methods = (d['methods'] as Map?)?.cast<String, dynamic>() ?? const {};
          final banks = (d['banks'] as List? ?? const []).cast<Map>();
          final cryptos = (d['cryptos'] as List? ?? const []).cast<Map>();
          final history = (d['history'] as List? ?? const []).cast<Map>();
          final available = crmNum(d['available_balance']);
          final methodOptions = <String, String>{
            if (methods['internal'] == true) 'internal': 'Internal transfer',
            if (methods['bank'] == true) 'bank': 'Bank account',
            if (methods['crypto'] == true) 'crypto': 'Crypto wallet',
            if (methods['manual'] == true) 'manual': 'Manual request',
          };
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              InfoCard(
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Available balance', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('${available.toStringAsFixed(2)} USD', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ]),
              ),
              const SizedBox(height: 18),
              if (methodOptions.isEmpty)
                const InfoCard(child: Text('No withdrawal methods are enabled for IB commission right now.'))
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: _method,
                  decoration: portalField(context, 'Withdrawal method'),
                  items: [for (final e in methodOptions.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => _method = v),
                ),
                if (_method == 'bank') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _bankId,
                    decoration: portalField(context, 'Bank account', helper: banks.isEmpty ? 'No verified bank account on file' : null),
                    items: [for (final b in banks) DropdownMenuItem(value: b['id'] as int, child: Text('${b['bank_name']} · ${b['account_number']}'))],
                    onChanged: (v) => setState(() => _bankId = v),
                  ),
                ],
                if (_method == 'crypto') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _cryptoId,
                    decoration: portalField(context, 'Crypto wallet', helper: cryptos.isEmpty ? 'No verified crypto wallet on file' : null),
                    items: [for (final c in cryptos) DropdownMenuItem(value: c['id'] as int, child: Text('${c['wallet_name']} (${c['network']})'))],
                    onChanged: (v) => setState(() => _cryptoId = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: portalField(context, 'Amount (USD)')),
                const SizedBox(height: 12),
                TextField(controller: _notes, decoration: portalField(context, 'Notes (optional)')),
                const SizedBox(height: 16),
                if (_msg != null) ...[
                  _ok ? Text(_msg!, style: const TextStyle(color: _kGreen, fontWeight: FontWeight.w600)) : ErrorBox(_msg!),
                  const SizedBox(height: 10),
                ],
                FilledButton(onPressed: _busy ? null : _submit, style: navyButton(), child: Text(_busy ? 'Submitting…' : 'Request withdrawal')),
              ],
              const SizedBox(height: 22),
              _sectionTitle('History'),
              if (history.isEmpty)
                const InfoCard(child: Text('No withdrawal requests yet.'))
              else
                for (final h in history) _TxCard(t: h.cast<String, dynamic>()),
            ],
          );
        },
      ),
    );
  }
}

// ── Team reports (deposits / withdrawals) ────────────────────────────────────

final _ibTeamReportProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, kind) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/ib/team-report/$kind/');
  return (((res.data as Map)['data']) as Map).cast<String, dynamic>();
});

class IbTeamReportScreen extends ConsumerWidget {
  const IbTeamReportScreen({super.key, required this.kind});
  final String kind; // 'deposits' | 'withdrawals'
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_ibTeamReportProvider(kind));
    return PortalPage(
      title: kind == 'deposits' ? 'Team Deposits' : 'Team Withdrawals',
      actions: [IconButton(onPressed: () => ref.invalidate(_ibTeamReportProvider(kind)), icon: const Icon(Icons.refresh))],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [ErrorBox(crmMessage(e, 'Could not load this report.'))]),
        data: (d) {
          final rows = (d['rows'] as List? ?? const []).cast<Map>();
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_ibTeamReportProvider(kind));
              await ref.read(_ibTeamReportProvider(kind).future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (rows.isEmpty)
                  const InfoCard(child: Text('No records yet.'))
                else
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InfoCard(
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${r['client'] ?? r['client_email'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                              const SizedBox(height: 3),
                              Text('${r['created_at'] ?? ''}'.split('T').first, style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
                            ]),
                          ),
                          Text('${_money(r['amount'])} ${r['currency'] ?? 'USD'}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}
