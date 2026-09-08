import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

/// Admin data providers — all tenant-scoped by the gateway via the JWT.

/// Drives live auto-refresh of the changing dashboard numbers (equity, floating
/// P/L, exposure, alerts) so they update without a manual refresh. Riverpod
/// keeps the previous value during each reload, so the UI never blanks.
final adminLiveTicker = StreamProvider.autoDispose<int>(
  (ref) => Stream<int>.periodic(const Duration(seconds: 2), (i) => i + 1),
);

final clientsProvider = FutureProvider.autoDispose<List<Client>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (equity / floating P/L / margin)
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/accounts/clients') as List;
  return data.map((e) => Client.fromJson(e)).toList();
});

/// Subscribes the admin's WebSocket to every client account so the engine's
/// live ACCOUNT_UPDATE frames (equity / floating P/L, pushed ~2×/sec) stream in
/// for instant, tick-driven dashboard numbers — no polling.
final adminAccountWatchProvider = Provider.autoDispose<void>((ref) {
  final sock = ref.watch(marketSocketProvider);
  final clients = ref.watch(clientsProvider).valueOrNull;
  if (sock == null || clients == null) return;
  for (final c in clients) {
    for (final a in c.accounts) {
      sock.watchAccount(a.id);
    }
  }
});

final allPositionsProvider = FutureProvider.autoDispose<List<Position>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (per-position P/L)
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/accounts/positions/all') as List;
  return data.map((e) => Position.fromJson(e)).toList();
});

final exposureProvider = FutureProvider.autoDispose<Map<String, double>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (net exposure)
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/accounts/exposure/net') as List;
  final net = <String, double>{};
  for (final e in data) {
    // Backend now returns the human symbol name; fall back to symbolId for
    // older responses so the chip never breaks.
    final sym = (e['symbol'] ?? e['symbolId'] ?? '').toString();
    final vol = double.tryParse('${e['_sum']?['volume'] ?? 0}') ?? 0;
    net[sym] = (net[sym] ?? 0) + (e['side'] == 'BUY' ? vol : -vol);
  }
  return net;
});

final adminSymbolsProvider = FutureProvider.autoDispose<List<TradeSymbol>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/symbols') as List;
  return data.map((e) => TradeSymbol.fromJson(e)).toList();
});

final riskLimitsProvider = FutureProvider.autoDispose<List<RiskLimit>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/risk/limits') as List;
  return data.map((e) => RiskLimit.fromJson(e)).toList();
});

final marginAlertsProvider = FutureProvider.autoDispose<List<MarginAlert>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (margin-call watch)
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/risk/margin-alerts') as List;
  return data.map((e) => MarginAlert.fromJson(e)).toList();
});

final auditProvider = FutureProvider.autoDispose.family<List<AuditEntry>, String>((ref, action) async {
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/audit', query: action.isEmpty ? null : {'action': action}) as List;
  return data.map((e) => AuditEntry.fromJson(e)).toList();
});

final tenantsProvider = FutureProvider.autoDispose<List<Tenant>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/tenants') as List;
  return data.map((e) => Tenant.fromJson(e)).toList();
});

// ── Dealing desk / A-B book management ──────────────────────────────────────

/// Net warehouse (B-book) exposure + A-book coverage summary.
final bookExposureProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (warehouse exposure / house P/L)
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/exposure') as Map<String, dynamic>;
});

/// A-book cover (hedge) order blotter.
final hedgeBlotterProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh (cover order status)
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/hedges') as List;
});

/// LP execution bridge config for this tenant (back-compat single-venue view).
final lpConfigProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/lp-config') as Map<String, dynamic>;
});

/// All A-book LP venues (one per driver) for multi-venue routing.
final lpVenuesProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/lp-venues') as List;
});

/// Routing rules (Group × Symbol/Class → book + LP venue), most-specific first.
final routingRulesProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/routing-rules') as List;
});

/// Trading groups (id + name) for the routing-rule scope pickers.
final tradingGroupsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/groups') as List;
});

/// Per-symbol news-mode state (widen spread + pause new opens).
final newsModeProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  ref.watch(adminLiveTicker); // reflect toggles promptly
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/book/news') as List;
});

/// Liquidity providers (multi-source feed) for this tenant.
final liquidityProvidersProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/liquidity') as List;
});

/// Live per-provider quotes + spreads per symbol (auto-refreshing).
final liquidityMonitorProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  ref.watch(adminLiveTicker); // live refresh of the spread comparison
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/liquidity/monitor') as Map<String, dynamic>;
});

/// Tenant client-pricing policy (PRIMARY vs BEST_SPREAD + hysteresis margin).
final liquidityPricingProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/liquidity/pricing') as Map<String, dynamic>;
});

/// Explicit symbol mappings for one provider (feed name → B-Trader symbol).
final liquiditySymbolMapsProvider =
    FutureProvider.autoDispose.family<List<dynamic>, String>((ref, providerId) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/liquidity/$providerId/symbol-maps') as List;
});

/// Feed symbols seen recently that matched no B-Trader symbol (mapping helper).
final liquidityUnmappedProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  ref.watch(adminLiveTicker);
  final api = ref.watch(apiClientProvider);
  return await api.get('/admin/liquidity/unmapped') as List;
});
