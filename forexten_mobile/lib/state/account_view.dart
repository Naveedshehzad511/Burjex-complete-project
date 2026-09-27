import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

final watchlistProvider = StateNotifierProvider<WatchlistNotifier, List<String>?>((ref) {
  ref.watch(activeAccountIdProvider);
  return WatchlistNotifier();
});

class WatchlistNotifier extends StateNotifier<List<String>?> {
  WatchlistNotifier() : super(null);

  void add(String symbol, List<String> all) {
    final base = state ?? List.of(all);
    if (base.contains(symbol)) return;
    state = [...base, symbol];
  }

  void remove(String symbol, List<String> all) {
    final base = state ?? List.of(all);
    state = base.where((s) => s != symbol).toList();
  }
}

final activeAccountProvider = Provider<Account?>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
  final id = ref.watch(activeAccountIdProvider);
  if (accounts.isEmpty) return null;
  final base = accounts.firstWhere((a) => a.id == id, orElse: () => accounts.first);
  return ref.watch(liveAccountProvider)[base.id] ?? base;
});

final clientSuffixProvider = Provider<String>((ref) {
  final a = ref.watch(activeAccountProvider);
  return a?.symbolSuffix ?? '';
});

String symbolDisplay(String canonical, String suffix) =>
    suffix.isEmpty ? canonical : '$canonical$suffix';
