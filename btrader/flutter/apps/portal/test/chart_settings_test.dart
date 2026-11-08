import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/chart_settings_screen.dart';
import 'package:burjex_portal/state/chart_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: ChartSettingsScreen()),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows all settings, scrolls, line type has exactly three options', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pump();

    expect(find.text('Line type'), findsOneWidget);
    expect(find.text('Candlestick'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cs-line-type')));
    await tester.pumpAndSettle();
    expect(find.text('Bar chart'), findsOneWidget);
    expect(find.text('Line chart'), findsOneWidget);
    expect(find.text('Heikin Ashi'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cs-option-Line chart')));
    await tester.pumpAndSettle();
    expect(c.read(chartSettingsProvider).lineType, ChartLineType.line);
    expect(find.text('Line chart'), findsOneWidget); // subtitle

    for (final k in [
      'cs-trade-positions', 'cs-trade-orders', 'cs-trade-history', 'cs-profit-loss', 'cs-sl-tp',
      'cs-period-separators', 'cs-panel-bottom', 'cs-free-movement', 'cs-colors',
    ]) {
      await tester.scrollUntilVisible(find.byKey(ValueKey(k)), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
  });

  testWidgets('checkbox toggles and persists across a restart', (tester) async {
    var c = ProviderContainer();
    await tester.pumpWidget(_app(c));
    await tester.pump();
    expect(c.read(chartSettingsProvider).tradeHistory, false);
    await tester.tap(find.byKey(const ValueKey('cs-trade-history')));
    await tester.pump();
    expect(c.read(chartSettingsProvider).tradeHistory, true);
    c.read(chartSettingsProvider.notifier).setLineType(ChartLineType.bar);
    c.read(chartSettingsProvider.notifier).setFreeChartMovement(true);
    await tester.pump();
    c.dispose();

    c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(chartSettingsProvider);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final s = c.read(chartSettingsProvider);
    expect(s.tradeHistory, true);
    expect(s.lineType, ChartLineType.bar);
    expect(s.freeChartMovement, true);
    expect(s.tradeOrders, true); // untouched default
  });

  testWidgets('Trading panel at the bottom is a plain checkbox (off by default) and there is no One Click Trading row', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pump();
    expect(find.text('One Click Trading'), findsNothing);
    final tile = find.byKey(const ValueKey('cs-panel-bottom'));
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(find.text('Trading panel at the bottom'), findsOneWidget);
    expect(c.read(chartSettingsProvider).tradingPanelAtBottom, isFalse);
    await tester.tap(tile);
    await tester.pump();
    expect(c.read(chartSettingsProvider).tradingPanelAtBottom, isTrue);
    expect(find.byType(AlertDialog), findsNothing, reason: 'no warning, no extra steps');
    await tester.tap(tile);
    await tester.pump();
    expect(c.read(chartSettingsProvider).tradingPanelAtBottom, isFalse);
    await tester.tap(tile);
    await tester.pump();

    // The choice survives a restart.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(chartSettingsProvider);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(c2.read(chartSettingsProvider).tradingPanelAtBottom, isTrue);
  });

  testWidgets('the Colors row opens the Colors screen; Free chart movement is ticked by default', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(Branding.fallback), home: const ChartSettingsScreen()),
    ));
    await tester.pump();
    final free = find.byKey(const ValueKey('cs-free-movement'));
    await tester.scrollUntilVisible(free, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<Checkbox>(find.descendant(of: free, matching: find.byType(Checkbox))).value, isTrue);
    final colors = find.byKey(const ValueKey('cs-colors'));
    await tester.scrollUntilVisible(colors, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(colors);
    await tester.pump();
    await tester.tap(colors);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cc-scheme')), findsOneWidget);
    expect(find.text('SAVE'), findsOneWidget);
  });
}
