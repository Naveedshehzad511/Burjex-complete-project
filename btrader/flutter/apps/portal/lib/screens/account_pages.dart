import 'package:btrader_core/btrader_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

// ── Open account ────────────────────────────────────────────────────────────

class _AccountType {
  const _AccountType(this.id, this.name, this.leverages);
  final int id;
  final String name;
  final List<int> leverages;
}

final _accountTypesProvider = FutureProvider.autoDispose<({List<_AccountType> types, List<String> currencies})>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/accounts/types/');
  final d = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
  final types = <_AccountType>[];
  for (final raw in (d['account_types'] as List? ?? const [])) {
    final t = (raw as Map).cast<String, dynamic>();
    var lev = <int>[
      for (final v in (t['leverage_options'] as List? ?? const [])) int.tryParse('$v') ?? 0,
    ].where((v) => v > 0).toList();
    if (lev.isEmpty) {
      final max = int.tryParse('${t['max_leverage'] ?? 100}') ?? 100;
      lev = [for (final v in const [10, 20, 50, 100, 200, 300, 400, 500, 1000]) if (v <= max) v];
      if (lev.isEmpty) lev = [max];
    }
    types.add(_AccountType(
      int.tryParse('${t['id']}') ?? 0,
      '${t['account_name'] ?? t['name'] ?? t['account_code'] ?? 'Account'}',
      lev,
    ));
  }
  final cur = [for (final c in (d['portal_currencies'] as List? ?? const ['USD'])) '$c'];
  return (types: types, currencies: cur.isEmpty ? const ['USD'] : cur);
});

class OpenAccountScreen extends ConsumerStatefulWidget {
  const OpenAccountScreen({super.key, this.demo = false});
  final bool demo;
  @override
  ConsumerState<OpenAccountScreen> createState() => _OpenAccountScreenState();
}

class _OpenAccountScreenState extends ConsumerState<OpenAccountScreen> {
  int? _typeId;
  int? _leverage;
  String _currency = 'USD';
  final _main = TextEditingController();
  final _investor = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _main.dispose();
    _investor.dispose();
    super.dispose();
  }

  Future<void> _submit(_AccountType type) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(crmDioProvider).post('/accounts/open/', data: {
        'account_type': type.id,
        'account_kind': widget.demo ? 'demo' : 'real',
        'leverage': _leverage ?? type.leverages.first,
        'currency': _currency,
        'main_password': _main.text,
        'investor_password': _investor.text,
      });
      ref.invalidate(crmDashboardProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.demo ? 'Demo account created.' : 'Account created.')));
      context.go('/home');
    } on DioException catch (e) {
      if (mounted) setState(() => _error = crmMessage(e, 'Could not open the account.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(_accountTypesProvider);
    return PortalPage(
      title: widget.demo ? 'Open Demo Account' : 'Open Real Account',
      child: types.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e, 'Could not load account types.'))),
        data: (d) {
          if (d.types.isEmpty) {
            return const Padding(padding: EdgeInsets.all(16), child: ErrorBox('No account types are available right now.'));
          }
          final type = d.types.firstWhere((t) => t.id == _typeId, orElse: () => d.types.first);
          final lev = type.leverages;
          final levValue = lev.contains(_leverage) ? _leverage! : lev.first;
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Text('Choose an account type', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: type.id,
              decoration: portalField(context, 'Account type'),
              items: [for (final t in d.types) DropdownMenuItem(value: t.id, child: Text(t.name))],
              onChanged: (v) => setState(() {
                _typeId = v;
                _leverage = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: levValue,
              decoration: portalField(context, 'Leverage'),
              items: [for (final l in lev) DropdownMenuItem(value: l, child: Text('1:$l'))],
              onChanged: (v) => setState(() => _leverage = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: d.currencies.contains(_currency) ? _currency : d.currencies.first,
              decoration: portalField(context, 'Currency'),
              items: [for (final c in d.currencies) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) => setState(() => _currency = v ?? _currency),
            ),
            const SizedBox(height: 12),
            TextField(controller: _main, obscureText: true, decoration: portalField(context, 'Trading password')),
            const SizedBox(height: 12),
            TextField(controller: _investor, obscureText: true, decoration: portalField(context, 'Investor password')),
            const SizedBox(height: 6),
            Text('Trading and investor passwords must differ (min. 8 characters). The investor password gives read-only access.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : () => _submit(type),
              style: navyButton(),
              child: Text(_busy ? 'Opening…' : (widget.demo ? '+ Open Demo Account' : '+ Open Real Account')),
            ),
          ]);
        },
      ),
    );
  }
}

