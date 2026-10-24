import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../state/crypto_policy.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';
import '../widgets/state_views.dart';
import 'kyc_screen.dart' show kycStatusProvider;

// ── Validation (pure, so it is the same everywhere and testable) ─────────────────────────────────

/// A payout wallet address checked against the chosen network: TRC20 / TRON addresses start with T and have 34
/// characters; ERC20 / BEP20 (Ethereum, BNB Smart Chain) are 0x + 40 hex digits. A network that is not one of those
/// only needs a plausible length - the CRM, which pays out, has the last word.
String? withdrawAddressError(String? network, String address) {
  final a = address.trim();
  if (a.isEmpty) return 'Enter the wallet address.';
  final n = (network ?? '').toUpperCase();
  if (n.contains('TRC') || n.contains('TRON')) {
    return RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$').hasMatch(a) ? null : 'A TRC20 address starts with T and has 34 characters.';
  }
  if (n.contains('ERC') || n.contains('BEP') || n.contains('ETH') || n.contains('BSC')) {
    return RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a) ? null : 'An ERC20 / BEP20 address starts with 0x and has 42 characters.';
  }
  return a.length >= 10 && !a.contains(RegExp(r'\s')) ? null : 'Enter a valid wallet address.';
}

/// IBAN shape: country code, two check digits, then up to 30 letters or digits (spaces allowed). Empty is fine.
String? withdrawIbanError(String iban) {
  final v = iban.replaceAll(' ', '').toUpperCase();
  if (v.isEmpty) return null;
  return RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$').hasMatch(v) ? null : 'Enter a valid IBAN.';
}

// ── Models of what the CRM returns ───────────────────────────────────────────────────────────────

class _Account {
  const _Account(this.id, this.label, this.details);
  final int id;
  final String label;
  final String details;
}

/// A live trading account a withdrawal can be taken from (only offered when the CRM has direct
/// trading-account withdrawals switched on). [withdrawable] is null when the live balance could not be read.
class _TradingSource {
  const _TradingSource({required this.key, required this.label, required this.currency, required this.balance, required this.withdrawable, required this.error});
  final String key; // 'TRADING:<id>', exactly what the CRM expects back
  final String label;
  final String currency;
  final double balance;
  final double? withdrawable;
  final String error;
}

class _Method {
  const _Method({
    required this.key,
    required this.label,
    required this.gateway,
    required this.currency,
    required this.min,
    required this.max,
    required this.enabled,
    required this.accounts,
    required this.emptyHint,
  });
  final String key; // bank | crypto
  final String label;
  final int? gateway;
  final String currency;
  final double min, max;
  final bool enabled;
  final List<_Account> accounts;
  final String emptyHint;
}

class _Withdrawal {
  const _Withdrawal({
    required this.allowed,
    required this.reason,
    required this.methods,
    required this.uid,
    required this.wallet,
    this.directEnabled = false,
    this.accounts = const [],
  });
  final bool allowed;
  final bool directEnabled;
  final List<_TradingSource> accounts;
  final String reason;
  final List<_Method> methods;
  final String uid;
  final double wallet;
}

final _withdrawProvider = FutureProvider.autoDispose<_Withdrawal>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/withdrawals/methods/');
  final d = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
  final wallet = ((await dio.get('/wallet/')).data as Map)['data'] as Map;
  final methods = <_Method>[];
  for (final m in (d['methods'] as List? ?? const [])) {
    final j = (m as Map).cast<String, dynamic>();
    if (hideCryptoFunding && '${j['key']}' != 'bank') continue; // iPhone / iPad: bank transfer only
    methods.add(_Method(
      key: '${j['key']}',
      label: '${j['label'] ?? j['key']}',
      gateway: int.tryParse('${j['gateway']}'),
      currency: '${j['currency'] ?? 'USD'}',
      min: crmNum(j['min_amount']),
      max: crmNum(j['max_amount']),
      enabled: j['enabled'] == true,
      accounts: [
        for (final a in (j['accounts'] as List? ?? const []))
          _Account(int.tryParse('${(a as Map)['id']}') ?? 0, '${a['label'] ?? ''}', '${a['details'] ?? ''}'),
      ],
      emptyHint: '${j['empty_hint'] ?? ''}',
    ));
  }
  final accounts = <_TradingSource>[
    for (final a in (d['trading_accounts'] as List? ?? const []))
      _TradingSource(
        key: '${(a as Map)['key']}',
        label: '${a['login_id'] ?? a['account_number']}',
        currency: '${a['currency'] ?? 'USD'}',
        balance: crmNum(a['balance']),
        withdrawable: a['withdrawable'] == null ? null : crmNum(a['withdrawable']),
        error: '${a['error'] ?? ''}',
      ),
  ];
  return _Withdrawal(
    allowed: d['allowed'] != false,
    reason: '${d['block_reason'] ?? ''}',
    methods: methods,
    uid: '${d['request_uid'] ?? ''}',
    wallet: crmNum(wallet['available_balance'] ?? wallet['wallet_balance']),
    directEnabled: d['direct_withdraw_enabled'] == true,
    accounts: accounts,
  );
});

