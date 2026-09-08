import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

/// MT5-style Market Watch: a live bid/ask grid streamed over the WebSocket.
/// Prices are blue when at/above the day open, red when below (MT5 convention).
class MarketWatchScreen extends ConsumerWidget {
  const MarketWatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Touching the socket provider opens the WS and starts the tick stream.
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    final symbols = ref.watch(adminSymbolsProvider);
    final quotes = ref.watch(quotesProvider);
    final stats = ref.watch(dayStatsProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerBg = isDark ? const Color(0xFF131C2E) : const Color(0xFFEDF1F7);
    final line = Theme.of(context).dividerColor;

    final live = quotes.isNotEmpty;

    return AdminPage(
      title: 'Market Watch',
      actions: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: (live ? tc.profit : Colors.orange).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(live ? Icons.circle : Icons.circle_outlined, size: 9, color: live ? tc.profit : Colors.orange),
            const SizedBox(width: 6),
            Text(live ? 'LIVE' : 'WAITING FEED',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: live ? tc.profit : Colors.orange)),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Refresh symbols',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: () => ref.invalidate(adminSymbolsProvider),
        ),
      ],
      child: symbols.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load symbols: $e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(child: Text('No symbols enabled.', style: TextStyle(color: Theme.of(context).hintColor)));
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!live)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Waiting for the price feed. Quotes stream in as soon as the market-data bridge pushes ticks.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final compact = c.maxWidth < 560; // phones: drop spread/high/low
                return Container(
                  decoration: BoxDecoration(border: Border.all(color: line), borderRadius: BorderRadius.circular(8)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    _HeaderRow(bg: headerBg, color: Theme.of(context).hintColor, compact: compact),
                    Expanded(
                      child: ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => Divider(height: 0.5, thickness: 0.5, color: line),
                        itemBuilder: (_, i) => _QuoteRow(
                          symbol: list[i],
                          tick: quotes[list[i].symbol],
                          stat: stats[list[i].symbol],
                          zebra: i.isOdd,
                          tc: tc,
                          compact: compact,
                        ),
                      ),
                    ),
                  ]),
                );
              }),
            ),
          ]);
        },
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.bg, required this.color, this.compact = false});
  final Color bg;
  final Color color;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    TextStyle h() => TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: color);
    Widget cell(String t, int flex, {Alignment a = Alignment.centerLeft}) =>
        Expanded(flex: flex, child: Align(alignment: a, child: Text(t, maxLines: 1, overflow: TextOverflow.clip, style: h())));
    return Container(
      height: 34,
      color: bg,
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
      child: Row(children: compact
          ? [
              cell('SYMBOL', 4),
              cell('BID', 4, a: Alignment.centerRight),
              cell('ASK', 4, a: Alignment.centerRight),
              cell('CHG', 3, a: Alignment.centerRight),
            ]
          : [
              cell('SYMBOL', 3),
              cell('BID', 3, a: Alignment.centerRight),
              cell('ASK', 3, a: Alignment.centerRight),
              cell('SPREAD', 2, a: Alignment.centerRight),
              cell('CHANGE', 2, a: Alignment.centerRight),
              cell('HIGH', 3, a: Alignment.centerRight),
              cell('LOW', 3, a: Alignment.centerRight),
            ]),
    );
  }
}

class _QuoteRow extends StatelessWidget {
  const _QuoteRow({required this.symbol, required this.tick, required this.stat, required this.zebra, required this.tc, this.compact = false});
  final TradeSymbol symbol;
  final Tick? tick;
  final DayStat? stat;
  final bool zebra;
  final TradeColors tc;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final faint = Theme.of(context).hintColor;
    final digits = symbol.digits;
    final point = math.pow(10, -digits).toDouble();

    final mid = tick == null ? null : (tick!.bid + tick!.ask) / 2;
    Color dir = Theme.of(context).colorScheme.onSurface;
    if (mid != null && stat != null) dir = mid >= stat!.open ? tc.up : tc.down;
    final changePct = (mid != null && stat != null) ? stat!.changePct(mid) : 0.0;
    final spread = tick == null ? null : ((tick!.ask - tick!.bid) / point).round();

    TextStyle num(Color c, {FontWeight w = FontWeight.w600}) =>
        TextStyle(fontSize: compact ? 12.5 : 13, fontWeight: w, color: c, fontFeatures: const [FontFeature.tabularFigures()]);
    Widget cell(Widget w, int flex, {Alignment a = Alignment.centerLeft}) =>
        Expanded(flex: flex, child: Align(alignment: a, child: w));
    String px(double? v) => v == null ? '—' : price(v, digits);
    final symCell = cell(Text(symbol.symbol, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: compact ? 12.5 : 13)), 4);
    final bidCell = cell(Text(px(tick?.bid), maxLines: 1, style: num(tick == null ? faint : dir)), 4, a: Alignment.centerRight);
    final askCell = cell(Text(px(tick?.ask), maxLines: 1, style: num(tick == null ? faint : dir)), 4, a: Alignment.centerRight);
    final chgCell = cell(Text(tick == null ? '—' : pct(changePct), maxLines: 1, style: num(changePct >= 0 ? tc.up : tc.down, w: FontWeight.w600)), 3, a: Alignment.centerRight);

    return Container(
      height: 38,
      color: zebra ? (isDark ? const Color(0x0AFFFFFF) : const Color(0x04000000)) : null,
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
      child: Row(children: compact
          ? [symCell, bidCell, askCell, chgCell]
          : [
              cell(Text(symbol.symbol, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), 3),
              cell(Text(px(tick?.bid), style: num(tick == null ? faint : dir)), 3, a: Alignment.centerRight),
              cell(Text(px(tick?.ask), style: num(tick == null ? faint : dir)), 3, a: Alignment.centerRight),
              cell(Text(spread == null ? '—' : '$spread', style: num(faint, w: FontWeight.w500)), 2, a: Alignment.centerRight),
              cell(Text(tick == null ? '—' : pct(changePct), style: num(changePct >= 0 ? tc.up : tc.down, w: FontWeight.w600)), 2, a: Alignment.centerRight),
              cell(Text(stat == null ? '—' : price(stat!.high, digits), style: num(faint, w: FontWeight.w500)), 3, a: Alignment.centerRight),
              cell(Text(stat == null ? '—' : price(stat!.low, digits), style: num(faint, w: FontWeight.w500)), 3, a: Alignment.centerRight),
            ]),
    );
  }
}
