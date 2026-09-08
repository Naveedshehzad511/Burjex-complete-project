import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/charts_screen.dart';
import 'screens/trade_screen.dart';

/// Optional host bridge when BTrader screens are embedded outside GoRouter
/// (e.g. CRM MainShell). Standalone trader app leaves this null and uses routes.
class BTraderEmbedNav extends InheritedWidget {
  const BTraderEmbedNav({
    super.key,
    required this.openChart,
    required this.openTrade,
    required super.child,
  });

  final void Function(String symbol) openChart;
  final void Function(String symbol) openTrade;

  static BTraderEmbedNav? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BTraderEmbedNav>();

  @override
  bool updateShouldNotify(BTraderEmbedNav old) =>
      openChart != old.openChart || openTrade != old.openTrade;
}

/// Routing helper: prefers GoRouter (standalone), then embed bridge, then push.
class TraderNav {
  static void openTrade(BuildContext context, String symbol) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/trade?symbol=${Uri.encodeComponent(symbol)}');
      return;
    }
    final embed = BTraderEmbedNav.maybeOf(context);
    if (embed != null) {
      embed.openTrade(symbol);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TradeScreen(symbol: symbol)),
    );
  }

  static void openChart(BuildContext context, String symbol) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/charts?symbol=${Uri.encodeComponent(symbol)}');
      return;
    }
    final embed = BTraderEmbedNav.maybeOf(context);
    if (embed != null) {
      embed.openChart(symbol);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChartsScreen(symbol: symbol)),
    );
  }

  static void openCharts(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/charts');
      return;
    }
    final embed = BTraderEmbedNav.maybeOf(context);
    if (embed != null) {
      embed.openChart('');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChartsScreen()),
    );
  }
}