/// Withdrawal request, dynamic like the deposit flow: the methods, the saved (KYC-verified) accounts and the
/// limits come from the CRM; the form shows only the fields of the selected method and starts clean when the
/// method changes; the request is checked here the way the CRM will check it, and sent once.
class WithdrawScreen extends ConsumerStatefulWidget {
  const WithdrawScreen({super.key});
  @override
  ConsumerState<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends ConsumerState<WithdrawScreen> {
  final _amount = TextEditingController();
  final _bankName = TextEditingController();
  final _accName = TextEditingController();
  final _accNum = TextEditingController();
  final _iban = TextEditingController();
  final _swift = TextEditingController();
  final _address = TextEditingController();

  String _source = 'wallet'; // 'wallet' or a trading account's 'TRADING:<id>'
  String? _method; // key of the selected method
  int? _savedId; // a verified account chosen from the list
  String? _network;
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    for (final c in [_amount, _bankName, _accName, _accNum, _iban, _swift, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  void _clearDetails() {
    for (final c in [_bankName, _accName, _accNum, _iban, _swift, _address]) {
      c.clear();
    }
    _savedId = null;
    _network = null;
    _error = null;
  }

  /// The selected trading account, or null for the wallet (also when the account is no longer offered).
  _TradingSource? _account(_Withdrawal w) =>
      w.directEnabled ? w.accounts.where((a) => a.key == _source).firstOrNull : null;

  _Method? _selected(_Withdrawal w) {
    final enabled = w.methods.where((m) => m.enabled).toList();
    if (enabled.isEmpty) return null;
    return enabled.where((m) => m.key == _method).firstOrNull ?? enabled.first;
  }

  /// First problem with what was entered, or null. Mirrors the CRM's own rules; the CRM stays the authority.
  String? _validate(_Withdrawal w, _Method m, List<Map<String, dynamic>> networks) {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) return 'Enter a valid amount.';
    final acct = _account(w);
    if (acct != null) {
      if (acct.withdrawable == null) return 'The live balance of account ${acct.label} could not be read. Try again in a moment.';
      if (amt > acct.withdrawable!) {
        return 'The amount is more than the funds available to withdraw from account ${acct.label} (${acct.withdrawable!.toStringAsFixed(2)} ${acct.currency}).';
      }
    } else if (amt > w.wallet) {
      return 'The amount is more than your available wallet balance (${w.wallet.toStringAsFixed(2)} ${m.currency}).';
    }
    if (m.min > 0 && amt < m.min) return 'The minimum withdrawal for this method is ${m.min.toStringAsFixed(2)} ${m.currency}.';
    if (m.max > 0 && amt > m.max) return 'The maximum withdrawal for this method is ${m.max.toStringAsFixed(2)} ${m.currency}.';
    if (m.accounts.isNotEmpty) {
      return _savedId == null ? 'Select one of your verified ${m.key == 'bank' ? 'bank accounts' : 'wallets'}.' : null;
    }
    if (m.key == 'bank') {
      if (_bankName.text.trim().isEmpty) return 'Enter the bank name.';
      if (_accName.text.trim().isEmpty) return 'Enter the account holder name.';
      if (_accNum.text.trim().isEmpty && _iban.text.trim().isEmpty) return 'Enter the account number or the IBAN.';
      return withdrawIbanError(_iban.text);
    }
    if (_network == null || _network!.isEmpty) return 'Select the network.';
    return withdrawAddressError(_network, _address.text);
  }

  Future<void> _submit(_Withdrawal w, _Method m, List<Map<String, dynamic>> networks) async {
    if (_busy) return; // never a second request for the same tap
    final problem = _validate(w, m, networks);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final amt = double.parse(_amount.text.trim());
      final fields = <String, dynamic>{
        if (m.gateway != null) 'gateway': m.gateway,
        'method': m.key.toUpperCase(),
        'amount': amt.toStringAsFixed(2),
        'currency': m.currency,
        'withdraw_from': _account(w)?.key ?? 'wallet',
        if (w.uid.isNotEmpty) 'request_uid': w.uid, // the CRM ignores a repeat of the same request
        if (m.accounts.isNotEmpty)
          (m.key == 'bank' ? 'bank_account' : 'crypto_address'): _savedId
        else if (m.key == 'bank') ...{
          'manual_bank_name': _bankName.text.trim(),
          'manual_account_name': _accName.text.trim(),
          'manual_account_number': _accNum.text.trim(),
          'manual_iban': _iban.text.replaceAll(' ', '').toUpperCase(),
          'manual_swift_code': _swift.text.trim(),
        } else ...{
          'manual_crypto_address': _address.text.trim(),
          'manual_crypto_network': _network,
        },
      };
      final res = await ref.read(crmDioProvider).post('/withdrawals/', data: FormData.fromMap(fields));
      ref.invalidate(crmDashboardProvider);
      _done = crmMessage(res.data, 'Withdrawal request submitted. It is pending approval.');
    } on DioException catch (e) {
      _error = crmMessage(e, 'The withdrawal request failed. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_withdrawProvider);
    final kyc = ref.watch(kycStatusProvider).valueOrNull;
    final networks = [if (!hideCryptoFunding) for (final n in (kyc?['crypto_network_options'] as List? ?? const [])) (n as Map).cast<String, dynamic>()];
    final fieldSettings = {for (final f in (kyc?['bank_field_settings'] as List? ?? const [])) '${(f as Map)['field_key']}': f.cast<String, dynamic>()};

    String label(String key, String fallback) => '${fieldSettings[key]?['label'] ?? fallback}';

    return PortalPage(
      title: 'Withdraw',
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => LoadErrorView(e, onRetry: () => ref.invalidate(_withdrawProvider)),
        data: (w) {
          if (_done != null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const SizedBox(height: 30),
                const Icon(Icons.check_circle, size: 64, color: Color(0xFF1B9E4B)),
                const SizedBox(height: 14),
                Text(_done!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('Status: pending approval', style: TextStyle(color: Theme.of(context).hintColor)),
                const SizedBox(height: 22),
                FilledButton(onPressed: () => context.go('/home'), style: navyButton(), child: const Text('Back to Home')),
              ]),
            );
          }
          final m = _selected(w);
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!w.allowed) ...[ErrorBox(w.reason.isEmpty ? 'Withdrawals are not available right now.' : w.reason), const SizedBox(height: 12)],
            if (w.directEnabled && w.accounts.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                key: const ValueKey('source'),
                initialValue: _account(w)?.key ?? 'wallet',
                isExpanded: true,
                decoration: portalField(context, 'Withdraw from'),
                items: [
                  DropdownMenuItem(value: 'wallet', child: Text('My Wallet — ${w.wallet.toStringAsFixed(2)} USD')),
                  for (final a in w.accounts)
                    DropdownMenuItem(
                        value: a.key, child: Text('${a.label} — Balance ${a.balance.toStringAsFixed(2)}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _source = v ?? 'wallet';
                          _error = null;
                        }),
              ),
              const SizedBox(height: 12),
            ],
            InfoCard(
              child: Builder(builder: (context) {
                final acct = _account(w);
                final figure = acct == null
                    ? '${w.wallet.toStringAsFixed(2)} USD'
                    : acct.withdrawable == null
                        ? 'Unavailable'
                        : '${acct.withdrawable!.toStringAsFixed(2)} ${acct.currency}';
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(acct == null ? 'WALLET AVAILABLE' : 'AVAILABLE TO WITHDRAW · ${acct.label}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(figure, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: kNavy)),
                  if (acct != null) ...[
                    const SizedBox(height: 4),
                    Text('Balance ${acct.balance.toStringAsFixed(2)} ${acct.currency}. Open positions reduce what can be withdrawn.',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                    if (acct.error.isNotEmpty) Text(acct.error, style: const TextStyle(fontSize: 12, color: Color(0xFFE5484D))),
                  ],
                ]);
              }),
            ),
            const SizedBox(height: 8),
            Text(
                _account(w) == null
                    ? 'Withdrawals are paid from your wallet. Admin approval completes the payout.'
                    : 'The amount is taken from this trading account when the withdrawal is approved.',
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 14),
            if (m == null)
              ErrorBox(w.methods.isEmpty ? 'No withdrawal methods are available right now.' : 'Withdrawal methods are temporarily unavailable.')
            else ...[
              Wrap(spacing: 8, children: [
                for (final x in w.methods)
                  ChoiceChip(
                    key: ValueKey('method-${x.key}'),
                    label: Text(x.label),
                    selected: x.key == m.key,
                    onSelected: x.enabled && !_busy
                        ? (_) => setState(() {
                              _method = x.key;
                              _clearDetails(); // nothing of the other method stays on screen
                            })
                        : null,
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: portalField(context, 'Amount (${m.currency})'),
              ),
              if (m.min > 0 || m.max > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                      [if (m.min > 0) 'Min ${m.min.toStringAsFixed(2)}', if (m.max > 0) 'Max ${m.max.toStringAsFixed(2)}'].join(' · '),
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              const SizedBox(height: 12),
              if (m.accounts.isNotEmpty)
                DropdownButtonFormField<int>(
                  key: ValueKey('saved-${m.key}'),
                  initialValue: _savedId,
                  isExpanded: true,
                  decoration: portalField(context, m.key == 'bank' ? 'Verified bank account' : 'Verified wallet'),
                  items: [
                    for (final a in m.accounts)
                      DropdownMenuItem(value: a.id, child: Text(a.details.isEmpty ? a.label : '${a.label}\n${a.details}', overflow: TextOverflow.ellipsis, maxLines: 2)),
                  ],
                  onChanged: (v) => setState(() => _savedId = v),
                )
              else if (m.key == 'bank') ...[
                if (m.emptyHint.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(m.emptyHint, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor))),
                TextField(key: const ValueKey('bank-name'), controller: _bankName, decoration: portalField(context, '${label('bank_name', 'Bank name')} *')),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('acc-name'), controller: _accName, decoration: portalField(context, '${label('account_name', 'Account holder name')} *')),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('acc-num'), controller: _accNum, decoration: portalField(context, label('account_number', 'Account number'))),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('iban'), controller: _iban, textCapitalization: TextCapitalization.characters, decoration: portalField(context, label('iban', 'IBAN'))),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('swift'), controller: _swift, textCapitalization: TextCapitalization.characters, decoration: portalField(context, label('swift_code', 'SWIFT code'))),
              ] else ...[
                if (m.emptyHint.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(m.emptyHint, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor))),
                if (networks.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: const ValueKey('network'),
                    initialValue: _network,
                    decoration: portalField(context, 'Network *'),
                    items: [for (final n in networks) DropdownMenuItem(value: '${n['label']}', child: Text('${n['label']}'))],
                    onChanged: (v) => setState(() => _network = v),
                  )
                else
                  TextField(key: const ValueKey('network-text'), onChanged: (v) => _network = v.trim(), decoration: portalField(context, 'Network * (e.g. TRC20)')),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('address'), controller: _address, decoration: portalField(context, 'Wallet address *')),
              ],
            ],
            if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('submit'),
              onPressed: (_busy || !w.allowed || m == null) ? null : () => _submit(w, m, networks),
              style: navyButton(),
              child: Text(_busy ? 'Submitting…' : 'Submit Withdrawal'),
            ),
          ]);
        },
      ),
    );
  }
}
