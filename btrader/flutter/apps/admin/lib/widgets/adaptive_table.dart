import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

/// One record in an [AdaptiveTable]. `cells` line up 1:1 with the table columns;
/// `actions` are buttons shown in a trailing column on wide screens and in a
/// footer row on phones.
class AdaptiveRow {
  const AdaptiveRow({required this.cells, this.actions, this.onTap});
  final List<Widget> cells;
  final List<Widget>? actions;
  final VoidCallback? onTap;
}

/// Renders a [DataTable] on wide screens and a stacked list of label:value
/// cards on phones — so the same admin screens stay usable on a small display
/// without each screen re-implementing two layouts.
class AdaptiveTable extends StatelessWidget {
  const AdaptiveTable({
    super.key,
    required this.columns,
    required this.rows,
    this.actionsLabel = 'Actions',
    this.actionsFirst = false,
  });
  final List<String> columns;
  final List<AdaptiveRow> rows;
  final String actionsLabel;
  /// Put the actions column first so Edit/Delete stay visible without horizontal scroll.
  final bool actionsFirst;

  bool get _hasActions => rows.any((r) => (r.actions?.isNotEmpty ?? false));

  @override
  Widget build(BuildContext context) {
    if (context.isMobile) return _cards(context);
    return _table(context);
  }

  Widget _table(BuildContext context) {
    final actionCol = _hasActions ? [DataColumn(label: Text(actionsLabel))] : const <DataColumn>[];
    final dataCols = [for (final c in columns) DataColumn(label: Text(c))];
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [
            if (actionsFirst) ...actionCol,
            ...dataCols,
            if (!actionsFirst) ...actionCol,
          ],
          rows: [
            for (final r in rows)
              DataRow(
                onSelectChanged: r.onTap == null ? null : (_) => r.onTap!(),
                cells: [
                  if (actionsFirst && _hasActions)
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: r.actions ?? const [])),
                  for (final cell in r.cells) DataCell(cell),
                  if (!actionsFirst && _hasActions)
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: r.actions ?? const [])),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _cards(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      children: [
        for (final r in rows)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: r.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (r.actions?.isNotEmpty ?? false) ...[
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: r.actions!),
                      const Divider(height: 16),
                    ],
                    for (var i = 0; i < columns.length && i < r.cells.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(columns[i], style: TextStyle(color: hint, fontSize: 12.5)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: DefaultTextStyle.merge(
                              style: const TextStyle(fontSize: 13.5),
                              child: Align(alignment: Alignment.centerLeft, child: r.cells[i]),
                            )),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
