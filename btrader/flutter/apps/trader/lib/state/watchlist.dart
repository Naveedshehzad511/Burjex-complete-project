import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:btrader_core/btrader_core.dart';

/// Per-account Quotes watchlist (canonical symbol codes, in display order).
///
/// `null` means "not customized yet" → the UI shows **all symbols from the
/// account's trading group** (Symbol Mappings). Once the user adds or removes
/// a pair, it becomes an explicit, saved list for that account only — so a
/// Standard account never inherits a Pro watchlist.
class WatchlistNotifier extends StateNotifier<List<String>?> {
  WatchlistNotifier(this.accountId) : super(null) {
    _load();
  }

  final String? accountId;

  String get _key =>
      accountId == null || accountId!.isEmpty ? 'bt_watchlist' : 'bt_watchlist_$accountId';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = p.getStringList(_key);
  }

  Future<void> _persist(List<String> v) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, v);
  }

  void add(String symbol, List<String> all) {
    final base = state ?? List.of(all);
    if (base.contains(symbol)) return;
    final next = [...base, symbol];
    state = next;
    _persist(next);
  }

  void remove(String symbol, List<String> all) {
    final base = state ?? List.of(all);
    final next = base.where((s) => s != symbol).toList();
    state = next;
    _persist(next);
  }

  /// Ensure every group-assigned symbol appears at least once (auto universe).
  /// Does not remove user customizations of order/extras within the group.
  void ensureGroupSymbols(List<String> groupCodes) {
    if (groupCodes.isEmpty) return;
    if (state == null) {
      // Uncustomized → UI already shows allCodes; nothing to persist.
      return;
    }
    final missing = groupCodes.where((c) => !state!.contains(c)).toList();
    if (missing.isEmpty) return;
    final next = [...state!, ...missing];
    state = next;
    _persist(next);
  }
}

final watchlistProvider =
    StateNotifierProvider<WatchlistNotifier, List<String>?>((ref) {
  final accountId = ref.watch(activeAccountIdProvider);
  return WatchlistNotifier(accountId);
});
