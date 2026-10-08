import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../widgets/portal_ui.dart';

// ── What the CRM offers (the website's lists are the fallback when the admin has configured none) ──

/// Identity document types, from the CRM's required-document list.
List<String> kycIdentityTypes(Map<String, dynamic> d) {
  final fromCrm = [
    for (final o in (d['identity_document_options'] as List? ?? const [])) '${(o as Map)['name'] ?? ''}'.trim(),
  ].where((s) => s.isNotEmpty).toList();
  return fromCrm.isNotEmpty ? fromCrm : const ['National ID', 'Passport', 'Driving License'];
}

/// Crypto networks, from the CRM. The CRM stores the network by its label.
List<String> kycCryptoNetworks(Map<String, dynamic> d) {
  final fromCrm = [
    for (final o in (d['crypto_network_options'] as List? ?? const [])) '${(o as Map)['label'] ?? ''}'.trim(),
  ].where((s) => s.isNotEmpty).toList();
  return fromCrm.isNotEmpty ? fromCrm : const ['USDT TRC20', 'USDT ERC20', 'USDT BEP20', 'BTC', 'ETH'];
}

/// A passport is a single page; any other document needs a back as well.
bool kycBackRequired(String documentType) => !documentType.toLowerCase().contains('passport');

/// One bank-detail field the form shows.
class KycBankField {
  const KycBankField(this.key, this.label, {this.required = false, this.number = false});
  final String key; // the name the CRM expects
  final String label;
  final bool required;
  final bool number;
}

/// The bank fields to show: the website's set, in its order, limited to what the admin enabled and
/// labelled and marked required in the CRM. Holder name and bank name are always asked for.
List<KycBankField> kycBankFields(Map<String, dynamic> d) {
  const base = <(String, String)>[
    ('account_name', 'Account Title'),
    ('bank_name', 'Bank Name'),
    ('account_number', 'Account Number'),
    ('iban', 'IBAN'),
    ('swift_code', 'SWIFT Code'),
    ('bank_country', 'Country'),
  ];
  final settings = <String, ({String label, bool required})>{};
  for (final s in (d['bank_field_settings'] as List? ?? const [])) {
    final m = (s as Map).cast<String, dynamic>();
    var key = '${m['field_key'] ?? ''}';
    if (key == 'country') key = 'bank_country';
    settings[key] = (label: '${m['label'] ?? ''}'.trim(), required: m['is_required'] == true);
  }
  const core = {'account_name', 'bank_name'};
  return [
    for (final (key, fallback) in base)
      if (settings.isEmpty || settings.containsKey(key) || core.contains(key))
        KycBankField(
          key,
          (settings[key]?.label.isNotEmpty ?? false) ? settings[key]!.label : fallback,
          required: core.contains(key) || (settings[key]?.required ?? false),
        ),
  ];
}

final kycStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(crmDioProvider).get('/kyc/status/');
  return ((res.data as Map)['data'] as Map).cast<String, dynamic>();
});

Color _statusColor(String s) {
  final l = s.toLowerCase();
  if (l.contains('approved') || l.contains('verified')) return const Color(0xFF1B7A3B);
  if (l.contains('reject')) return const Color(0xFFC62828);
  return const Color(0xFF9A5B00);
}

