import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crm/crm.dart';
import '../session/sessions.dart';
import '../state/movers.dart';
import 'portal_ui.dart';

/// Which carousel.
enum MoversSide { gainers, losers }

String _categoryLabel(String c) {
  switch (c) {
    case 'COMMODITIES':
      return 'Commodities';
    case 'CRYPTO':
      return 'Crypto';
    case 'INDICES':
      return 'Indices';
    case 'STOCKS':
      return 'Stocks';
    default:
      return c;
  }
}

/// "Top Gainers" / "Top Losers" on Home: a horizontally swipeable row of up to five cards (the strongest mover of
/// each of Commodities, Crypto, Indices and Stocks, then the next strongest). It loads on its own, apart from the
/// rest of the screen, and says so when it is loading, stale, empty or cannot be reached.
class MoversSection extends ConsumerWidget {
  const MoversSection({super.key, required this.side});
  final MoversSide side;

  bool get _gainers => side == MoversSide.gainers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A client with no trading account has no instruments to rank: nothing to show (never a spinner that never ends).
    final hasAccounts = ref.watch(crmDashboardProvider.select((d) => d.valueOrNull?.accounts.isNotEmpty ?? true));
    if (!hasAccounts) return const SizedBox.shrink();
    final state = ref.watch(moversProvider);
    final sessionError = ref.watch(tradingSessionProvider.select((s) => s.error));
    final hint = Theme.of(context).hintColor;

    final data = state.data;
    final cards = data == null ? const <Mover>[] : (_gainers ? data.gainers : data.losers);

    Widget body;
    if (data == null && (state.failed || sessionError != null)) {
      body = InfoCard(
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: hint),
          const SizedBox(width: 10),
          Expanded(child: Text('Market movers are unavailable right now.', style: TextStyle(color: hint, fontSize: 13.5))),
          TextButton(onPressed: () => ref.read(moversProvider.notifier).refresh(), child: const Text('Retry')),
        ]),
      );
    } else if (data == null) {
      body = const _SkeletonRow();
    } else if (cards.isEmpty) {
      body = InfoCard(
        child: Text(_gainers ? 'No gainers yet today.' : 'No losers yet today.', style: TextStyle(color: hint, fontSize: 13.5)),
      );
    } else {
      body = _CardsRow(cards: cards, gainers: _gainers);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 22),
      Row(children: [
        Expanded(child: Text(_gainers ? 'Top Gainers' : 'Top Losers', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
        if (state.stale && data != null) _StaleNote(asOf: data.asOf),
      ]),
      const SizedBox(height: 12),
      body,
    ]);
  }
}

/// "Updated 14:32" while the latest refresh has failed: the cards on screen are the last good ones.
class _StaleNote extends StatelessWidget {
  const _StaleNote({required this.asOf});
  final DateTime asOf;
  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.fromDateTime(asOf.toLocal());
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.history, size: 15, color: Color(0xFFB7791F)),
      const SizedBox(width: 4),
      Text('Updated $hh:$mm', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
    ]);
  }
}

/// The cards, side by side, scrolling sideways. The card width follows the screen width, the height follows the content.
class _CardsRow extends StatelessWidget {
  const _CardsRow({required this.cards, required this.gainers});
  final List<Mover> cards;
  final bool gainers;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = (box.maxWidth * 0.46).clamp(132.0, 240.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final m in cards)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(width: w, child: _MoverCard(mover: m)),
                ),
            ]),
          ),
        );
      });
}

class _MoverCard extends StatelessWidget {
  const _MoverCard({required this.mover});
  final Mover mover;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final up = mover.changePct >= 0;
    final color = up ? tc.profit : tc.loss;
    final hint = Theme.of(context).hintColor;
    final pct = '${up ? '+' : ''}${mover.changePct.toStringAsFixed(2)}%';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: hint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(_categoryLabel(mover.category), maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: hint)),
        ),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(mover.symbol, maxLines: 1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 2),
        Text(mover.name.isEmpty ? ' ' : mover.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: hint)),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(mover.price.toStringAsFixed(mover.digits), maxLines: 1, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        // Shrinks rather than overflows on a narrow screen or a large text size.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(up ? Icons.trending_up : Icons.trending_down, size: 15, color: color),
              const SizedBox(width: 4),
              Text(pct, maxLines: 1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Placeholder cards while the first answer is on its way (the rest of Home is already usable).
class _SkeletonRow extends StatefulWidget {
  const _SkeletonRow();
  @override
  State<_SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<_SkeletonRow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth * 0.46).clamp(132.0, 240.0);
      return AnimatedBuilder(
        animation: _c,
        builder: (_, __) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: w,
                height: 138,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(color: base.withValues(alpha: 0.05 + 0.06 * _c.value), borderRadius: BorderRadius.circular(16)),
              ),
          ]),
        ),
      );
    });
  }
}
