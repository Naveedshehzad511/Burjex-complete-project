import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

/// App settings — the active account header, an accounts switcher, theme mode,
/// notification prefs, about, and sign out. No deposit/withdrawal/leverage
/// here: B-Trader is the platform, not the broker.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final liveAcc = ref.watch(liveAccountProvider);
    final activeId = ref.watch(activeAccountIdProvider);

    Account? active;
    for (final a in accounts) {
      if (a.id == activeId) active = a;
    }
    active ??= accounts.isEmpty ? null : accounts.first;
    // Owner name is the same across a trader's accounts; take the first present.
    String? ownerName;
    for (final a in accounts) {
      if (a.ownerName != null && a.ownerName!.isNotEmpty) {
        ownerName = a.ownerName;
        break;
      }
    }
    // Prefer the live (WS) balance for the active account.
    final activeLive = active == null ? null : (liveAcc[active.id] ?? active);
    final tc = Theme.of(context).extension<TradeColors>()!;

    void switchTo(Account a) {
      ref.read(activeAccountIdProvider.notifier).state = a.id;
    }

    // Self-serve demo account (virtual balance, real prices, B-book only).
    // Show the new demo account's login + password so the client can save them
    // (they can also just switch to it in-app — same login).
    Future<void> showCredentials(String login, String password) async {
      Widget row(String k, String v) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              SizedBox(width: 92, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
              Expanded(child: SelectableText(v, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]))),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: v)),
              ),
            ]),
          );
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Demo account ready'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Save these — you can log in by account number on any device, or just switch to it here in the app.'),
            const SizedBox(height: 10),
            row('Account #', login),
            row('Password', password),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    }

    Future<void> openDemo() async {
      final balance = TextEditingController(text: '10000');
      final pass = TextEditingController();
      String currency = 'USD';
      String leverage = '100';
      final created = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: const Text('Open demo account'),
            content: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: currency,
                      decoration: const InputDecoration(labelText: 'Currency'),
                      items: const ['USD', 'EUR', 'GBP', 'AED', 'JPY'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) => setDlg(() => currency = v ?? 'USD'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: leverage,
                      decoration: const InputDecoration(labelText: 'Leverage 1:'),
                      items: const ['50', '100', '200', '500', '1000'].map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
                      onChanged: (v) => setDlg(() => leverage = v ?? '100'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: balance,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Starting balance', helperText: 'Virtual funds — choose any amount'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pass,
                  decoration: const InputDecoration(labelText: 'Password (optional)', helperText: 'Leave blank to auto-generate a login password'),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
            ],
          ),
        ),
      );
      if (created != true) return;
      try {
        final res = await ref.read(apiClientProvider).post('/accounts/demo', {
          'currency': currency,
          'leverage': int.tryParse(leverage) ?? 100,
          'balance': double.tryParse(balance.text) ?? 0,
          if (pass.text.trim().length >= 6) 'password': pass.text.trim(),
        });
        ref.invalidate(accountsProvider);
        final newId = res['id'];
        if (newId is String) ref.read(activeAccountIdProvider.notifier).state = newId;
        if (context.mounted) {
          await showCredentials('${res['login'] ?? ''}', '${res['password'] ?? ''}');
        }
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create demo account')));
      }
    }

    // Top up / reset a demo account's virtual balance to any amount.
    Future<void> topUpDemo(Account a) async {
      final ctrl = TextEditingController(text: a.balance.toStringAsFixed(2));
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Demo balance'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Set balance (${a.currency})', helperText: 'Top up or reset your demo funds'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await ref.read(apiClientProvider).post('/accounts/${a.id}/demo-balance', {'balance': double.tryParse(ctrl.text) ?? 0});
        ref.invalidate(accountsProvider);
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Demo balance updated')));
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Update failed')));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        // ── Active account header (client name + account number) ──
        if (active != null && activeLive != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(ownerName ?? brand.appName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                _AccountBadge(isDemo: active.isDemo),
              ]),
              const SizedBox(height: 2),
              Text(brand.appName, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
              const SizedBox(height: 10),
              Row(children: [
                _Chip(icon: Icons.tag, label: '#${active.login}'),
                const SizedBox(width: 8),
                if (active.groupName != null) _Chip(icon: Icons.workspaces_outline, label: active.groupName!),
                const Spacer(),
                Text('1:${active.leverage}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
              ]),
              const Divider(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Balance', style: TextStyle(color: Theme.of(context).hintColor)),
                Text('${money(activeLive.balance)} ${active.currency}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Equity', style: TextStyle(color: Theme.of(context).hintColor)),
                Text(money(activeLive.liveEquity),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ]),
          ),
        // ── Accounts switcher + demo ──
        const _SectionLabel('Accounts'),
        if (accounts.length > 1)
          for (final a in accounts)
            _AccountTile(
              account: liveAcc[a.id] ?? a,
              login: a.login,
              currency: a.currency,
              groupName: a.groupName,
              type: a.type,
              broker: brand.appName,
              isDemo: a.isDemo,
              selected: a.id == active?.id,
              accent: tc.up,
              onTap: () => switchTo(a),
            ),
        if (active != null && active.isDemo)
          ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: const Text('Top up / reset demo balance'),
            subtitle: Text('${money(active.balance)} ${active.currency}'),
            onTap: () => topUpDemo(active!),
          ),
        ListTile(
          leading: Icon(Icons.add_circle_outline, color: tc.up),
          title: const Text('Open demo account'),
          subtitle: const Text('Virtual funds, real prices — practice risk-free'),
          onTap: openDemo,
        ),
        const _SectionLabel('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Dark')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
        ),
        const _SectionLabel('Notifications'),
        SwitchListTile(value: true, onChanged: (_) {}, title: const Text('Order fills')),
        SwitchListTile(value: true, onChanged: (_) {}, title: const Text('Margin call alerts')),
        SwitchListTile(value: false, onChanged: (_) {}, title: const Text('Price alerts')),
        const _SectionLabel('About'),
        ListTile(title: const Text('App'), trailing: Text(brand.appName)),
        const ListTile(title: Text('Version'), trailing: Text('1.0.0')),
        const Divider(height: 24),
        ListTile(
          leading: const Icon(Icons.logout, color: Color(0xFFE5484D)),
          title: const Text('Sign out', style: TextStyle(color: Color(0xFFE5484D))),
          onTap: () => ref.read(authControllerProvider.notifier).logout(),
        ),
        const SizedBox(height: 16),
        Center(child: Text(brand.appName, style: TextStyle(color: Theme.of(context).hintColor))),
        const SizedBox(height: 24),
      ]),
    );
  }
}

