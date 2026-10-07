import 'dart:convert';

import 'dart:async';

import 'package:btrader_core/btrader_core.dart' show BtConfig;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

/// How a deposit method is paid, decided by the server (`profile`), never guessed from its name:
/// - [manual]  bank / UPI / local transfer: the admin's account details are shown and the client
///             uploads a payment slip;
/// - [crypto]  a fixed wallet address the admin configured;
/// - [gateway] a payment provider (Match2Pay): the client picks a network and pays on the
///             provider's page. Nothing to upload.
enum DepositKind { manual, crypto, gateway }

/// One deposit method as the admin configured it in the CRM (`/deposits/methods/` `gateways[]`).
class DepositMethod {
  const DepositMethod({
    required this.id,
    required this.name,
    required this.kind,
    required this.currency,
    required this.minAmount,
    required this.processingTime,
    required this.charges,
    required this.instructions,
    required this.requireProof,
    required this.canUse,
    required this.exchangeRate,
    required this.badge,
    required this.icon,
    required this.bankName,
    required this.accountName,
    required this.accountNumber,
    required this.iban,
    required this.swift,
    required this.walletAddress,
    required this.network,
    required this.networks,
  });

  final int id;
  final String name;
  final DepositKind kind;
  final String currency;
  final double minAmount;
  final String processingTime;
  final String charges;
  final String instructions;
  final bool requireProof;
  final bool canUse;
  final double exchangeRate;
  final String badge;
  final String icon; // path or URL as stored by the CRM; '' when none
  final String bankName,
      accountName,
      accountNumber,
      iban,
      swift,
      walletAddress,
      network;

  /// Networks a provider method can be paid on (from the CRM, per currency); empty for other methods.
  final List<({String network, String label})> networks;

  static String _s(Object? v) => v == null ? '' : '$v'.trim();

  factory DepositMethod.fromJson(Map<String, dynamic> j) {
    final profile = _s(j['profile']).toUpperCase();
    return DepositMethod(
      id: int.tryParse('${j['id']}') ?? 0,
      name: _s(j['name']).isEmpty ? 'Method' : _s(j['name']),
      kind: switch (profile) {
        'MATCH2PAY' => DepositKind.gateway,
        'CRYPTO' => DepositKind.crypto,
        _ => DepositKind.manual,
      },
      currency:
          _s(j['currency']).isEmpty ? 'USD' : _s(j['currency']).toUpperCase(),
      minAmount: crmNum(j['min_amount']),
      processingTime: _s(j['processing_time']),
      charges: _s(j['charges']),
      instructions: _s(j['instructions']),
      requireProof: j['require_payment_proof'] == true,
      canUse: j['can_use'] != false,
      exchangeRate: double.tryParse(_s(j['exchange_rate'])) ?? 1,
      badge: _s(j['display_badge']),
      icon: _s(j['icon']),
      bankName: _s(j['bank_name']),
      accountName: _s(j['account_name']),
      accountNumber: _s(j['account_number']),
      iban: _s(j['iban']),
      swift: _s(j['swift_code']),
      walletAddress: _s(j['wallet_address']),
      network: _s(j['network']),
      networks: [
        for (final n in (j['networks'] as List? ?? const []))
          (
            network: _s((n as Map)['network']),
            label: _s(n['label']).isEmpty ? _s(n['network']) : _s(n['label']),
          ),
      ],
    );
  }

  /// A payment slip is required exactly when the server will insist on one: a manual method always,
  /// any other method only if the admin switched "require payment proof" on. A provider (gateway)
  /// method never asks for one.
  bool get needsProof =>
      kind != DepositKind.gateway &&
      (requireProof || kind == DepositKind.manual);

  /// The title on the method card: a provider shows what is being deposited (USDT), the rest their name.
  String get cardTitle => kind == DepositKind.gateway
      ? (currency.isEmpty ? 'USDT' : currency)
      : name;

  /// Local-currency amount the client will actually send for [usd], or null when this method is paid
  /// in dollars (or has no usable rate) and there is nothing to convert.
  double? localAmount(double usd) {
    if (kind != DepositKind.manual) return null;
    if (currency == 'USD' || exchangeRate <= 0 || exchangeRate == 1)
      return null;
    return usd * exchangeRate;
  }
}

/// Where a deposit can be credited: the wallet, or one of the client's live accounts.
class DepositTarget {
  const DepositTarget(this.value, this.label);
  final String value; // 'wallet' or the account login the CRM expects
  final String label;
}

