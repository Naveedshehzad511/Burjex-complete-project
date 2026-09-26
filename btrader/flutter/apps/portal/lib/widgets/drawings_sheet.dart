import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

/// Drawing-tools sheet: pick a tool to place (horizontal line / trendline /
/// Fibonacci) and manage the drawings already on the current symbol.
void showDrawingsSheet(
  BuildContext context, {
  required String symbol,
  required int digits,
  required void Function(DrawingType) onSelectTool,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DrawingsSheet(symbol: symbol, digits: digits, onSelectTool: onSelectTool),
  );
}

/// A compact preset palette (shared look with the indicator color picker).
const List<int> _palette = [
  0xFF2196F3, 0xFF42A5F5, 0xFF26C6DA, 0xFF26A69A,
  0xFF66BB6A, 0xFF9CCC65, 0xFFFFCA28, 0xFFFFA726,
  0xFFFF7043, 0xFFEF5350, 0xFFEC407A, 0xFFAB47BC,
  0xFF7E57C2, 0xFF5C6BC0, 0xFF90A4AE, 0xFFECEFF1,
];

class _DrawingsSheet extends ConsumerWidget {
  const _DrawingsSheet({required this.symbol, required this.digits, required this.onSelectTool});
  final String symbol;
  final int digits;
  final void Function(DrawingType) onSelectTool;

  void _pickColor(BuildContext context, void Function(int) onPick) {
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
                    onPick(c);
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(chartDrawingsProvider).where((d) => d.symbol == symbol).toList();
    final ctrl = ref.read(chartDrawingsProvider.notifier);

    Widget toolTile(DrawingType t, IconData icon) => ListTile(
          dense: true,
          leading: Icon(icon, color: Color(t.defaultColor)),
          title: Text(t.label),
          subtitle: Text('${t.anchorCount} tap${t.anchorCount > 1 ? 's' : ''} to place'),
          onTap: () {
            Navigator.pop(context);
            onSelectTool(t);
          },
        );

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Drawing tools', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          toolTile(DrawingType.horizontalLine, Icons.horizontal_rule),
          toolTile(DrawingType.trendline, Icons.trending_up),
          toolTile(DrawingType.fibRetracement, Icons.stacked_line_chart),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(children: [
              Text('On $symbol', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
              const Spacer(),
              if (mine.isNotEmpty)
                TextButton.icon(
                  onPressed: () => ctrl.clearSymbol(symbol),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear'),
                ),
            ]),
          ),
          if (mine.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: Text('No drawings yet. Pick a tool above and tap the chart to place it.',
                  textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: mine.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = mine[i];
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: InkWell(
                      onTap: () => _pickColor(context, (c) => ctrl.updateColor(d.id, c)),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(d.colorArgb),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: Theme.of(context).dividerColor),
                        ),
                        child: const Icon(Icons.edit, size: 13, color: Colors.white),
                      ),
                    ),
                    title: Text(d.type.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(d.summary(digits)),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => ctrl.remove(d.id),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}
