import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chart_colors.dart';
import '../widgets/color_picker.dart';

/// The colour a chart element has today with the Default scheme: the app theme's. Used to show a row's swatch
/// before anything overrides it (and as the picker's starting colour).
Color chartThemeColor(BuildContext context, ChartColorKey k) {
  final t = Theme.of(context);
  final tc = t.extension<TradeColors>()!;
  return switch (k) {
    ChartColorKey.background => t.scaffoldBackgroundColor,
    ChartColorKey.foreground => t.colorScheme.onSurface,
    ChartColorKey.grid => t.dividerColor,
    ChartColorKey.barUp || ChartColorKey.bullCandle || ChartColorKey.volumes => tc.up,
    ChartColorKey.barDown || ChartColorKey.bearCandle => tc.down,
    ChartColorKey.chartLine => t.colorScheme.primary,
    ChartColorKey.bidLine => tc.sell,
    ChartColorKey.askLine => tc.buy,
    ChartColorKey.slLine || ChartColorKey.slText => tc.loss,
    ChartColorKey.tpLine || ChartColorKey.tpText => tc.profit,
    ChartColorKey.sellLine || ChartColorKey.sellText => tc.sell,
    ChartColorKey.buyLine || ChartColorKey.buyText => tc.buy,
    ChartColorKey.stopLimitLine || ChartColorKey.stopLimitText => t.colorScheme.onSurface,
  };
}

/// MT5-style Colors screen: Scheme selector and one row per chart element with its colour as a circle. Changes are a
/// draft until SAVE, which stores them and applies them to the chart at once.
class ChartColorsScreen extends ConsumerStatefulWidget {
  const ChartColorsScreen({super.key});

  @override
  ConsumerState<ChartColorsScreen> createState() => _ChartColorsScreenState();
}

class _ChartColorsScreenState extends ConsumerState<ChartColorsScreen> {
  late ChartScheme _scheme;
  late Map<ChartColorKey, Color> _edits;
  late bool _custom;
  late final ChartColorsState _saved;

  @override
  void initState() {
    super.initState();
    _saved = ref.read(chartColorsProvider);
    _scheme = _saved.scheme;
    _edits = {..._saved.edits};
    _custom = _saved.custom;
  }

  ChartColorsState get _draft => ChartColorsState(scheme: _scheme, edits: _edits, custom: _custom);
  bool get _dirty => _scheme != _saved.scheme || _custom != _saved.custom || !_sameEdits(_edits, _saved.edits);

  static bool _sameEdits(Map<ChartColorKey, Color> a, Map<ChartColorKey, Color> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key]?.toARGB32() == e.value.toARGB32());

  void _save() {
    ref.read(chartColorsProvider.notifier).apply(_scheme, _edits, custom: _custom);
    Navigator.of(context).pop();
  }

  Future<void> _pickScheme() async {
    // MT5's selector: the schemes, then Custom. (Default is first: today's look, unchanged until another is picked.)
    final picked = await showDialog<Object>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        Widget option(Key key, String label, Object value) {
          final on = _draft.schemeLabel == label;
          return InkWell(
            key: key,
            onTap: () => Navigator.pop(ctx, value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: on ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 24),
                Expanded(child: Text(label, style: Theme.of(ctx).textTheme.titleMedium)),
              ]),
            ),
          );
        }

        return AlertDialog(
          title: const Text('Scheme'),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final s in ChartScheme.values) option(ValueKey('cc-scheme-${s.name}'), s.label, s),
              option(const ValueKey('cc-scheme-custom'), 'Custom', 'custom'),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      },
    );
    if (picked == null) return;
    setState(() {
      if (picked is ChartScheme) {
        // A predefined scheme sets all of its colours together (single-colour edits are cleared, as in MT5).
        _scheme = picked;
        _edits = {};
        _custom = false;
      } else {
        // Custom: the colours stay exactly as they are; from here they are edited one by one.
        _custom = true;
      }
    });
  }

  Future<void> _pickColor(ChartColorKey k) async {
    final now = _draft.colorOf(k, chartThemeColor(context, k));
    final c = await showChartColorPicker(context, title: k.label, initial: now);
    if (c == null || !mounted) return;
    // Only this colour changes; every other selection stays as it was.
    setState(() => _edits = {..._edits, k: c});
  }

  Future<bool> _confirmLeave() async {
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('cc-discard'),
        title: const Text('Save changes?'),
        content: const Text('You changed colors that are not saved yet.'),
        actions: [
          TextButton(key: const ValueKey('cc-discard-cancel'), onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          TextButton(key: const ValueKey('cc-discard-drop'), onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard')),
          FilledButton(key: const ValueKey('cc-discard-save'), onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (r == 'save') {
      ref.read(chartColorsProvider.notifier).apply(_scheme, _edits, custom: _custom);
      return true;
    }
    return r == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final hint = t.hintColor;
    final rows = <Widget>[];
    ChartColorGroup? group;
    for (final k in ChartColorKey.values) {
      if (k.group != group) {
        group = k.group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(group.label.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: hint)),
        ));
      }
      final c = _draft.colorOf(k, chartThemeColor(context, k));
      rows.add(InkWell(
        key: ValueKey('cc-row-${k.name}'),
        onTap: () => _pickColor(k),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.dividerColor.withValues(alpha: 0.5)))),
          child: Row(children: [
            Expanded(child: Text(k.label, style: t.textTheme.titleMedium)),
            Container(
              key: ValueKey('cc-swatch-${k.name}'),
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: hint.withValues(alpha: 0.5))),
            ),
          ]),
        ),
      ));
    }

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Colors'),
          actions: [
            TextButton(
              key: const ValueKey('cc-save'),
              onPressed: _save,
              child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            key: const ValueKey('chart-colors-list'),
            children: [
              InkWell(
                key: const ValueKey('cc-scheme'),
                onTap: _pickScheme,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.dividerColor.withValues(alpha: 0.5)))),
                  child: Row(children: [
                    Text('Scheme', style: TextStyle(color: hint, fontSize: 16)),
                    const Spacer(),
                    Text(_draft.schemeLabel, key: const ValueKey('cc-scheme-label'), style: t.textTheme.titleMedium),
                    Icon(Icons.arrow_drop_down, color: hint),
                  ]),
                ),
              ),
              ...rows,
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