class DepositSetup {
  const DepositSetup({
    required this.allowed,
    required this.reason,
    required this.methods,
    required this.targets,
    required this.networks,
  });
  final bool allowed;
  final String reason;
  final List<DepositMethod> methods;
  final List<DepositTarget> targets;
  final List<({String network, String label})> networks;

  factory DepositSetup.fromJson(Map<String, dynamic> d, double wallet) {
    final accounts = [
      for (final a in (d['trading_accounts'] as List? ?? const []))
        (a as Map).cast<String, dynamic>()
    ];
    return DepositSetup(
      allowed: d['allowed'] != false,
      reason: DepositMethod._s(d['block_reason']),
      methods: [
        for (final g in (d['gateways'] as List? ?? const []))
          DepositMethod.fromJson((g as Map).cast<String, dynamic>())
      ],
      targets: [
        DepositTarget('wallet', 'My Wallet — ${wallet.toStringAsFixed(2)} USD'),
        for (final a in accounts)
          DepositTarget(
            DepositMethod._s(a['login_id'] ?? a['account_number']),
            '${DepositMethod._s(a['login_id'] ?? a['account_number'])} — Balance ${crmNum(a['balance']).toStringAsFixed(2)}',
          ),
      ],
      networks: [
        for (final n in (d['crypto_networks'] as List? ?? const []))
          (
            network: DepositMethod._s((n as Map)['network']),
            label: DepositMethod._s(n['label']).isEmpty
                ? DepositMethod._s(n['network'])
                : DepositMethod._s(n['label'])
          ),
      ],
    );
  }
}

final _depositSetupProvider =
    FutureProvider.autoDispose<DepositSetup>((ref) async {
  final dio = ref.watch(crmDioProvider);
  final res = await dio.get('/deposits/methods/');
  final d = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
  double wallet = 0;
  try {
    final w = ((await dio.get('/wallet/')).data as Map)['data'] as Map;
    wallet = crmNum(w['available_balance'] ?? w['wallet_balance']);
  } catch (_) {/* the wallet line is informational; the methods still work */}
  return DepositSetup.fromJson(d, wallet);
});

