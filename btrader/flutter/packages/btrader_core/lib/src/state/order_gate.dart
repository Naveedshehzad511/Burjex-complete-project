import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/symbol.dart';
import 'live.dart';
import 'providers.dart';

/// The two refusal messages for a client order action. They are the same words the trading
/// engine answers with, so the app's own pre-check and a server refusal read identically.
const String kMarketClosedMessage = 'Market is closed';
const String kPriceUnavailableMessage = 'Live market price is unavailable';

/// Why a CLIENT order action on one symbol (a new order, SL / TP edit, pending-order edit or
/// cancel, a close) must not be sent right now - or null when it may be.
///
/// The same two questions the engine asks (`guard.rs`):
///  1. is the market open, from the symbol's admin-configured sessions ([isSymbolTradableNow]);
///  2. is the price live, i.e. its feed has not been silent for [kFeedGrace]. [hasQuote] false means
///     no price at all.
/// A closed market is reported as closed even when the price is also old.
///
/// This only saves a request that would be refused: the engine still decides, and refuses the same
/// action when it arrives from anywhere else. While the symbol list has not loaded, the market is
/// not judged closed (the engine will), so a slow load never blocks a valid action.
String? orderActionBlock({
  required TradeSymbol? spec,
  required bool hasQuote,
  required bool feedLive,
  DateTime? utcNow,
}) {
  if (spec != null && !isSymbolTradableNow(spec, (utcNow ?? DateTime.now()).toUtc())) {
    return kMarketClosedMessage;
  }
  if (!hasQuote || !feedLive) return kPriceUnavailableMessage;
  return null;
}

/// `ref.read` of a Ref or a WidgetRef, so one helper serves widgets and controllers alike.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// [orderActionBlock] for [symbol], read from the app's live state.
String? orderBlockFor(ProviderReader read, String symbol) {
  final symbols = read(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
  TradeSymbol? spec;
  for (final s in symbols) {
    if (s.symbol == symbol) {
      spec = s;
      break;
    }
  }
  // The app only stops what it is SURE of: a closed market (admin sessions), or a feed that was
  // live and has gone silent past [kFeedGrace]. A symbol the app holds no quote for (not
  // subscribed here, or the first tick not yet arrived) is left to the engine, which has the
  // real price and answers with the reason - so a valid action is never refused on a UI gap.
  return orderActionBlock(
    spec: spec,
    hasQuote: true,
    feedLive: read(symbolFeedLiveProvider(symbol)),
  );
}

/// The message inside an API error (the engine's own words, e.g. "Market is closed"), else [fallback].
String apiErrorMessage(Object e, {String fallback = 'Please try again'}) {
  try {
    final d = (e as dynamic).response?.data;
    if (d is Map) {
      final m = d['message'] ?? (d['error'] is Map ? d['error']['message'] : d['error']);
      if (m is String && m.trim().isNotEmpty) return m;
    }
  } catch (_) {/* fall through */}
  return fallback;
}
