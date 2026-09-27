import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../session/sessions.dart';
import 'portal_ui.dart';

const _kInvestorBg = Color(0xFFFFF1E0);
const _kInvestorFg = Color(0xFF9A5B00);

class InvestorChip extends StatelessWidget {
  const InvestorChip({super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: _kInvestorBg, borderRadius: BorderRadius.circular(8)),
        child: const Text('Investor', style: TextStyle(color: _kInvestorFg, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

/// "+" on the Trade screen: sign into another trading account (trading password =
/// full trading, investor password = read-only) and pick from saved accounts.
Future<void> showManageAccountDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ManageAccountDialog(),
    );

class _ManageAccountDialog extends ConsumerStatefulWidget {
  const _ManageAccountDialog();
  @override
  ConsumerState<_ManageAccountDialog> createState() => _ManageAccountDialogState();
}

class _ManageAccountDialogState extends ConsumerState<_ManageAccountDialog> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_id.text.trim().isEmpty || _pw.text.isEmpty) {
      setState(() => _error = 'Enter the account ID and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await ref.read(tradingSessionProvider.notifier).addManaged(_id.text, _pw.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _openSaved(ManagedAccount a) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await ref.read(tradingSessionProvider.notifier).openManaged(a);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(managedAccountsProvider);
    final active = ref.watch(tradingSessionProvider);
    return Dialog(
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? null : const Color(0xFFEFF1F6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Manage account', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text('Sign in with a trading account ID to manage it here. Use the trading password for full access or the investor password for read-only.',
                style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor, height: 1.35)),
            const SizedBox(height: 16),
            TextField(
              controller: _id,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              decoration: portalField(context, 'Account ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pw,
              obscureText: true,
              onSubmitted: (_) => _login(),
              decoration: portalField(context, 'Password'),
            ),
            if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _login, style: navyButton(), child: Text(_busy ? 'Signing in…' : 'Login')),
            if (saved.isNotEmpty) ...[
              const SizedBox(height: 22),
              const Text('Saved accounts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              for (final a in saved)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: active.login == a.login && active.managed ? kNavy : Theme.of(context).dividerColor, width: active.login == a.login && active.managed ? 1.6 : 1),
                  ),
                  child: ListTile(
                    dense: true,
                    onTap: _busy ? null : () => _openSaved(a),
                    title: Row(children: [
                      Flexible(child: Text(a.holderName.isEmpty ? 'Account' : a.holderName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                      if (a.readonly) const InvestorChip(),
                    ]),
                    subtitle: Text('Account: ${a.login}  ·  Balance: ${a.balance.toStringAsFixed(2)}${a.isDemo ? '  ·  Demo' : ''}'),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _busy ? null : () => ref.read(managedAccountsProvider.notifier).remove(a.login),
                    ),
                  ),
                ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Shows which account Quotes / Chart / Trade / History are working on and flags
/// investor (read-only) sessions clearly.
class ActiveAccountBar extends ConsumerWidget {
  const ActiveAccountBar({super.key, this.compact = false, this.onlyWhenSpecial = false});
  final bool compact;

  /// Only show for managed / read-only / loading / error states (keeps the chart clean).
  final bool onlyWhenSpecial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(tradingSessionProvider);
    final own = ref.watch(crmDashboardProvider).valueOrNull?.accounts ?? const <CrmAccount>[];
    if (s.login == null && !s.loading && s.error == null) return const SizedBox.shrink();
    if (onlyWhenSpecial && !(s.managed || s.readonly || s.loading || s.error != null)) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: s.readonly ? _kInvestorBg : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(s.readonly ? Icons.visibility_outlined : Icons.account_circle_outlined, size: 18, color: s.readonly ? _kInvestorFg : kNavy),
        const SizedBox(width: 8),
        Expanded(
          child: s.loading
              ? const Text('Opening account…', style: TextStyle(fontSize: 13))
              : s.error != null
                  ? Text(s.error!, style: const TextStyle(fontSize: 13, color: Color(0xFFC62828)))
                  : Row(children: [
                      Flexible(
                        child: Text(
                          '#${s.login}${s.holderName.isNotEmpty && s.managed ? ' · ${s.holderName}' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (s.readonly) const InvestorChip(),
                      if (s.readonly)
                        const Padding(padding: EdgeInsets.only(left: 8), child: Text('Read-only', style: TextStyle(fontSize: 12, color: _kInvestorFg))),
                    ]),
        ),
        if (s.error != null && s.login != null)
          TextButton(
            onPressed: () => ref.read(tradingSessionProvider.notifier).openOwn(s.login!),
            child: const Text('Retry'),
          ),
        if (own.length > 1 || ref.watch(managedAccountsProvider).isNotEmpty || s.managed)
          PopupMenuButton<String>(
            tooltip: 'Switch account',
            icon: const Icon(Icons.swap_vert, size: 20),
            onSelected: (v) {
              if (v == '__manage') {
                showManageAccountDialog(context);
              } else {
                ref.read(tradingSessionProvider.notifier).openOwn(v);
              }
            },
            itemBuilder: (_) => [
              for (final a in own.where((a) => a.tradingEnabled))
                PopupMenuItem(value: a.login, child: Text('My account #${a.login} · ${a.isDemo ? 'Demo' : 'Real'}')),
              const PopupMenuItem(value: '__manage', child: Text('Managed accounts…')),
            ],
          ),
      ]),
    );
  }
}