/// Opens the provider's payment page. On the web it replaces this tab (a popup opened after a network
/// call is blocked by browsers); on a phone it opens the browser. Replaceable in tests.
@visibleForTesting
Future<bool> Function(Uri url) depositLauncher = (url) async {
  try {
    return await launchUrl(url,
        webOnlyWindowName: '_self',
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
};

/// A CRM-served path (`/media/...`) made absolute against the CRM's own host.
String crmAssetUrl(String path) {
  if (path.isEmpty) return '';
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  final base = Uri.parse(BtConfig.crmBase);
  return '${base.scheme}://${base.authority}${path.startsWith('/') ? '' : '/'}$path';
}

/// The Deposit screen: the admin's deposit methods as cards, and for the chosen one exactly what the
/// CRM website shows - the admin's bank details (or a provider / crypto flow), the account to credit,
/// the amount, a payment slip only where the method needs one. Everything comes from the CRM, so
/// changing a method there changes this screen.
class DepositScreen extends ConsumerStatefulWidget {
  const DepositScreen({super.key});

  @override
  ConsumerState<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends ConsumerState<DepositScreen> {
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  int? _methodId;
  String _target = 'wallet';
  String? _network;
  PlatformFile? _proof;
  bool _busy = false;
  String? _error;
  String? _done;
  Map<String, dynamic>? _session; // a created provider payment

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _select(DepositMethod m) {
    if (!m.canUse || m.id == _methodId) return;
    setState(() {
      _methodId = m.id;
      _error = null;
      _proof = null;
      _reference.clear();
    });
  }

  Future<void> _pickProof() async {
    final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true);
    if (r != null && r.files.isNotEmpty && mounted)
      setState(() => _proof = r.files.first);
  }

  Future<void> _submit(DepositSetup s, DepositMethod m) async {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }
    if (m.kind == DepositKind.gateway && (_network ?? '').isEmpty) {
      setState(() => _error = 'Select a network.');
      return;
    }
    if (m.needsProof && _proof?.bytes == null) {
      setState(() => _error = 'Upload your payment slip for this method.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dio = ref.read(crmDioProvider);
      if (m.kind == DepositKind.gateway) {
        final res = await dio.post('/deposits/crypto/', data: {
          'gateway': m.id,
          'crypto_network': _network,
          'trading_account': _target,
          'amount': amt.toStringAsFixed(2),
        });
        _session = ((res.data as Map)['data'] as Map).cast<String, dynamic>();
        // Straight on to the payment gateway, as on the website; the page below stays as the fallback.
        final url = '${_session!['checkout_url'] ?? ''}';
        if (url.isNotEmpty) unawaited(depositLauncher(Uri.parse(url)));
      } else {
        final res = await dio.post(
          '/deposits/',
          data: FormData.fromMap({
            'gateway': m.id,
            'amount': amt.toStringAsFixed(2),
            'currency':
                'USD', // the client enters dollars; the rate only tells how much to send
            'reference': _reference.text.trim(),
            'trading_account': _target,
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
            if (_proof?.bytes != null)
              'payment_screenshot': MultipartFile.fromBytes(_proof!.bytes!,
                  filename: _proof!.name),
          }),
        );
        ref.invalidate(crmDashboardProvider);
        _done = crmMessage(res.data, 'Deposit request submitted.');
      }
    } on DioException catch (e) {
      _error = crmMessage(e, 'Request failed. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(_depositSetupProvider);
    return PortalPage(
      title: 'Deposit',
      child: setup.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(
            padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (s) {
          if (_done != null)
            return _Result(message: _done!, onHome: () => context.go('/home'));
          final session = _session;
          if (session != null)
            return _GatewaySession(
                session: session, onHome: () => context.go('/home'));

          final m = s.methods.where((x) => x.id == _methodId).firstOrNull ??
              s.methods.where((x) => x.canUse).firstOrNull;
          final amt = double.tryParse(_amount.text.trim()) ?? 0;
          final target =
              s.targets.any((t) => t.value == _target) ? _target : 'wallet';
          final networks =
              (m != null && m.networks.isNotEmpty) ? m.networks : s.networks;
          final network = networks.any((n) => n.network == _network)
              ? _network
              : (networks.isEmpty ? null : networks.first.network);
          if (_network != network) _network = network;
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!s.allowed) ...[
              ErrorBox(s.reason.isEmpty
                  ? 'Deposits are not available right now.'
                  : s.reason),
              const SizedBox(height: 12)
            ],
            if (s.methods.isEmpty)
              const ErrorBox('No deposit methods available right now.')
            else
              LayoutBuilder(builder: (context, box) {
                // Two cards per row on a phone, more as the screen allows. Every card in a row is as
                // tall as the tallest, so the grid stays even whatever each method shows.
                final cols = (box.maxWidth / 170).floor().clamp(2, 4);
                const gap = 12.0;
                final rows = <Widget>[];
                for (var i = 0; i < s.methods.length; i += cols) {
                  final chunk = s.methods.skip(i).take(cols).toList();
                  rows.add(Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
                    child: IntrinsicHeight(
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var c = 0; c < cols; c++) ...[
                              if (c > 0) const SizedBox(width: gap),
                              Expanded(
                                child: c < chunk.length
                                    ? _MethodCard(
                                        method: chunk[c],
                                        selected: chunk[c].id == m?.id,
                                        onTap: () => _select(chunk[c]))
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ]),
                    ),
                  ));
                }
                return Column(children: rows);
              }),
            if (m != null) ...[
              const SizedBox(height: 22),
              Divider(height: 1, color: Theme.of(context).dividerColor),
              const SizedBox(height: 16),
              Text('Selected method',
                  style: TextStyle(
                      fontSize: 12.5, color: Theme.of(context).hintColor)),
              const SizedBox(height: 2),
              Text(
                  m.kind == DepositKind.gateway
                      ? '${m.cardTitle} (${m.name})'
                      : m.name,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800, color: kNavy)),
              const SizedBox(height: 12),
              if (m.kind == DepositKind.manual) _BankDetails(method: m),
              if (m.kind == DepositKind.crypto) _CryptoDetails(method: m),
              if (m.instructions.isNotEmpty &&
                  m.kind != DepositKind.gateway) ...[
                const SizedBox(height: 10),
                InfoCard(
                    child: Text(m.instructions,
                        style: const TextStyle(height: 1.4))),
              ],
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: ValueKey('target-${m.id}'),
                initialValue: target,
                isExpanded: true,
                decoration: portalField(context, 'Select Account *'),
                items: [
                  for (final t in s.targets)
                    DropdownMenuItem(
                        value: t.value,
                        child: Text(t.label, overflow: TextOverflow.ellipsis))
                ],
                onChanged: (v) => setState(() => _target = v ?? 'wallet'),
              ),
              if (s.targets.length == 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                      'No live deposit-enabled trading account found. Deposit will go to My Wallet.',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              if (m.kind == DepositKind.gateway) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('network-${m.id}'),
                  initialValue: network,
                  isExpanded: true,
                  decoration: portalField(context, 'Select Method *'),
                  items: [
                    for (final n in networks)
                      DropdownMenuItem(value: n.network, child: Text(n.label))
                  ],
                  onChanged: (v) => setState(() => _network = v),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: portalField(
                    context,
                    m.kind == DepositKind.gateway
                        ? 'Amount *'
                        : 'Amount (USD) *'),
              ),
              if (m.localAmount(amt) != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text.rich(TextSpan(children: [
                    const TextSpan(text: 'You will send '),
                    TextSpan(
                        text: '${_money(m.localAmount(amt)!)} ${m.currency}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    TextSpan(
                        text:
                            '\nRate: 1 USD = ${_money(m.exchangeRate)} ${m.currency}',
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).hintColor)),
                  ])),
                ),
              ],
              if (m.kind != DepositKind.gateway) ...[
                const SizedBox(height: 12),
                TextField(
                    controller: _reference,
                    decoration: portalField(context, 'Transaction ID')),
              ],
              if (m.needsProof) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pickProof,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_proof == null ? 'Upload slip *' : _proof!.name,
                      overflow: TextOverflow.ellipsis),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    foregroundColor: kNavy,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
              if (m.kind != DepositKind.gateway) ...[
                const SizedBox(height: 12),
                TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: portalField(context, 'Notes')),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                ErrorBox(_error!)
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: (_busy || !s.allowed || !m.canUse)
                    ? null
                    : () => _submit(s, m),
                style: navyButton(),
                child: Text(_busy
                    ? 'Submitting…'
                    : (m.kind == DepositKind.gateway
                        ? 'Submit'
                        : 'Deposit Now')),
              ),
              const SizedBox(height: 16),
            ],
          ]);
        },
      ),
    );
  }
}