// ── Profile ─────────────────────────────────────────────────────────────────

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _cur = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  @override
  void dispose() {
    _cur.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final res = await ref.read(crmDioProvider).post('/auth/change-password/', data: {
        'current_password': _cur.text,
        'old_password': _cur.text,
        'new_password': _next.text,
        'confirm_password': _next.text,
      });
      _ok = true;
      _msg = crmMessage(res.data, 'Password updated.');
      _cur.clear();
      _next.clear();
    } on DioException catch (e) {
      _ok = false;
      _msg = crmMessage(e, 'Could not update the password.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(crmProfileProvider);
    return PortalPage(
      title: 'My Data / Profile',
      child: p.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (u) {
          Widget ro(String label, String v) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: InputDecorator(
                  decoration: portalField(context, label),
                  child: Text(v.isEmpty ? '—' : v, style: const TextStyle(fontSize: 16)),
                ),
              );
          Widget chip(String t, Color bg, Color fg) => Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
                child: Text(t, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
              );
          final approved = u.accountStatus.toUpperCase() == 'APPROVED';
          return ListView(padding: const EdgeInsets.all(16), children: [
            InfoCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(u.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(u.email, style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 10),
                Row(children: [
                  chip(u.accountStatus.isEmpty ? 'PENDING' : u.accountStatus.toUpperCase(),
                      approved ? const Color(0xFFE3F5E9) : const Color(0xFFFFF1E0), approved ? const Color(0xFF1B7A3B) : const Color(0xFF9A5B00)),
                  chip(u.kycApproved ? 'KYC APPROVED' : 'KYC ${u.kycStatus.isEmpty ? 'PENDING' : u.kycStatus.toUpperCase()}',
                      u.kycApproved ? const Color(0xFFE3F5E9) : const Color(0xFFFFF1E0), u.kycApproved ? const Color(0xFF1B7A3B) : const Color(0xFF9A5B00)),
                ]),
                const SizedBox(height: 8),
                Text('Wallet: ${u.walletBalance.toStringAsFixed(2)} USD'),
              ]),
            ),
            const SizedBox(height: 14),
            ro('First name', u.firstName),
            ro('Last name', u.lastName),
            ro('Phone', u.phone),
            ro('Country', u.country),
            ro('Address', u.address),
            Text('Name, phone, country and address cannot be edited after account creation.',
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 22),
            const Text('Change password', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(controller: _cur, obscureText: true, decoration: portalField(context, 'Current password')),
            const SizedBox(height: 12),
            TextField(controller: _next, obscureText: true, decoration: portalField(context, 'New password')),
            if (_msg != null) ...[
              const SizedBox(height: 12),
              _ok ? Text(_msg!, style: const TextStyle(color: Color(0xFF1B7A3B), fontWeight: FontWeight.w600)) : ErrorBox(_msg!),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _changePassword, style: navyButton(), child: Text(_busy ? 'Updating…' : 'Update Password')),
            const SizedBox(height: 24),
          ]);
        },
      ),
    );
  }
}

// ── KYC ─────────────────────────────────────────────────────────────────────

final _kycProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/kyc/status/');
  return ((res.data as Map)['data'] as Map).cast<String, dynamic>();
});

class KycScreen extends ConsumerWidget {
  const KycScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(_kycProvider);
    return PortalPage(
      title: 'KYC',
      child: k.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (d) {
          Widget row(String label, String status) {
            final s = status.toLowerCase();
            final ok = s.contains('approved') || s.contains('verified');
            final bad = s.contains('reject');
            final color = ok ? const Color(0xFF1B7A3B) : bad ? const Color(0xFFC62828) : const Color(0xFF9A5B00);
            return InfoCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
              ]),
            );
          }

          final reason = '${d['kyc_reject_reason'] ?? ''}';
          return ListView(padding: const EdgeInsets.all(16), children: [
            InfoCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Verification status', style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 4),
                Text('${d['kyc_status'] ?? 'PENDING'}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: kNavy)),
                if (reason.isNotEmpty) ...[const SizedBox(height: 8), Text(reason, style: const TextStyle(color: Color(0xFFC62828)))],
              ]),
            ),
            const SizedBox(height: 12),
            row('Identity', '${d['identity_status_ui'] ?? 'Not Submitted'}'),
            const SizedBox(height: 8),
            row('Address', '${d['address_status_ui'] ?? 'Not Submitted'}'),
            const SizedBox(height: 8),
            row('Bank account', '${d['bank_status_ui'] ?? 'Not Submitted'}'),
            const SizedBox(height: 8),
            row('Crypto wallet', '${d['crypto_status_ui'] ?? 'Not Submitted'}'),
            const SizedBox(height: 16),
            Text(
              'Document upload is completed in the client portal on the web. Your status above updates here as soon as the team reviews it.',
              style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor, height: 1.4),
            ),
          ]);
        },
      ),
    );
  }
}

// ── Wallet ──────────────────────────────────────────────────────────────────

class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(crmDashboardProvider);
    return PortalPage(
      title: 'My Wallet',
      child: d.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (x) => ListView(padding: const EdgeInsets.all(16), children: [
          InfoCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('WALLET AVAILABLE', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('${x.walletBalance.toStringAsFixed(2)} USD', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: kNavy)),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton(onPressed: () => context.push('/deposit'), style: navyButton(), child: const Text('Deposit'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(onPressed: () => context.push('/withdraw'), style: navyButton(color: const Color(0xFFD33F3A)), child: const Text('Withdraw'))),
          ]),
        ]),
      ),
    );
  }
}
