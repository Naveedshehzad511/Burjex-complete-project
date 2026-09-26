import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

/// Resolves the active account merged with the latest live snapshot (if any).
final activeAccountProvider = Provider<Account?>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
  final id = ref.watch(activeAccountIdProvider);
  if (accounts.isEmpty) return null;
  final base = accounts.firstWhere((a) => a.id == id, orElse: () => accounts.first);
  final live = ref.watch(liveAccountProvider)[base.id];
  return live ?? base;
});

/// The active account's client symbol suffix (".s" / ".p" / ...), "" if none.
/// Display-only: append to a canonical symbol with [symbolDisplay].
final clientSuffixProvider = Provider<String>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
  final id = ref.watch(activeAccountIdProvider);
  if (accounts.isEmpty) return '';
  final base = accounts.firstWhere((a) => a.id == id, orElse: () => accounts.first);
  return base.symbolSuffix ?? '';
});

/// Append the active group's suffix to a canonical symbol name for display.
String symbolDisplay(String canonical, String suffix) => suffix.isEmpty ? canonical : '$canonical$suffix';

/// MT5-style account summary: Balance, Equity, Margin, Free Margin, Margin Level, P/L.
class AccountPanel extends ConsumerWidget {
  const AccountPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(activeAccountProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (a == null) return const SizedBox.shrink();

    // Prefer live quote-based P/L so the bar moves even if engine WS is quiet.
    final id = ref.watch(activeAccountIdProvider);
    final livePL = ref.watch(livePositionProvider);
    final quotes = ref.watch(quotesProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final open = ref.watch(openPositionsProvider).valueOrNull ?? const <Position>[];
    double floating = a.floatingPL;
    if (open.isNotEmpty) {
      floating = 0;
      for (final p in open.where((p) => id == null || p.accountId == id)) {
        floating += resolvePositionPl(p, livePl: livePL, quotes: quotes, symbols: symbols);
      }
    }
    final equity = a.balance + a.credit + floating;
    final freeMargin = equity - a.margin;
    final marginLevel = a.margin > 0 ? equity / a.margin * 100 : 0.0;
    final plColor = floating >= 0 ? tc.profit : tc.loss;

    Widget cell(String k, String v, {Color? color}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
            Text(v, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            cell('Balance', money(a.balance)),
            cell('Equity', money(equity)),
            cell('Floating P/L', money(floating), color: plColor),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            cell('Margin', money(a.margin)),
            cell('Free margin', money(freeMargin)),
            cell('Margin level', '${marginLevel.toStringAsFixed(0)}%'),
          ]),
        ]),
      ),
    );
  }
}