/// One selectable account row (MT5-style): label, number · broker, balance, and
/// a check on the active one.
class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.login,
    required this.currency,
    required this.groupName,
    required this.type,
    required this.broker,
    required this.isDemo,
    required this.selected,
    required this.accent,
    required this.onTap,
  });
  final Account account;
  final String login;
  final String currency;
  final String? groupName;
  final String type;
  final String broker;
  final bool isDemo;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = (groupName != null && groupName!.isNotEmpty) ? groupName! : type;
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: accent.withValues(alpha: 0.08),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.15) : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.candlestick_chart, size: 22, color: selected ? accent : Theme.of(context).hintColor),
      ),
      title: Row(children: [
        Flexible(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
        Padding(padding: const EdgeInsets.only(left: 6), child: _AccountBadge(isDemo: isDemo)),
      ]),
      subtitle: Text('$login · $broker', style: const TextStyle(fontSize: 12)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${money(account.balance)} $currency',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
        if (selected)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle, size: 13, color: accent),
            const SizedBox(width: 3),
            Text('Active', style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w600)),
          ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: Theme.of(context).hintColor),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Account-type pill: orange DEMO for virtual accounts, teal LIVE for real ones.
class _AccountBadge extends StatelessWidget {
  const _AccountBadge({required this.isDemo});
  final bool isDemo;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: isDemo ? const Color(0xFFFFA726) : const Color(0xFF26A69A), borderRadius: BorderRadius.circular(5)),
        child: Text(isDemo ? 'DEMO' : 'LIVE',
            style: TextStyle(color: isDemo ? const Color(0xFF4A2A00) : const Color(0xFF06342B), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: 0.5, color: Theme.of(context).hintColor)),
      );
}
