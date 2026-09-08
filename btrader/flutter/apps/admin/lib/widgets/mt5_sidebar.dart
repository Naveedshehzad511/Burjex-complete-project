import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';

// ════════════════════════════════════════════════════════════════════════════
//  MARKET WATCH PANEL — live bid/ask, MT5 style (blue ≥ day-open, red < open).
// ════════════════════════════════════════════════════════════════════════════
class MarketWatchPanel extends ConsumerWidget {
  const MarketWatchPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(marketSocketProvider); // opens the WS + tick stream
    ref.watch(feedSubscriptionProvider); // subscribes the socket to all symbols
    final symbols = ref.watch(adminSymbolsProvider);
    final quotes = ref.watch(quotesProvider);
    final stats = ref.watch(dayStatsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final live = quotes.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _PanelHeader(
        icon: Icons.show_chart,
        title: 'Market Watch',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(live ? Icons.circle : Icons.circle_outlined, size: 8, color: live ? tc.profit : Colors.orange),
          const SizedBox(width: 4),
          Text(live ? 'LIVE' : 'FEED', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: live ? tc.profit : Colors.orange)),
        ]),
      ),
      _MwColumnHead(),
      Expanded(
        child: symbols.when(
          loading: () => const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          error: (e, _) => _hint(context, 'Symbols unavailable'),
          data: (list) => list.isEmpty
              ? _hint(context, 'No symbols enabled')
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: list.length,
                  itemBuilder: (_, i) => _MwRow(symbol: list[i], tick: quotes[list[i].symbol], stat: stats[list[i].symbol], zebra: i.isOdd, tc: tc),
                ),
        ),
      ),
    ]);
  }
}

class _MwColumnHead extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hintColor;
    TextStyle s() => TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.2, color: c);
    return Container(
      height: 24,
      color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF101826) : const Color(0xFFF4F7FC),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Expanded(flex: 4, child: Text('SYMBOL', style: s())),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('BID', style: s()))),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('ASK', style: s()))),
      ]),
    );
  }
}

class _MwRow extends StatelessWidget {
  const _MwRow({required this.symbol, required this.tick, required this.stat, required this.zebra, required this.tc});
  final TradeSymbol symbol;
  final Tick? tick;
  final DayStat? stat;
  final bool zebra;
  final TradeColors tc;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final faint = Theme.of(context).hintColor;
    final mid = tick == null ? null : (tick!.bid + tick!.ask) / 2;
    Color dir = Theme.of(context).colorScheme.onSurface;
    if (mid != null && stat != null) dir = mid >= stat!.open ? tc.up : tc.down;
    TextStyle num(Color c) => TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c, fontFeatures: const [FontFeature.tabularFigures()]);
    String px(double? v) => v == null ? '—' : price(v, symbol.digits);

    return Container(
      height: 30,
      color: zebra ? (isDark ? const Color(0x0AFFFFFF) : const Color(0x03000000)) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Expanded(flex: 4, child: Text(symbol.symbol, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(px(tick?.bid), style: num(tick == null ? faint : dir)))),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(px(tick?.ask), style: num(tick == null ? faint : dir)))),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  NAVIGATOR PANEL — MT5-style grouped tree of pages.
// ════════════════════════════════════════════════════════════════════════════
class _NavGroup {
  final String name;
  final List<_NavLeaf> items;
  const _NavGroup(this.name, this.items);
}

class _NavLeaf {
  final String path;
  final String label;
  final IconData icon;
  const _NavLeaf(this.path, this.label, this.icon);
}

const navGroups = [
  _NavGroup('Dashboard', [
    _NavLeaf('/', 'Overview', Icons.dashboard_outlined),
  ]),
  _NavGroup('Trading', [
    _NavLeaf('/trading', 'Trading', Icons.swap_vert),
    _NavLeaf('/accounts', 'Trading Accounts', Icons.account_balance_wallet_outlined),
    _NavLeaf('/demo-accounts', 'Demo Accounts', Icons.science_outlined),
    _NavLeaf('/dealing', 'Dealing (A / B)', Icons.account_tree_outlined),
    _NavLeaf('/liquidity', 'Liquidity', Icons.water_drop_outlined),
    _NavLeaf('/symbols', 'Symbols', Icons.candlestick_chart_outlined),
    _NavLeaf('/groups', 'Trading Groups', Icons.groups_outlined),
  ]),
  _NavGroup('Clients & Money', [
    _NavLeaf('/clients', 'Clients', Icons.people_outline),
    _NavLeaf('/financial', 'Financial', Icons.payments_outlined),
  ]),
  _NavGroup('Administration', [
    _NavLeaf('/risk', 'Risk', Icons.warning_amber_outlined),
    _NavLeaf('/audit', 'Audit', Icons.receipt_long_outlined),
    _NavLeaf('/tenants', 'Tenants', Icons.apartment_outlined),
    _NavLeaf('/hq', 'Companies (HQ)', Icons.public_outlined),
    _NavLeaf('/integrations', 'CRM / Integrations', Icons.cable_outlined),
  ]),
];

class NavigatorPanel extends StatelessWidget {
  const NavigatorPanel({super.key, required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _PanelHeader(icon: Icons.account_tree, title: 'Navigator'),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final g in navGroups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(g.name.toUpperCase(),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: Theme.of(context).hintColor)),
              ),
              for (final leaf in g.items) _NavRow(leaf: leaf, selected: currentPath == leaf.path),
            ],
          ],
        ),
      ),
    ]);
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.leaf, required this.selected});
  final _NavLeaf leaf;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final blue = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => context.go(leaf.path),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: selected ? blue.withValues(alpha: 0.10) : null,
          border: Border(left: BorderSide(color: selected ? blue : Colors.transparent, width: 3)),
        ),
        padding: const EdgeInsets.only(left: 13, right: 12),
        child: Row(children: [
          Icon(leaf.icon, size: 17, color: selected ? blue : Theme.of(context).hintColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(leaf.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? blue : Theme.of(context).colorScheme.onSurface)),
          ),
        ]),
      ),
    );
  }
}

// ── Shared panel header bar ──────────────────────────────────────────────────
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.icon, required this.title, this.trailing});
  final IconData icon;
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blue = Theme.of(context).colorScheme.primary;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0E1626) : const Color(0xFFEAF1FE),
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Icon(icon, size: 15, color: blue),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

Widget _hint(BuildContext context, String msg) =>
    Center(child: Text(msg, style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)));