/// KYC: identity (document front and back), bank account and crypto wallet. Each is submitted here,
/// the same as on the CRM website, and the status follows the team's review.
class KycScreen extends ConsumerWidget {
  const KycScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, Widget sheet) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => sheet,
    );
    if (saved == null) return;
    ref.invalidate(kycStatusProvider);
    ref.invalidate(crmProfileProvider);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(saved)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(kycStatusProvider);
    return PortalPage(
      title: 'KYC',
      child: k.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: ErrorBox(crmMessage(e))),
        data: (d) {
          final reason = '${d['kyc_reject_reason'] ?? ''}';
          final identityStatus = '${d['identity_status_ui'] ?? 'Not Submitted'}';
          final identity = (d['identity_latest'] as Map?)?.cast<String, dynamic>();
          final bank = (d['bank_latest'] as Map?)?.cast<String, dynamic>();
          final crypto = (d['crypto_latest'] as Map?)?.cast<String, dynamic>();
          final underReview = identityStatus == 'Pending' && d['identity_can_upload'] != true;

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
            _Section(
              title: 'Identity',
              status: identityStatus,
              lines: [
                if (identity != null && '${identity['document_type'] ?? ''}'.isNotEmpty) 'Document: ${identity['document_type']}',
                if (underReview) 'Your documents are under review.',
              ],
              action: d['identity_can_upload'] == true ? (identity == null ? 'Upload documents' : 'Upload again') : null,
              onAction: () => _open(context, ref, _IdentitySheet(status: d)),
            ),
            const SizedBox(height: 10),
            _Section(
              title: 'Bank account',
              status: '${d['bank_status_ui'] ?? 'Not Submitted'}',
              lines: [
                if (bank != null) ...[
                  if ('${bank['bank_name'] ?? ''}'.isNotEmpty) '${bank['bank_name']}',
                  if ('${bank['account_name'] ?? ''}'.isNotEmpty) '${bank['account_name']}',
                  if ('${bank['account_number'] ?? ''}'.isNotEmpty) '${bank['account_number']}',
                ],
              ],
              action: d['bank_can_submit'] == true ? (bank == null ? 'Add bank account' : 'Add another') : null,
              onAction: () => _open(context, ref, _BankSheet(status: d)),
            ),
            const SizedBox(height: 10),
            _Section(
              title: 'Crypto wallet',
              status: '${d['crypto_status_ui'] ?? 'Not Submitted'}',
              lines: [
                if (crypto != null) ...[
                  if ('${crypto['network'] ?? ''}'.isNotEmpty) '${crypto['network']}',
                  if ('${crypto['wallet_address'] ?? ''}'.isNotEmpty) '${crypto['wallet_address']}',
                ],
              ],
              action: d['crypto_can_submit'] == true ? (crypto == null ? 'Add crypto wallet' : 'Add another') : null,
              onAction: () => _open(context, ref, _CryptoSheet(status: d)),
            ),
            const SizedBox(height: 16),
            Text(
              'Your documents and details are reviewed by our team. The status above updates here as soon as they are.',
              style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor, height: 1.4),
            ),
          ]);
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.status, required this.lines, required this.action, required this.onAction});
  final String title;
  final String status;
  final List<String> lines;
  final String? action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return InfoCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          Text(status, style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w700)),
        ]),
        for (final l in lines)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(l, style: TextStyle(fontSize: 13.5, color: Theme.of(context).hintColor))),
        if (action != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onAction,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: kNavy,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
            ),
            child: Text(action!, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );
  }
}

// ── Forms ───────────────────────────────────────────────────────────────────────────────────────

/// Shell for a form sheet: title, scrollable body, keyboard-aware.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          ...children,
        ]),
      );
}

Future<String?> _post(WidgetRef ref, Object data, String ok) async {
  final res = await ref.read(crmDioProvider).post('/kyc/upload/', data: data);
  return crmMessage(res.data, ok);
}

class _FilePick extends StatelessWidget {
  const _FilePick({required this.label, required this.file, required this.onPick});
  final String label;
  final PlatformFile? file;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onPick,
        icon: Icon(file == null ? Icons.upload_file : Icons.check_circle, color: file == null ? null : const Color(0xFF1B7A3B)),
        label: Text(file == null ? label : file!.name, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          foregroundColor: kNavy,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      );
}

class _IdentitySheet extends ConsumerStatefulWidget {
  const _IdentitySheet({required this.status});
  final Map<String, dynamic> status;
  @override
  ConsumerState<_IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends ConsumerState<_IdentitySheet> {
  late final List<String> _types = kycIdentityTypes(widget.status);
  late String _type = _types.contains('Passport') ? 'Passport' : _types.first;
  PlatformFile? _front, _back;
  bool _busy = false;
  String? _error;

  Future<PlatformFile?> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'], withData: true);
    return r == null || r.files.isEmpty ? null : r.files.first;
  }

