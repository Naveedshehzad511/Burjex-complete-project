import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

/// Responsive shell. On phones it's a bottom NavigationBar; on tablet/desktop it
/// switches to a side NavigationRail and centres wide content for readability.
/// Mounting it activates the WebSocket and subscribes to symbols + accounts.
class TraderShell extends ConsumerWidget {
  const TraderShell({super.key, required this.state, required this.child});
  final GoRouterState state;
  final Widget child;

  static const _dest = [
    (path: '/markets', label: 'Markets', icon: Icons.list_rounded),
    (path: '/charts', label: 'Chart', icon: Icons.candlestick_chart_rounded),
    (path: '/portfolio', label: 'Portfolio', icon: Icons.pie_chart_outline_rounded),
    (path: '/history', label: 'History', icon: Icons.history_rounded),
    (path: '/settings', label: 'Settings', icon: Icons.settings_outlined),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Activate live data.
    final sock = ref.watch(marketSocketProvider);
    ref.watch(quotesSeedProvider); // seed last-known prices so the watchlist is never blank
    final symbols = ref.watch(symbolsProvider).valueOrNull;
    final accounts = ref.watch(accountsProvider).valueOrNull;
    if (sock != null) {
      if (symbols != null) sock.subscribe(symbols.map((s) => s.symbol).toList());
      if (accounts != null) {
        for (final a in accounts) {
          sock.watchAccount(a.id);
        }
      }
    }

    final loc = state.matchedLocation;
    final index = _dest.indexWhere((d) => loc.startsWith(d.path)).clamp(0, _dest.length - 1);
    void go(int i) => context.go(_dest[i].path);

    if (context.isWide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            extended: context.isDesktop,
            minExtendedWidth: 190,
            selectedIndex: index,
            onDestinationSelected: go,
            labelType: context.isDesktop ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            destinations: [
              for (final d in _dest) NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: child),
            ),
          ),
        ]),
      );
    }

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: go,
        destinations: [
          for (final d in _dest) NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}

/// Centres content on very wide viewports so trading panels don't stretch edge-to-edge.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 900});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) =>
      Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child));
}
