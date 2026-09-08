import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../nav.dart';
import '../state/watchlist.dart';
import '../widgets/big_figure_price.dart';

/// MT5-style Quotes watchlist. Pure quotes — add/remove pairs with +/swipe, and
/// tap a pair for the New Order / Chart / Properties menu (no page navigation).
class MarketsScreen extends ConsumerStatefulWidget {
  const MarketsScreen({super.key});

  @override
  ConsumerState<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends ConsumerState<MarketsScreen> {
  /// Survives auth/account refreshes so Quotes never cold-spins after first load.
  List<TradeSymbol>? _lastSymbols;

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    final symbols = ref.watch(symbolsProvider);
    final mode = ref.watch(themeModeProvider);

    // Never full-screen "search"/reload on tab open — paint last symbols while
    // a background refetch runs; spinner only on the true first cold load.
    final fresh = symbols.valueOrNull;
    if (fresh != null) _lastSymbols = fresh;
    final list = fresh ?? _lastSymbols;
    if (symbols.hasError && list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quotes')),
        body: Center(child: Text('Failed to load symbols\n${symbols.error}', textAlign: TextAlign.center)),
      );
    }
    if (list == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Quotes'),
          actions: [
            IconButton(
              tooltip: 'Toggle theme',
              icon: Icon(mode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
            ),
          ],
        ),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final byCode = {for (final s in list) s.symbol: s};
    final allCodes = list.map((s) => s.symbol).toList();
    // Auto-universe: group Symbol Mappings appear without manual "Add symbols".
    ref.listen<AsyncValue<List<TradeSymbol>>>(symbolsProvider, (prev, next) {
      final codes = next.valueOrNull?.map((s) => s.symbol).toList();
      if (codes != null && codes.isNotEmpty) {
        ref.read(watchlistProvider.notifier).ensureGroupSymbols(codes);
      }
    });
    // Default watchlist = this account group's symbols only (not the full book).
    final watch = ref.watch(watchlistProvider) ?? allCodes;
    final shown = watch.where(byCode.containsKey).toList();
    // Drop stale watchlist entries from other account types/groups.
    final filteredWatch = shown.isEmpty && allCodes.isNotEmpty ? allCodes : shown;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quotes'),
        actions: [
          IconButton(
            tooltip: 'Add symbols',
            icon: const Icon(Icons.add),
            onPressed: () => _manageSheet(context, ref, list, filteredWatch, allCodes),
          ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(mode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: filteredWatch.isEmpty
          ? _Empty(onAdd: () => _manageSheet(context, ref, list, filteredWatch, allCodes))
          : ListView.separated(
              itemCount: filteredWatch.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              // Per-row select: apply each tick immediately without rebuilding
              // the entire Quotes list on every symbol update.
              itemBuilder: (_, i) {
                final s = byCode[filteredWatch[i]]!;
                return Dismissible(
                  key: ValueKey(s.symbol),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: const Color(0xFFE5484D),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  onDismissed: (_) => ref.read(watchlistProvider.notifier).remove(s.symbol, allCodes),
                  child: Consumer(
                    builder: (context, ref, _) {
                      final raw = ref.watch(quotesProvider.select((m) => m[s.symbol]));
                      final stat = ref.watch(dayStatsProvider.select((m) => m[s.symbol]));
                      final tick = raw == null ? null : s.applyGroupMarkup(raw);
                      return _QuoteRow(
                        symbol: s,
                        display: s.displaySymbol,
                        tick: tick,
                        stat: stat,
                        onTap: () => _quoteMenu(context, ref, s, allCodes),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }

  // ── Tap menu: New Order / Chart / Properties / Remove ───────────────────────
  void _quoteMenu(BuildContext context, WidgetRef ref, TradeSymbol s, List<String> allCodes) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(s.displaySymbol, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(s.description ?? s.klass),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_chart_rounded),
            title: const Text('New Order'),
            onTap: () {
              Navigator.pop(ctx);
              TraderNav.openTrade(context, s.symbol);
            },
          ),
          ListTile(
            leading: const Icon(Icons.candlestick_chart_rounded),
            title: const Text('Chart'),
            onTap: () {
              Navigator.pop(ctx);
              TraderNav.openChart(context, s.symbol);
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Properties'),
            onTap: () {
              Navigator.pop(ctx);
              _properties(context, s);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFE5484D)),
            title: const Text('Remove from Quotes', style: TextStyle(color: Color(0xFFE5484D))),
            onTap: () {
              Navigator.pop(ctx);
              ref.read(watchlistProvider.notifier).remove(s.symbol, allCodes);
            },
          ),
        ]),
      ),
    );
  }

  void _properties(BuildContext context, TradeSymbol s) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: TextStyle(color: Theme.of(context).hintColor)),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w500)),
          ]),
        );
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${s.displaySymbol} — Properties'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          row('Description', s.description ?? '—'),
          row('Class', s.klass),
          row('Digits', '${s.digits}'),
          row('Client symbol', s.displaySymbol),
          row('Pricing', s.pricingMethod ?? 'group default'),
          if (s.minSpreadPoints > 0 || s.maxSpreadPoints > 0)
            row('Spread band', '${s.minSpreadPoints}–${s.maxSpreadPoints == 0 ? '∞' : s.maxSpreadPoints} pts')
          else
            row('Group markup', '${s.markupPoints} pts'),
          row('Min lot', '${s.minLot}'),
          row('Max lot', '${s.maxLot}'),
          row('Lot step', '${s.lotStep}'),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  // ── Add/remove symbols sheet ────────────────────────────────────────────────
  void _manageSheet(
    BuildContext context,
    WidgetRef ref,
    List<TradeSymbol> all,
    List<String> watch,
    List<String> allCodes,
  ) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => Consumer(
          builder: (context, ref, __) {
            final current = ref.watch(watchlistProvider) ?? allCodes;
            return Column(children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Symbols', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: all.length,
                  itemBuilder: (_, i) {
                    final s = all[i];
                    final inList = current.contains(s.symbol);
                    return ListTile(
                      title: Text(s.displaySymbol),
                      subtitle: Text(s.description ?? s.klass, style: const TextStyle(fontSize: 11)),
                      trailing: Icon(
                        inList ? Icons.check_circle : Icons.add_circle_outline,
                        color: inList ? const Color(0xFF0BB07B) : Theme.of(context).hintColor,
                      ),
                      onTap: () {
                        final n = ref.read(watchlistProvider.notifier);
                        if (inList) {
                          n.remove(s.symbol, allCodes);
                        } else {
                          n.add(s.symbol, allCodes);
                        }
                      },
                    );
                  },
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('No pairs in your watchlist', style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add symbols')),
        ]),
      );
}