String _money(double v) {
  final fixed = v.toStringAsFixed(2);
  final parts = fixed.split('.');
  final whole =
      parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$whole.${parts[1]}';
}

class _MethodCard extends StatelessWidget {
  const _MethodCard(
      {required this.method, required this.selected, required this.onTap});
  final DepositMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = method;
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final icon = crmAssetUrl(m.icon);
    final initials = m.kind == DepositKind.gateway
        ? 'US'
        : (m.name.length >= 2 ? m.name.substring(0, 2) : m.name).toUpperCase();
    return Opacity(
      opacity: m.canUse ? 1 : 0.6,
      child: InkWell(
        key: ValueKey('deposit-method-${m.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: m.canUse ? onTap : null,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: selected ? kNavy : Theme.of(context).dividerColor,
                width: selected ? 2 : 1),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: kNavy.withValues(alpha: 0.14),
                        blurRadius: 0,
                        spreadRadius: 3)
                  ]
                : null,
          ),
          child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 48,
                    height: 48,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.surfaceContainerHigh,
                        border:
                            Border.all(color: Theme.of(context).dividerColor)),
                    alignment: Alignment.center,
                    child: icon.isEmpty
                        ? Text(initials,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                                color: kNavy))
                        : Image.network(icon,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Text(initials,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                    color: kNavy))),
                  ),
                  const SizedBox(height: 8),
                  Text(m.cardTitle,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: kNavy)),
                  if (m.badge.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(m.badge.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 10,
                              letterSpacing: 0.6,
                              color: Color(0xFF92400E))),
                    ),
                  const SizedBox(height: 4),
                  Text('Min: ${m.minAmount.toStringAsFixed(2)} ${m.currency}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: hint)),
                  Text(
                      'Processing: ${m.processingTime.isEmpty ? '-' : m.processingTime}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: hint)),
                  if (!m.canUse)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Under maintenance',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF92400E))),
                    ),
                ]),
                if (selected)
                  const Positioned(
                      top: -8,
                      right: -4,
                      child: Icon(Icons.check_circle, size: 20, color: kNavy)),
              ]),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value,
      {this.copy = false, this.mono = false});
  final String label;
  final String value;
  final bool copy;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final shown = value.isEmpty ? '-' : value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(
                text: '$label: ',
                style: TextStyle(color: Theme.of(context).hintColor)),
            TextSpan(
                text: shown,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontFamily: mono ? 'monospace' : null,
                    fontSize: mono ? 12.5 : null)),
          ])),
        ),
        if (copy && value.isNotEmpty)
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('$label copied'),
                    duration: const Duration(seconds: 1)));
            },
            child: const Padding(
                padding: EdgeInsets.fromLTRB(8, 2, 2, 2),
                child: Icon(Icons.copy, size: 16, color: kNavy)),
          ),
      ]),
    );
  }
}

