import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chart_settings.dart';
import 'chart_colors_screen.dart';

String chartLineTypeLabel(ChartLineType t) => switch (t) {
      ChartLineType.bar => 'Bar chart',
      ChartLineType.candles => 'Candlestick',
      ChartLineType.line => 'Line chart',
    };

/// MT5-style chart settings (phase 1: the screen and its saved state; see [ChartSettingsState]).
class ChartSettingsScreen extends ConsumerWidget {
  const ChartSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(chartSettingsProvider);
    final c = ref.read(chartSettingsProvider.notifier);

    Widget check(Key key, String title, String subtitle, bool value, ValueChanged<bool> onChanged) =>
        _SettingTile(
          key: key,
          title: title,
          subtitle: subtitle,
          onTap: () => onChanged(!value),
          trailing: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('chart-settings-list'),
          children: [
            _SettingTile(
              key: const ValueKey('cs-line-type'),
              title: 'Line type',
              subtitle: chartLineTypeLabel(s.lineType),
              onTap: () => _pick<ChartLineType>(
                context,
                title: 'Line type',
                values: ChartLineType.values,
                selected: s.lineType,
                label: chartLineTypeLabel,
                onPick: c.setLineType,
              ),
            ),
            check(const ValueKey('cs-trade-positions'), 'Trade positions',
                'Show position open prices on the chart', s.tradePositions, c.setTradePositions),
            check(const ValueKey('cs-trade-orders'), 'Trade orders',
                'Show pending order prices on the chart', s.tradeOrders, c.setTradeOrders),
            check(const ValueKey('cs-trade-history'), 'Trade history',
                'Show trade operations history on the chart', s.tradeHistory, c.setTradeHistory),
            check(const ValueKey('cs-profit-loss'), 'Profit/loss',
                'Show profit/loss for open positions', s.profitLoss, c.setProfitLoss),
            check(const ValueKey('cs-sl-tp'), 'SL/TP levels',
                'Show Stop Loss and Take Profit values on the chart', s.slTpLevels, c.setSlTpLevels),
            check(
                const ValueKey('cs-period-separators'),
                'Show period separators',
                'Show additional vertical lines on the chart indicating the higher timeframe borders',
                s.periodSeparators,
                c.setPeriodSeparators),
            check(const ValueKey('cs-panel-bottom'), 'Trading panel at the bottom',
                'Show the trading panel at the bottom of the chart', s.tradingPanelAtBottom, c.setTradingPanelAtBottom),
            check(const ValueKey('cs-free-movement'), 'Free chart movement', 'Free chart movement',
                s.freeChartMovement, c.setFreeChartMovement),
            _SettingTile(
              key: const ValueKey('cs-colors'),
              title: 'Colors',
              subtitle: 'Customize color scheme',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ChartColorsScreen())),
              last: true,
            ),
          ],
        ),
      ),
    );
  }

  /// MT5-style radio dialog: title, one radio row per value, Cancel.
  Future<void> _pick<T>(
    BuildContext context, {
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onPick,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(title),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final v in values)
                InkWell(
                  key: ValueKey('cs-option-${label(v)}'),
                  onTap: () {
                    onPick(v);
                    Navigator.pop(ctx);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Icon(v == selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: v == selected ? cs.primary : cs.onSurfaceVariant),
                      const SizedBox(width: 24),
                      Expanded(child: Text(label(v), style: Theme.of(ctx).textTheme.titleMedium)),
                    ]),
                  ),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      },
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.last = false,
  });
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: last ? Colors.transparent : t.dividerColor.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}
