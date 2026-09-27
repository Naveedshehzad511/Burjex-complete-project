import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

/// Live portal.burjexprime.net bottom nav. Do not add Markets / Portfolio / Settings.
class PortalTabs {
  static const dest = <({String path, String label, IconData icon})>[
    (path: '/home', label: 'Home', icon: Icons.home_outlined),
    (path: '/quotes', label: 'Quotes', icon: Icons.list_alt_outlined),
    (path: '/chart', label: 'Chart', icon: Icons.candlestick_chart),
    (path: '/trade', label: 'Trade', icon: Icons.swap_horiz),
    (path: '/history', label: 'History', icon: Icons.history),
  ];

  static List<String> get labels => [for (final d in dest) d.label];
}

class PortalShell extends ConsumerWidget {
  const PortalShell({super.key, required this.state, required this.child});
  final GoRouterState state;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sock = ref.watch(marketSocketProvider);
    ref.watch(quotesSeedProvider);
    ref.watch(feedSubscriptionProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull;
    final accounts = ref.watch(accountsProvider).valueOrNull;
    if (sock != null) {
      if (symbols != null) {
        sock.subscribe(symbols.map((s) => s.symbol).toList());
      }
      if (accounts != null) {
        for (final a in accounts) {
          sock.watchAccount(a.id);
        }
      }
    }

    final loc = state.matchedLocation;
    final index = PortalTabs.dest.indexWhere((d) => loc.startsWith(d.path)).clamp(0, PortalTabs.dest.length - 1);
    void go(int i) => context.go(PortalTabs.dest[i].path);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: go,
        destinations: [
          for (final d in PortalTabs.dest) NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