class _BankDetails extends StatelessWidget {
  const _BankDetails({required this.method});
  final DepositMethod method;

  @override
  Widget build(BuildContext context) {
    final m = method;
    return InfoCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Bank Details',
            style: TextStyle(fontWeight: FontWeight.w800, color: kNavy)),
        const SizedBox(height: 6),
        _DetailRow('Bank Name', m.bankName),
        _DetailRow('Account Name', m.accountName),
        _DetailRow('Account Number', m.accountNumber, copy: true),
        _DetailRow('IBAN', m.iban, copy: true),
        if (m.swift.isNotEmpty) _DetailRow('SWIFT', m.swift, copy: true),
        _DetailRow('Processing Time', m.processingTime),
        _DetailRow('Commission', m.charges),
      ]),
    );
  }
}

class _CryptoDetails extends StatelessWidget {
  const _CryptoDetails({required this.method});
  final DepositMethod method;

  @override
  Widget build(BuildContext context) {
    final m = method;
    return InfoCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Crypto payment details',
            style: TextStyle(fontWeight: FontWeight.w800, color: kNavy)),
        const SizedBox(height: 6),
        _DetailRow('Currency', m.currency),
        _DetailRow('Network', m.network),
        _DetailRow('Wallet Address', m.walletAddress, copy: true, mono: true),
        _DetailRow('Processing Time', m.processingTime),
      ]),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.message, required this.onHome});
  final String message;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          const SizedBox(height: 30),
          const Icon(Icons.check_circle, size: 64, color: Color(0xFF1B9E4B)),
          const SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 22),
          FilledButton(
              onPressed: onHome,
              style: navyButton(),
              child: const Text('Back to Home')),
        ]),
      );
}

/// A provider payment that was created: what to pay, where, and the provider's own page.
class _GatewaySession extends StatelessWidget {
  const _GatewaySession({required this.session, required this.onHome});
  final Map<String, dynamic> session;
  final VoidCallback onHome;

  Uint8List? _qrBytes() {
    final raw = '${session['qr_code_data'] ?? ''}';
    final i = raw.indexOf('base64,');
    if (!raw.startsWith('data:image') || i < 0) return null;
    try {
      return base64Decode(raw.substring(i + 7));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = '${session['checkout_url'] ?? ''}';
    final address = '${session['address'] ?? ''}';
    final qr = _qrBytes();
    return ListView(padding: const EdgeInsets.all(16), children: [
      InfoCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Send cryptocurrency',
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 16, color: kNavy)),
          const SizedBox(height: 6),
          Text(
              'Complete the payment on the provider\'s page. Your balance is credited once the network confirms it.',
              style: TextStyle(
                  fontSize: 12.5, color: Theme.of(context).hintColor)),
          const SizedBox(height: 10),
          _DetailRow('Network', '${session['network'] ?? ''}'),
          _DetailRow('Amount',
              '${session['amount'] ?? ''} ${session['currency'] ?? ''}'),
          if (address.isNotEmpty)
            _DetailRow('Address', address, copy: true, mono: true),
          if (qr != null)
            Center(
                child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Image.memory(qr, width: 180, height: 180))),
        ]),
      ),
      const SizedBox(height: 16),
      if (url.isNotEmpty)
        FilledButton(
          onPressed: () => launchUrl(Uri.parse(url),
              webOnlyWindowName: '_blank',
              mode: kIsWeb
                  ? LaunchMode.platformDefault
                  : LaunchMode.externalApplication),
          style: navyButton(),
          child: const Text('Open payment page'),
        ),
      const SizedBox(height: 10),
      OutlinedButton(
          onPressed: onHome,
          style:
              OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: const Text('Back to Home')),
    ]);
  }
}
