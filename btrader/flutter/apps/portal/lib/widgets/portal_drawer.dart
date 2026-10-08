import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../screens/ib_screens.dart' show IbState, ibStateProvider;
import '../session/sessions.dart';

/// Side menu — same structure as the existing portal: expandable My Fund, IB
/// Programme, My Data and Account groups, then the single-page entries, the
/// support card and Logout.
///
/// Sized to about half the viewport (see [width] below) so the screen behind it stays
/// visible; the host Scaffold dims that screen with `drawerScrimColor`, and a tap on it closes
/// the menu.
class PortalDrawer extends ConsumerWidget {
  const PortalDrawer({super.key});

  /// About half the viewport, but never so narrow that a label has to shrink or clip, and never
  /// so wide that it behaves like a full-screen page. On a very small screen it can't exceed 90%.
  static double widthFor(double viewport) =>
      (viewport * 0.5).clamp(math.min(236.0, viewport * 0.9), 320.0);

  /// Height of one menu row.
  static const double _rowHeight = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void go(String route) {
      Navigator.of(context).pop();
      context.push(route);
    }

    final ib = ref.watch(ibStateProvider).valueOrNull;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Brand navy is unreadable on the dark surface, so icons / brand text switch to the theme's
    // light accent there; on the light theme they stay navy.
    final accent = dark ? cs.primary : kNavy;
    const titleStyle =
        TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.2);
    const childStyle =
        TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.2);

    // One row layout for every entry (plain or expandable): icon, fixed gap, label. Both kinds
    // use it, so labels line up exactly and share the same row height.
    Widget row(IconData icon, String label, {Color? color}) => Row(children: [
          SizedBox(width: 24, child: Icon(icon, size: 24, color: color ?? accent)),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: titleStyle.copyWith(color: color))),
        ]);

    Widget item(IconData icon, String label, VoidCallback onTap, {bool selected = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: Material(
            color: selected ? kNavy : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _rowHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: row(icon, label, color: selected ? Colors.white : null),
                  ),
                ),
              ),
            ),
          ),
        );

    Widget group(IconData icon, String label, List<(String, String)> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              minTileHeight: _rowHeight,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              iconColor: accent,
              collapsedIconColor: cs.onSurface.withValues(alpha: 0.85),
              title: row(icon, label),
              // Sub-items start under their parent's label (24 icon + 14 gap).
              childrenPadding: const EdgeInsets.only(left: 38, bottom: 4),
              children: [
                for (final c in children)
                  ListTile(
                    dense: true,
                    minTileHeight: 40,
                    minVerticalPadding: 0,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    title: Text(c.$1, style: childStyle),
                    onTap: () => go(c.$2),
                  ),
              ],
            ),
          ),
        );

    return Drawer(
      width: widthFor(MediaQuery.sizeOf(context).width),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(20))),
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(children: [
              Image.asset('assets/branding/logo_mark.png',
                  width: 36,
                  height: 36,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 36)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Burjex Prime',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: accent)),
              ),
              IconButton.filled(
                tooltip: 'Close menu',
                style: IconButton.styleFrom(
                  backgroundColor: kNavy,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(40, 40),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                icon: const Icon(Icons.keyboard_double_arrow_left, size: 22),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          Expanded(
            child:
                ListView(padding: const EdgeInsets.only(bottom: 6), children: [
              item(Icons.home, 'Dashboard', () => Navigator.of(context).pop(),
                  selected: true),
              group(Icons.account_balance_outlined, 'My Fund', const [
                ('Deposit', '/deposit'),
                ('Withdraw', '/withdraw'),
                ('Internal Transfer', '/transfer'),
                ('Transactions', '/p/transactions'),
              ]),
              item(Icons.account_balance_wallet_outlined, 'My Wallet',
                  () => go('/wallet')),
              item(Icons.verified_user_outlined, 'KYC', () => go('/kyc')),
              // The IB menu follows where the client stands. An approved IB has the dashboard (which
              // carries clients, commission, tree, withdraw, team deposits / withdrawals and level
              // progress, so none of those are repeated here); anyone else only needs the request
              // page, and it goes away once the request is approved. While the state is unknown
              // (loading / offline) both entries are offered.
              if (ib == IbState.approved)
                item(Icons.groups_outlined, 'IB Dashboard', () => go('/ib/dashboard'))
              else if (ib == IbState.pending || ib == IbState.none)
                item(Icons.groups_outlined, 'IB Request', () => go('/ib/apply'))
              else
                group(Icons.groups_outlined, 'IB Programme', const [
                  ('IB Dashboard', '/ib/dashboard'),
                  ('IB Request', '/ib/apply'),
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
              item(Icons.emoji_events_outlined, 'Competition',
                  () => go('/soon/Competition')),
              item(Icons.card_giftcard_outlined, 'Trade And Win',
                  () => go('/soon/Trade%20And%20Win')),
              item(Icons.newspaper_outlined, 'News', () => go('/soon/News')),
              item(Icons.desktop_windows_outlined, 'Trading Platform',
                  () => go('/trading-platform')),
              item(
                  Icons.gavel_outlined, 'Legal Agreements', () => go('/legal')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Material(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
              child: ListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                minLeadingWidth: 28,
                horizontalTitleGap: 12,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                leading:
                    Icon(Icons.headset_mic_outlined, size: 26, color: accent),
                title: const Text('Need Help?',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                subtitle: Text('Our support team is available 24/7.',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        color: cs.onSurface.withValues(alpha: 0.72))),
                trailing: Icon(Icons.chevron_right,
                    color: cs.onSurface.withValues(alpha: 0.85)),
                onTap: () => go('/p/support'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
            child: OutlinedButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                ref.read(tradingSessionProvider.notifier).reset();
                await ref.read(managedAccountsProvider.notifier).clear();
                await ref.read(crmSessionProvider.notifier).logout();
              },
              icon: const Icon(Icons.logout, size: 22),
              label: const Text('Logout',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE5524D),
                side: const BorderSide(color: Color(0xFFE5524D), width: 1.5),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
