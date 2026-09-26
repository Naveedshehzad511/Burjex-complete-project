import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

class _Gateway {
  const _Gateway(this.id, this.name, this.method, this.instructions, this.needsProof, this.minAmount);
  final int id;
  final String name;
  final String method;
  final String instructions;
  final bool needsProof;
  final double minAmount;
}

class _Methods {
  const _Methods({required this.allowed, required this.reason, required this.gateways, required this.accounts, required this.wallet});
  final bool allowed;
  final String reason;
  final List<_Gateway> gateways;
  final List<CrmAccount> accounts;
  final double wallet;
}

_Gateway _gw(Map<String, dynamic> g, bool deposit) => _Gateway(
      int.tryParse('${g['id']}') ?? 0,
      '${g['name'] ?? 'Method'}',
      '${g['payment_method'] ?? ''}',
      '${g['instructions'] ?? ''}',
      deposit && (g['require_payment_proof'] == true || '${g['profile']}' == 'MANUAL'),
      crmNum(g['min_amount']),
    );

final _methodsProvider = FutureProvider.autoDispose.family<_Methods, bool>((ref, deposit) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get(deposit ? '/deposits/methods/' : '/withdrawals/methods/');
  final d = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
  final wallet = ((await dio.get('/wallet/')).data as Map)['data'] as Map;
  return _Methods(
    allowed: d['allowed'] != false,
    reason: '${d['block_reason'] ?? ''}',
    gateways: [for (final g in (d['gateways'] as List? ?? const [])) _gw((g as Map).cast<String, dynamic>(), deposit)],
    accounts: [
      for (final a in (d['trading_accounts'] as List? ?? const [])) CrmAccount.fromJson((a as Map).cast<String, dynamic>()),
    ],
    wallet: crmNum(wallet['available_balance'] ?? wallet['wallet_balance']),
  );
});

/// Deposit / withdrawal request against the CRM (the money ledger). The request is
/// queued for admin approval; the approval is what triggers the push notification.
class FundingScreen extends ConsumerStatefulWidget {
  const FundingScreen({super.key, required this.type});
  final String type; // 'deposit' | 'withdraw'

  @override
  ConsumerState<FundingScreen> createState() => _FundingScreenState();
}

class _FundingScreenState extends ConsumerState<FundingScreen> {
  bool get _dep => widget.type == 'deposit';
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _details = TextEditingController();
  int? _gatewayId;
  String _target = 'wallet';
  PlatformFile? _proof;
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _details.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'], withData: true);
    if (r != null && r.files.isNotEmpty && mounted) setState(() => _proof = r.files.first);
  }

  Future<void> _submit(_Methods m, _Gateway g) async {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }
    if (_dep && g.needsProof && _proof?.bytes == null) {
      setState(() => _error = 'Attach your payment proof for this method.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fields = <String, dynamic>{
        'gateway': g.id,
        'amount': amt.toStringAsFixed(2),
        'currency': 'USD',
        'reference': _reference.text.trim(),
        if (_dep) 'trading_account': _target else 'withdraw_from': 'wallet',
        if (!_dep) 'account_details': _details.text.trim(),
        if (_dep && _proof?.bytes != null)
          'payment_screenshot': MultipartFile.fromBytes(_proof!.bytes!, filename: _proof!.name),
      };
      final res = await ref.read(crmDioProvider).post(_dep ? '/deposits/' : '/withdrawals/', data: FormData.fromMap(fields));
      ref.invalidate(crmDashboardProvider);
      _done = crmMessage(res.data, _dep ? 'Deposit request submitted.' : 'Withdrawal request submitted.');
    } on DioException catch (e) {
      _error = crmMessage(e, 'Request failed. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final methods = ref.watch(_methodsProvider(_dep));
    return PortalPage(
      title: _dep ? 'Deposit' : 'Withdraw',
      child: methods.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (m) {
          if (_done != null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const SizedBox(height: 30),
                const Icon(Icons.check_circle, size: 64, color: Color(0xFF1B9E4B)),
                const SizedBox(height: 14),
                Text(_done!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 22),
                FilledButton(onPressed: () => context.go('/home'), style: navyButton(), child: const Text('Back to Home')),
              ]),
            );
          }
          final gateway = m.gateways.where((g) => g.id == _gatewayId).firstOrNull ?? (m.gateways.isEmpty ? null : m.gateways.first);
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!_dep) ...[
              if (!m.allowed) ErrorBox(m.reason.isEmpty ? 'Withdrawals are not available right now.' : m.reason),
              if (!m.allowed) const SizedBox(height: 12),
              InfoCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('WALLET AVAILABLE', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text('${m.wallet.toStringAsFixed(2)} USD', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: kNavy)),
                ]),
              ),
              const SizedBox(height: 8),
              Text('Withdrawals are paid from your wallet. Admin approval completes the payout.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
              const SizedBox(height: 14),
            ] else ...[
              if (!m.allowed) ...[ErrorBox(m.reason.isEmpty ? 'Deposits are not available right now.' : m.reason), const SizedBox(height: 12)],
              InfoCard(
                child: DropdownButtonFormField<String>(
                  initialValue: _target,
                  decoration: portalField(context, 'Credit to'),
                  items: [
                    const DropdownMenuItem(value: 'wallet', child: Text('Wallet')),
                    for (final a in m.accounts) DropdownMenuItem(value: a.login, child: Text('#${a.login} · ${a.platform.isEmpty ? 'Account' : a.platform}')),
                  ],
                  onChanged: (v) => setState(() => _target = v ?? 'wallet'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (m.gateways.isEmpty)
              ErrorBox(_dep ? 'No deposit methods available right now.' : 'No withdrawal methods are configured.')
            else ...[
              DropdownButtonFormField<int>(
                initialValue: gateway?.id,
                decoration: portalField(context, _dep ? 'Deposit method' : 'Withdrawal method'),
                items: [for (final g in m.gateways) DropdownMenuItem(value: g.id, child: Text(g.name))],
                onChanged: (v) => setState(() => _gatewayId = v),
              ),
              if (gateway != null && gateway.instructions.isNotEmpty) ...[
                const SizedBox(height: 10),
                InfoCard(child: Text(gateway.instructions, style: const TextStyle(height: 1.4))),
              ],
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: portalField(context, 'Amount'),
            ),
            const SizedBox(height: 12),
            TextField(controller: _reference, decoration: portalField(context, 'Reference')),
            if (!_dep) ...[
              const SizedBox(height: 12),
              TextField(controller: _details, maxLines: 3, decoration: portalField(context, 'Account / wallet details')),
            ],
            if (_dep) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickProof,
                icon: const Icon(Icons.attach_file),
                label: Text(_proof == null ? 'Attach payment proof' : _proof!.name),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  foregroundColor: kNavy,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                ),
              ),
            ],
            if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: (_busy || !m.allowed || gateway == null) ? null : () => _submit(m, gateway),
              style: navyButton(),
              child: Text(_busy ? 'Submitting…' : (_dep ? 'Submit Deposit' : 'Submit Withdrawal')),
            ),
          ]);
        },
      ),
    );
  }
}