class _QuoteRow extends StatelessWidget {
  const _QuoteRow({required this.symbol, required this.display, required this.tick, required this.stat, required this.onTap});
  final TradeSymbol symbol;
  final String display;
  final Tick? tick;
  final DayStat? stat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final faint = Theme.of(context).hintColor;
    final digits = symbol.digits;
    final point = math.pow(10, -digits).toDouble();

    final mid = tick == null ? null : (tick!.bid + tick!.ask) / 2;
    Color dir = Theme.of(context).colorScheme.onSurface;
    if (mid != null && stat != null) dir = mid >= stat!.open ? tc.up : tc.down;

    final changePct = (mid != null && stat != null) ? stat!.changePct(mid) : 0.0;
    final spread = tick == null ? 0 : ((tick!.ask - tick!.bid) / point).round();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tick == null ? '' : pct(changePct),
                  style: TextStyle(fontSize: 11, color: changePct >= 0 ? tc.up : tc.down, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(display, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Row(children: [
                Text(tick == null ? symbol.description ?? '' : hms(DateTime.fromMillisecondsSinceEpoch(tick!.ts)),
                    style: TextStyle(fontSize: 11, color: faint)),
                if (tick != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.hourglass_empty, size: 11, color: faint),
                  const SizedBox(width: 2),
                  Text('$spread', style: TextStyle(fontSize: 11, color: faint)),
                ],
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Row(children: [
              tick == null ? Text('—', style: TextStyle(color: faint)) : BigFigurePrice(value: tick!.bid, digits: digits, color: dir),
              const SizedBox(width: 18),
              tick == null ? Text('—', style: TextStyle(color: faint)) : BigFigurePrice(value: tick!.ask, digits: digits, color: dir),
            ]),
            const SizedBox(height: 6),
            Text(stat == null ? '' : 'L: ${price(stat!.low, digits)}   H: ${price(stat!.high, digits)}',
                style: TextStyle(fontSize: 11, color: faint, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ]),
      ),
    );
  }
}
