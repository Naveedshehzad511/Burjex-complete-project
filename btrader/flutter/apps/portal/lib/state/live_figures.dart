import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/account_panel.dart' show activeAccountProvider;

/// The active account's money figures, derived ONE way for every screen: floating P/L is the sum of its open
/// positions' P/L (the engine's last push carried forward to the latest tick, see [resolvePositionPl]), equity is
/// balance + credit + that, free margin is equity - margin. The Trade tab, the account panel and Home all read this, so
/// they cannot disagree.
class LiveFigures {
  const LiveFigures({
    required this.accountId,
    required this.balance,
    required this.credit,
    required this.floating,
    required this.snapshotFloating,
    required this.margin,
  });

  final String accountId;
  final double balance, credit;

  /// Tick-level floating P/L (what the Trade tab shows).
  final double floating;

  /// The floating P/L in the engine's last account snapshot (what Home used to show).
  final double snapshotFloating;
  final double margin;

  double get equity => balance + credit + floating;
  double get freeMargin => equity - margin;

  // Compared in cents: a change smaller than what is displayed rebuilds nothing.
  static int _c(double v) => (v * 100).round();
  @override
  bool operator ==(Object o) =>
      o is LiveFigures &&
      o.accountId == accountId &&
      _c(o.balance) == _c(balance) &&
      _c(o.credit) == _c(credit) &&
      _c(o.floating) == _c(floating) &&
      _c(o.snapshotFloating) == _c(snapshotFloating) &&
      _c(o.margin) == _c(margin);
  @override
  int get hashCode => Object.hash(accountId, _c(balance), _c(credit), _c(floating), _c(snapshotFloating), _c(margin));
}

/// Null until an account is known. Only widgets that watch it rebuild, and only when a displayed cent changes.
final activeLiveFiguresProvider = Provider.autoDispose<LiveFigures?>((ref) {
  final a = ref.watch(activeAccountProvider);
  if (a == null) return null;
  final id = ref.watch(activeAccountIdProvider);
  final livePl = ref.watch(livePositionProvider);
  final snap = ref.watch(livePositionNotifierProvider);
  final quotes = ref.watch(quotesProvider);
  final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
  final open = ref.watch(accountPositionsProvider).valueOrNull ?? const <Position>[];
  var floating = a.floatingPL;
  if (open.isNotEmpty) {
    floating = 0;
    for (final p in open) {
      if (id == null || p.accountId.isEmpty || p.accountId == id) {
        floating += resolvePositionPl(p, livePl: livePl, quotes: quotes, symbols: symbols, snap: snap, accountCurrency: a.currency);
      }
    }
  }
  return LiveFigures(accountId: a.id, balance: a.balance, credit: a.credit, floating: floating, snapshotFloating: a.floatingPL, margin: a.margin);
});
