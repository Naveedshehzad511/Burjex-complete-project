import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'widgets/mt5_sidebar.dart';

const _items = [
  (path: '/', label: 'Overview', icon: Icons.dashboard_outlined),
  (path: '/market', label: 'Market Watch', icon: Icons.show_chart),
  (path: '/clients', label: 'Clients', icon: Icons.people_outline),
  (path: '/trading', label: 'Trading', icon: Icons.swap_vert),
  (path: '/accounts', label: 'Trading Accounts', icon: Icons.account_balance_wallet_outlined),
  (path: '/demo-accounts', label: 'Demo Accounts', icon: Icons.science_outlined),
  (path: '/dealing', label: 'Dealing (A/B)', icon: Icons.account_tree_outlined),
  (path: '/liquidity', label: 'Liquidity', icon: Icons.water_drop_outlined),
  (path: '/symbols', label: 'Symbols', icon: Icons.candlestick_chart_outlined),
  (path: '/groups', label: 'Trading Groups', icon: Icons.groups_outlined),
  (path: '/financial', label: 'Financial', icon: Icons.payments_outlined),
  (path: '/risk', label: 'Risk', icon: Icons.warning_amber_outlined),
  (path: '/audit', label: 'Audit', icon: Icons.receipt_long_outlined),
  (path: '/tenants', label: 'Tenants', icon: Icons.apartment_outlined),
  (path: '/hq', label: 'Companies (HQ)', icon: Icons.public_outlined),
  (path: '/integrations', label: 'CRM / Integrations', icon: Icons.cable_outlined),
];

/// Responsive admin shell. Desktop/tablet → persistent NavigationRail. Mobile →
/// an AppBar with a hamburger Drawer. Theme toggle + sign-out live in both.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key, required this.state, required this.child});
  final GoRouterState state;
  final Widget child;

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  // Resizable side-panel widths (persist for the session).
  double _navWidth = 230;
  double _mwWidth = 300;

  GoRouterState get state => widget.state;
  Widget get child => widget.child;

  int get _index {
    final loc = state.matchedLocation;
    final i = _items.indexWhere((x) => x.path == loc);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final mode = ref.watch(themeModeProvider);
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;

    void toggleTheme() => ref.read(themeModeProvider.notifier).set(
          mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light,
        );
    void logout() => ref.read(authControllerProvider.notifier).logout();

    if (context.isMobile) {
      return Scaffold(
        appBar: AppBar(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            BrandLogo(branding: brand, size: 22),
            const SizedBox(width: 8),
            Text(_items[_index].label),
          ]),
          actions: [
            IconButton(onPressed: toggleTheme, icon: const Icon(Icons.brightness_6_outlined)),
            IconButton(onPressed: logout, icon: const Icon(Icons.logout)),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: ListView(children: [
              for (var i = 0; i < _items.length; i++)
                ListTile(
                  leading: Icon(_items[i].icon),
                  title: Text(_items[i].label),
                  selected: i == _index,
                  onTap: () {
                    Navigator.pop(context);
                    context.go(_items[i].path);
                  },
                ),
            ]),
          ),
        ),
        body: child,
      );
    }

    final divColor = Theme.of(context).dividerColor;
    Widget brandHeader() => Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: divColor))),
          child: Row(children: [
            BrandLogo(branding: brand, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Text(brand.appName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: -0.2)),
            ),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Toggle theme', icon: const Icon(Icons.brightness_6_outlined, size: 18), onPressed: toggleTheme),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Sign out', icon: const Icon(Icons.logout, size: 18), onPressed: logout),
          ]),
        );

    return Scaffold(
      // Three-pane layout: Navigator (left, resizable) | content (middle) |
      // Market Watch (right, resizable). Drag the dividers to resize each pane.
      body: Row(children: [
        // ── LEFT: Navigator ──
        SizedBox(
          width: _navWidth,
          child: Column(children: [
            brandHeader(),
            Expanded(child: NavigatorPanel(currentPath: state.matchedLocation)),
          ]),
        ),
        _ResizeHandle(onDrag: (dx) => setState(() => _navWidth = (_navWidth + dx).clamp(170.0, 380.0))),
        // ── MIDDLE: active page ──
        Expanded(child: child),
        _ResizeHandle(onDrag: (dx) => setState(() => _mwWidth = (_mwWidth - dx).clamp(220.0, 520.0))),
        // ── RIGHT: Market Watch ──
        SizedBox(width: _mwWidth, child: const MarketWatchPanel()),
      ]),
    );
  }
}

/// Thin draggable divider that resizes the pane next to it (horizontal drag).
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag});
  final void Function(double dx) onDrag;
  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).dividerColor;
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(width: _hover ? 2 : 1, color: _hover ? accent : base),
          ),
        ),
      ),
    );
  }
}

/// Shared page scaffold for admin content pages.
class AdminPage extends StatelessWidget {
  const AdminPage({super.key, required this.title, required this.child, this.actions});
  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 560;
      final pad = narrow ? 14.0 : 24.0;
      final titleWidget = Text(
        title,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: narrow ? 20 : 22, fontWeight: FontWeight.w500),
      );
      final hasActions = actions != null && actions!.isNotEmpty;

      Widget header;
      if (!hasActions) {
        header = titleWidget;
      } else if (narrow) {
        // Stack title above a wrapping action row so nothing gets squeezed.
        header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleWidget,
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: actions!),
        ]);
      } else {
        header = Row(children: [Expanded(child: titleWidget), ...actions!]);
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: EdgeInsets.fromLTRB(pad, narrow ? 16 : 24, pad, 8), child: header),
        Expanded(child: Padding(padding: EdgeInsets.fromLTRB(pad, 8, pad, narrow ? 14 : 24), child: child)),
      ]);
    });
  }
}
