import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crm/crm.dart';
import 'portal_ui.dart';
import 'trade_toast.dart';

/// The 3-dot menu of an account card on Home: change the trading password, the investor
/// password, or the leverage of that account. Same rules as the CRM web portal (the app calls the
/// same CRM endpoints): a password change needs the code emailed to the client, a leverage change
/// is limited to the plan's maximum and needs trading enabled.
enum AccountAction { tradingPassword, investorPassword, leverage }

class AccountMenuButton extends ConsumerWidget {
  const AccountMenuButton({super.key, required this.account});
  final CrmAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<AccountAction>(
      tooltip: 'Account settings',
      icon: const Icon(Icons.more_vert),
      padding: EdgeInsets.zero,
      onSelected: (a) {
        switch (a) {
          case AccountAction.tradingPassword:
            showDialog<void>(context: context, builder: (_) => ChangePasswordDialog(account: account, mode: 'trading'));
          case AccountAction.investorPassword:
            showDialog<void>(context: context, builder: (_) => ChangePasswordDialog(account: account, mode: 'investor'));
          case AccountAction.leverage:
            showDialog<void>(context: context, builder: (_) => ChangeLeverageDialog(account: account));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: AccountAction.tradingPassword, child: Text('Change trading password')),
        const PopupMenuItem(value: AccountAction.investorPassword, child: Text('Change investor password')),
        PopupMenuItem(
          value: AccountAction.leverage,
          enabled: account.tradingEnabled,
          child: const Text('Change leverage'),
        ),
      ],
    );
  }
}

Map<String, dynamic> _data(Response<dynamic> r) {
  final d = r.data;
  final inner = d is Map ? d['data'] : null;
  return inner is Map ? inner.cast<String, dynamic>() : const <String, dynamic>{};
}

// ── Leverage ────────────────────────────────────────────────────────────────

class ChangeLeverageDialog extends ConsumerStatefulWidget {
  const ChangeLeverageDialog({super.key, required this.account});
  final CrmAccount account;

  @override
  ConsumerState<ChangeLeverageDialog> createState() => _ChangeLeverageDialogState();
}

class _ChangeLeverageDialogState extends ConsumerState<ChangeLeverageDialog> {
  List<int> _options = const [];
  int? _selected;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(crmDioProvider).get('/accounts/${widget.account.login}/leverage/');
      final d = _data(res);
      final opts = [for (final v in (d['options'] as List? ?? const [])) int.tryParse('$v') ?? 0]..removeWhere((v) => v <= 0);
      final cur = int.tryParse('${d['current_leverage']}') ?? widget.account.leverage;
      if (!mounted) return;
      setState(() {
        _options = opts;
        _selected = opts.contains(cur) ? cur : (opts.isEmpty ? null : opts.first);
        _loading = false;
        if (d['trading_enabled'] == false) _error = 'Leverage cannot be changed while trading is disabled on this account.';
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = crmMessage(e, 'Could not load the leverage options.');
      });
    }
  }

  Future<void> _save() async {
    final v = _selected;
    if (v == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(crmDioProvider).post('/accounts/${widget.account.login}/leverage/', data: {'leverage': v});
      ref.invalidate(crmDashboardProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ToastHost.show('Leverage updated', '${widget.account.login} is now 1:$v. ${crmMessage(res.data, '')}'.trim());
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = crmMessage(e, 'Could not change the leverage.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Change leverage · ${widget.account.login}'),
      content: _loading
          ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_options.isNotEmpty)
                DropdownButtonFormField<int>(
                  initialValue: _selected,
                  decoration: portalField(context, 'Leverage'),
                  items: [for (final o in _options) DropdownMenuItem(value: o, child: Text('1:$o'))],
                  onChanged: _busy ? null : (v) => setState(() => _selected = v),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
              ],
            ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || _loading || _selected == null || _selected == widget.account.leverage ? null : _save,
          style: navyButton(),
          child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Update'),
        ),
      ],
    );
  }
}

// ── Trading / investor password ─────────────────────────────────────────────

/// Two steps, like the CRM web portal: enter the new password and ask for a code (emailed to the
/// client), then enter the code. The new password is sent again with the code; the server does not
/// keep it between the two calls.
class ChangePasswordDialog extends ConsumerStatefulWidget {
  const ChangePasswordDialog({super.key, required this.account, required this.mode});
  final CrmAccount account;

  /// `trading` or `investor`.
  final String mode;

  @override
  ConsumerState<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<ChangePasswordDialog> {
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  String get _label => widget.mode == 'trading' ? 'trading' : 'investor';

  @override
  void dispose() {
    _new.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _call(Map<String, dynamic> body, void Function(Response<dynamic>) onOk) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(crmDioProvider).post('/accounts/${widget.account.login}/credential/${widget.mode}/', data: body);
      if (!mounted) return;
      setState(() => _busy = false);
      onOk(res);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = crmMessage(e, 'Could not change the password.');
      });
    }
  }

  Map<String, dynamic> get _passwords => {'new_password': _new.text, 'confirm_password': _confirm.text};

  Future<void> _requestCode() {
    if (_new.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return Future.value();
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = 'Password confirmation does not match.');
      return Future.value();
    }
    return _call({'action': 'request_otp', ..._passwords}, (_) => setState(() => _codeSent = true));
  }

  Future<void> _verify() {
    if (_code.text.trim().length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return Future.value();
    }
    return _call({'action': 'verify_otp', 'otp_code': _code.text.trim(), ..._passwords}, (res) {
      Navigator.of(context).pop();
      ToastHost.show('Password changed', 'The $_label password of ${widget.account.login} was updated.');
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Change $_label password · ${widget.account.login}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _new, obscureText: true, enabled: !_codeSent && !_busy, decoration: portalField(context, 'New $_label password')),
          const SizedBox(height: 12),
          TextField(controller: _confirm, obscureText: true, enabled: !_codeSent && !_busy, decoration: portalField(context, 'Confirm new password')),
          if (_codeSent) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: !_busy,
              decoration: portalField(context, 'Verification code', helper: 'We emailed a 6-digit code to you. It expires in 10 minutes.'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : (_codeSent ? _verify : _requestCode),
          style: navyButton(),
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(_codeSent ? 'Change password' : 'Send code'),
        ),
      ],
    );
  }
}
