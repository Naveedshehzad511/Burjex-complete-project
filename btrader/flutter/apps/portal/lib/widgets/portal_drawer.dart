import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../session/sessions.dart';

/// Side menu — same structure as the existing portal: expandable My Fund, IB
/// Programme, My Data and Account groups, then the single-page entries, the
/// support card and Logout.
class PortalDrawer extends ConsumerWidget {
  const PortalDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void go(String route) {
      Navigator.of(context).pop();
      context.push(route);
    }

    const titleStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);

    Widget item(IconData icon, String label, VoidCallback onTap, {bool selected = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: ListTile(
            selected: selected,
            selectedTileColor: kNavy,
            selectedColor: Colors.white,
            iconColor: kNavy,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            leading: Icon(icon, size: 26),
            title: Text(label, style: titleStyle),
            onTap: onTap,
          ),
        );

    Widget group(IconData icon, String label, List<(String, String)> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(icon, size: 26, color: kNavy),
              title: Text(label, style: titleStyle),
              childrenPadding: const EdgeInsets.only(left: 30),
              children: [
                for (final c in children)
                  ListTile(
                    dense: true,
                    title: Text(c.$1, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    onTap: () => go(c.$2),
                  ),
              ],
            ),
          ),
        );

    return Drawer(
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(children: [
              Image.asset('assets/branding/logo_mark.png', width: 44, height: 44, errorBuilder: (_, __, ___) => const SizedBox(width: 44)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Burjex Prime', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: kNavy))),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: kNavy, foregroundColor: Colors.white),
                icon: const Icon(Icons.keyboard_double_arrow_left),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          Expanded(
            child: ListView(children: [
              item(Icons.home, 'Dashboard', () => Navigator.of(context).pop(), selected: true),
              group(Icons.account_balance_outlined, 'My Fund', const [
                ('Deposit', '/deposit'),
                ('Withdraw', '/withdraw'),
                ('Internal Transfer', '/transfer'),
                ('Transactions', '/p/transactions'),
              ]),
              item(Icons.account_balance_wallet_outlined, 'My Wallet', () => go('/wallet')),
              item(Icons.verified_user_outlined, 'KYC', () => go('/kyc')),
              group(Icons.groups_outlined, 'IB Programme', const [
                ('IB Dashboard', '/p/ib-dashboard'),
                ('IB Progress', '/p/ib-progress'),
                ('IB Request', '/p/ib-request'),
                ('My Clients', '/p/ib-clients'),
                ('My Commission', '/p/ib-commission'),
                ('IB Tree Chart', '/p/ib-tree'),
                ('IB Withdraw', '/p/ib-withdraw'),
                ('Team Deposits', '/p/team-deposits'),
                ('Team Withdrawals', '/p/team-withdrawals'),
              ]),
              group(Icons.bar_chart, 'My Data', const [
                ('Deposit Report', '/p/report-deposits'),
                ('Withdraw Report', '/p/report-withdrawals'),
                ('Internal Transfers', '/p/report-transfers'),
                ('Deal Report', '/p/report-deals'),
                ('Summary Report', '/p/report-summary'),
              ]),
              group(Icons.manage_accounts_outlined, 'Account', const [
                ('My Profile', '/profile'),
                ('Open Account', '/open-account'),
                ('Security / 2FA', '/p/security'),
                ('Account History', '/p/account-history'),
                ('Notifications', '/p/notifications'),
              ]),
              item(Icons.emoji_events_outlined, 'Competition', () => go('/soon/Competition')),
              item(Icons.card_giftcard_outlined, 'Trade And Win', () => go('/soon/Trade%20And%20Win')),
              item(Icons.newspaper_outlined, 'News', () => go('/soon/News')),
              item(Icons.desktop_windows_outlined, 'Trading Platform', () => go('/p/platform')),
              item(Icons.gavel_outlined, 'Legal Agreements', () => go('/p/legal')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                leading: const Icon(Icons.headset_mic_outlined, size: 30, color: kNavy),
                title: const Text('Need Help?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                subtitle: const Text('Our support team is available 24/7.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => go('/p/support'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: OutlinedButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                ref.read(tradingSessionProvider.notifier).reset();
                await ref.read(managedAccountsProvider.notifier).clear();
                await ref.read(crmSessionProvider.notifier).logout();
              },
              icon: const Icon(Icons.logout),
              label: const Text('Logout', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFD33F3A),
                side: const BorderSide(color: Color(0xFFD33F3A), width: 1.5),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
