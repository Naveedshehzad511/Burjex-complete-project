import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'crm/crm.dart';
import 'services/sound_service.dart';
import 'session/sessions.dart';

/// Responsive shell. On phones it's a bottom NavigationBar; on tablet/desktop it
/// switches to a side NavigationRail and centres wide content for readability.
///
/// Mounting it is what starts everything live, so the market feed begins the
/// moment the app opens — not when a chart is first opened:
///   1. it opens the user's own trading account on the gateway (credentials come
///      from the CRM), which authenticates the WebSocket;
///   2. it keeps the WebSocket + symbol subscription alive on every tab.
class PortalShell extends ConsumerStatefulWidget {
  const PortalShell({super.key, required this.state, required this.child});
  final GoRouterState state;
  final Widget child;

  static const _dest = [
    (path: '/home', label: 'Home', icon: Icons.home_outlined, selected: Icons.home),
    (path: '/quotes', label: 'Quotes', icon: Icons.show_chart, selected: Icons.show_chart),
    (path: '/chart', label: 'Chart', icon: Icons.candlestick_chart_outlined, selected: Icons.candlestick_chart),
    (path: '/trade', label: 'Trade', icon: Icons.swap_horiz, selected: Icons.swap_horiz),
    (path: '/history', label: 'History', icon: Icons.history, selected: Icons.history),
  ];

  @override
  ConsumerState<PortalShell> createState() => _PortalShellState();
}

class _PortalShellState extends ConsumerState<PortalShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the background: make sure the price feed is really alive.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.read(marketSocketProvider)?.onAppResumed();
  }

  bool _booting = false;

  /// Once the CRM tells us which accounts the user has, reopen the account Quotes /
  /// Chart / Trade / History were last on — including another client's account
  /// opened read-only through Trade → "+" — so a refresh never silently swaps it
  /// for the main account. Falls back to the user's own primary account when
  /// nothing (usable) was remembered for this user.
  Future<void> _bootstrapPrimary(CrmDashboard? dash) async {
    if (dash == null || dash.accounts.isEmpty || _booting) return;
    final s = ref.read(tradingSessionProvider);
    if (s.login != null || s.loading) return; // already opened / opening / failed once
    _booting = true;
    try {
      final session = ref.read(tradingSessionProvider.notifier);
      final own = [for (final a in dash.accounts) a.login];
      final last = await LastTrading.read();
      if (!mounted || ref.read(tradingSessionProvider).login != null) return;
      if (last != null && last.belongsTo(own)) {
        if (last.managed) {
          final saved = ref.read(managedAccountsProvider.notifier);
          await saved.loaded;
          final hit = ref.read(managedAccountsProvider).where((a) => a.login == last.login);
          if (hit.isNotEmpty && await session.openManaged(hit.first) == null) return;
        } else if (dash.accounts.any((a) => a.login == last.login && a.tradingEnabled)) {
          unawaited(session.openOwn(last.login));
          return;
        }
      }
      final usable = dash.accounts.where((a) => a.tradingEnabled && a.status.toUpperCase() == 'ACTIVE').toList();
      final pick = usable.firstWhere((a) => !a.isDemo, orElse: () => usable.isNotEmpty ? usable.first : dash.accounts.first);
      unawaited(session.openOwn(pick.login));
    } finally {
      _booting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<CrmDashboard>>(crmDashboardProvider, (_, next) => _bootstrapPrimary(next.valueOrNull));
    // The first build can already have data (provider kept alive by Home).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bootstrapPrimary(ref.read(crmDashboardProvider).valueOrNull);
    });

    // Every trade the engine confirms - opened, closed (also by SL / TP, or from another device), SL / TP
    // modified - gets its sound + vibration, once (a REST reply for the same trade is matched in
    // SoundService, so the two sources never feed back twice).
    ref.listen<TradeEvent?>(lastTradeEventProvider, (_, e) {
      if (e != null) SoundService.instance.onTradeEvent(e.kind);
    });

    // Activate live data on every tab.
    final sock = ref.watch(marketSocketProvider);
    ref.watch(quotesSeedProvider); // last-known prices so the watchlist is never blank
    ref.watch(feedSubscriptionProvider);
    final accounts = ref.watch(accountsProvider).valueOrNull;
    if (sock != null && accounts != null) {
      for (final a in accounts) {
        sock.watchAccount(a.id);
      }
    }

    // Home is always the signed-in user's own dashboard (built from the CRM, never
    // from the trading session), so it stays available even while Quotes / Chart /
    // Trade / History show another client's account read-only — its Trade button
    // switches back to the user's own account.
    const dest = PortalShell._dest;
    final loc = widget.state.matchedLocation;
    final index = loc.startsWith('/new-order')
        ? dest.indexWhere((d) => d.path == '/trade')
        : dest.indexWhere((d) => loc.startsWith(d.path)).clamp(0, dest.length - 1);
    void go(int i) => context.go(dest[i].path);

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
              for (final d in dest)
                NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: widget.child),
            ),
          ),
        ]),
      );
    }

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: go,
        destinations: [
          for (final d in dest) NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
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