  Future<void> _submit() async {
    final backNeeded = kycBackRequired(_type);
    if (_front?.bytes == null) return setState(() => _error = 'Upload the front of your document.');
    if (backNeeded && _back?.bytes == null) return setState(() => _error = 'Upload the back of your document.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await _post(
        ref,
        FormData.fromMap({
          'action': 'upload_identity',
          'identity_document_type': _type,
          'identity_front': MultipartFile.fromBytes(_front!.bytes!, filename: _front!.name),
          if (_back?.bytes != null) 'identity_back': MultipartFile.fromBytes(_back!.bytes!, filename: _back!.name),
        }),
        'Identity documents submitted.',
      );
      if (mounted) Navigator.pop(context, msg);
      return;
    } on DioException catch (e) {
      _error = crmMessage(e, 'Could not submit. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final backNeeded = kycBackRequired(_type);
    return _Sheet(title: 'Identity verification', children: [
      DropdownButtonFormField<String>(
        initialValue: _type,
        isExpanded: true,
        decoration: portalField(context, 'Document Type'),
        items: [for (final t in _types) DropdownMenuItem(value: t, child: Text(t))],
        onChanged: (v) => setState(() => _type = v ?? _type),
      ),
      const SizedBox(height: 12),
      _FilePick(label: 'Upload document (Front) *', file: _front, onPick: () async {
        final f = await _pick();
        if (f != null && mounted) setState(() => _front = f);
      }),
      const SizedBox(height: 12),
      _FilePick(label: backNeeded ? 'Upload document (Back) *' : 'Upload document (Back, if any)', file: _back, onPick: () async {
        final f = await _pick();
        if (f != null && mounted) setState(() => _back = f);
      }),
      const SizedBox(height: 6),
      Text('JPG, PNG or PDF. Make sure the whole document is visible and readable.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
      if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _submit, style: navyButton(), child: Text(_busy ? 'Submitting…' : 'Submit')),
    ]);
  }
}

class _BankSheet extends ConsumerStatefulWidget {
  const _BankSheet({required this.status});
  final Map<String, dynamic> status;
  @override
  ConsumerState<_BankSheet> createState() => _BankSheetState();
}

class _BankSheetState extends ConsumerState<_BankSheet> {
  late final List<KycBankField> _fields = kycBankFields(widget.status);
  late final Map<String, TextEditingController> _c = {for (final f in _fields) f.key: TextEditingController()};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String key) => (_c[key]?.text ?? '').trim();

  Future<void> _submit() async {
    for (final f in _fields) {
      if (f.required && _v(f.key).isEmpty && f.key != 'account_number' && f.key != 'iban') {
        return setState(() => _error = '${f.label} is required.');
      }
    }
    if (_v('account_number').isEmpty && _v('iban').isEmpty) {
      return setState(() => _error = 'Enter an account number or an IBAN.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await _post(ref, {'action': 'submit_bank', for (final f in _fields) f.key: _v(f.key)}, 'Bank details saved.');
      if (mounted) Navigator.pop(context, msg);
      return;
    } on DioException catch (e) {
      _error = crmMessage(e, 'Could not save. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return _Sheet(title: 'Bank account', children: [
      for (final f in _fields) ...[
        TextField(
          controller: _c[f.key],
          textCapitalization: f.key == 'iban' || f.key == 'swift_code' ? TextCapitalization.characters : TextCapitalization.words,
          decoration: portalField(context, f.required ? '${f.label} *' : f.label),
        ),
        const SizedBox(height: 12),
      ],
      if (_error != null) ...[ErrorBox(_error!), const SizedBox(height: 12)],
      FilledButton(onPressed: _busy ? null : _submit, style: navyButton(), child: Text(_busy ? 'Saving…' : 'Save')),
    ]);
  }
}

class _CryptoSheet extends ConsumerStatefulWidget {
  const _CryptoSheet({required this.status});
  final Map<String, dynamic> status;
  @override
  ConsumerState<_CryptoSheet> createState() => _CryptoSheetState();
}

class _CryptoSheetState extends ConsumerState<_CryptoSheet> {
  late final List<String> _networks = kycCryptoNetworks(widget.status);
  late String _network = _networks.first;
  final _address = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_address.text.trim().isEmpty) return setState(() => _error = 'Enter your wallet address.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await _post(
        ref,
        {'action': 'submit_crypto', 'crypto_network': _network, 'wallet_address': _address.text.trim(), 'wallet_name': _name.text.trim()},
        'Crypto details saved.',
      );
      if (mounted) Navigator.pop(context, msg);
      return;
    } on DioException catch (e) {
      _error = crmMessage(e, 'Could not save. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return _Sheet(title: 'Crypto wallet', children: [
      DropdownButtonFormField<String>(
        initialValue: _network,
        isExpanded: true,
        decoration: portalField(context, 'Network *'),
        items: [for (final n in _networks) DropdownMenuItem(value: n, child: Text(n))],
        onChanged: (v) => setState(() => _network = v ?? _network),
      ),
      const SizedBox(height: 12),
      TextField(controller: _address, decoration: portalField(context, 'Wallet Address *')),
      const SizedBox(height: 12),
      TextField(controller: _name, decoration: portalField(context, 'Wallet Name (optional label)')),
      if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _submit, style: navyButton(), child: Text(_busy ? 'Saving…' : 'Save')),
    ]);
  }
}
