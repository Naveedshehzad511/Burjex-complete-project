import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

/// Opens the "Indicators" management sheet: list of added indicators (toggle /
/// edit / remove) plus an "Add indicator" picker. Mirrors the app's existing
/// modal-bottom-sheet trade UI.
void showIndicatorsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _IndicatorsSheet(),
  );
}

class _IndicatorsSheet extends ConsumerWidget {
  const _IndicatorsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indicators = ref.watch(chartIndicatorsProvider);
    final ctrl = ref.read(chartIndicatorsProvider.notifier);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(children: [
              const Text('Indicators', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (indicators.isNotEmpty)
                TextButton.icon(
                  onPressed: () => ctrl.clear(),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear'),
                ),
            ]),
          ),
          if (indicators.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
              child: Text('No indicators yet. Add one below to analyse the chart.',
                  textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: indicators.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final cfg = indicators[i];
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Color(cfg.colors.isNotEmpty ? cfg.colors.first : 0xFF2196F3),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    title: Text(cfg.type.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${cfg.summary}${cfg.type.usesSource ? '  ·  ${cfg.source.label}' : ''}'
                        '${cfg.type.isOverlay ? '' : '  ·  pane'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Switch(
                        value: cfg.enabled,
                        onChanged: (_) => ctrl.toggle(cfg.id),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.tune, size: 20),
                        onPressed: () => _openEditor(context, ref, cfg, isNew: false),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => ctrl.remove(cfg.id),
                      ),
                    ]),
                  );
                },
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _pickType(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add indicator'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  void _pickType(BuildContext context, WidgetRef ref) {
    final overlays = IndicatorType.values.where((t) => t.isOverlay).toList();
    final oscillators = IndicatorType.values.where((t) => !t.isOverlay).toList();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionLabel(context, 'Overlays'),
            for (final t in overlays) _typeTile(context, ref, t),
            _sectionLabel(context, 'Oscillators'),
            for (final t in oscillators) _typeTile(context, ref, t),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(s.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor, letterSpacing: 0.6)),
      );

  Widget _typeTile(BuildContext context, WidgetRef ref, IndicatorType t) => ListTile(
        dense: true,
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Color(t.defaultColors.first),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        title: Text(t.displayName),
        subtitle: Text(t.shortName),
        onTap: () {
          Navigator.pop(context); // close picker
          final id = 'new-${t.name}';
          _openEditor(context, ref, IndicatorConfig.defaults(t, id), isNew: true);
        },
      );

  void _openEditor(BuildContext context, WidgetRef ref, IndicatorConfig cfg, {required bool isNew}) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _IndicatorEditor(config: cfg, isNew: isNew),
    );
  }
}

/// Param / source / color editor, reused for adding and editing an indicator.
class _IndicatorEditor extends ConsumerStatefulWidget {
  const _IndicatorEditor({required this.config, required this.isNew});
  final IndicatorConfig config;
  final bool isNew;

  @override
  ConsumerState<_IndicatorEditor> createState() => _IndicatorEditorState();
}

class _IndicatorEditorState extends ConsumerState<_IndicatorEditor> {
  late Map<String, double> _params;
  late IndicatorSource _source;
  late List<int> _colors;

  @override
  void initState() {
    super.initState();
    _params = Map<String, double>.from(widget.config.params);
    _source = widget.config.source;
    _colors = List<int>.from(widget.config.colors);
  }

  void _save() {
    final cfg = widget.config.copyWith(params: _params, source: _source, colors: _colors);
    final ctrl = ref.read(chartIndicatorsProvider.notifier);
    if (widget.isNew) {
      // Give it a real unique id when committing (the editor used a placeholder).
      ctrl.addConfig(IndicatorConfig(
        id: '${cfg.type.name}-${DateTime.now().microsecondsSinceEpoch}',
        type: cfg.type,
        enabled: true,
        source: cfg.source,
        params: cfg.params,
        colors: cfg.colors,
      ));
    } else {
      ctrl.update(cfg);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.config.type;
    final labels = t.lineLabels;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Text(t.displayName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          Center(child: Text(t.isOverlay ? 'Price overlay' : 'Separate pane', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12))),
          const SizedBox(height: 12),
          // Numeric params.
          for (final f in t.paramFields) _paramRow(f),
          // Source.
          if (t.usesSource) ...[
            const SizedBox(height: 4),
            Row(children: [
              SizedBox(width: 110, child: Text('Source', style: TextStyle(color: Theme.of(context).hintColor))),
              const Spacer(),
              DropdownButton<IndicatorSource>(
                value: _source,
                items: IndicatorSource.values
                    .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                    .toList(),
                onChanged: (v) => setState(() => _source = v ?? _source),
              ),
            ]),
          ],
          const SizedBox(height: 4),
          // Colors, one per drawn line.
          for (var i = 0; i < labels.length; i++) _colorRow(labels[i], i),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _save,
            child: Text(widget.isNew ? 'Add' : 'Save'),
          ),
        ]),
      ),
    );
  }

  Widget _paramRow(IndicatorParamField f) {
    final v = _params[f.key] ?? widget.config.type.defaultParams[f.key] ?? f.min;
    final step = f.isInt ? 1.0 : 0.1;
    void set(double nv) {
      final clamped = nv.clamp(f.min, f.max);
      setState(() => _params[f.key] = f.isInt ? clamped.roundToDouble() : double.parse(clamped.toStringAsFixed(2)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 110, child: Text(f.label, style: TextStyle(color: Theme.of(context).hintColor))),
        const Spacer(),
        IconButton.filledTonal(visualDensity: VisualDensity.compact, onPressed: () => set(v - step), icon: const Icon(Icons.remove, size: 18)),
        SizedBox(
          width: 58,
          child: Text(
            f.isInt ? v.round().toString() : v.toStringAsFixed(v == v.roundToDouble() ? 1 : 2),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        IconButton.filledTonal(visualDensity: VisualDensity.compact, onPressed: () => set(v + step), icon: const Icon(Icons.add, size: 18)),
      ]),
    );
  }

  Widget _colorRow(String label, int idx) {
    final color = Color(idx < _colors.length ? _colors[idx] : 0xFF2196F3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 110, child: Text('$label color', style: TextStyle(color: Theme.of(context).hintColor))),
        const Spacer(),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _pickColor(idx),
          child: Container(
            width: 34,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          ),
        ),
      ]),
    );
  }

  void _pickColor(int idx) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick a color'),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in _palette)
                InkWell(
                  onTap: () {
                    setState(() {
                      while (_colors.length <= idx) {
                        _colors.add(0xFF2196F3);
                      }
                      _colors[idx] = c;
                    });
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(c),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact preset palette (no external color-picker dependency).
const List<int> _palette = [
  0xFF2196F3, 0xFF42A5F5, 0xFF26C6DA, 0xFF26A69A,
  0xFF66BB6A, 0xFF9CCC65, 0xFFFFCA28, 0xFFFFA726,
  0xFFFF7043, 0xFFEF5350, 0xFFEC407A, 0xFFAB47BC,
  0xFF7E57C2, 0xFF5C6BC0, 0xFF90A4AE, 0xFFECEFF1,
];
