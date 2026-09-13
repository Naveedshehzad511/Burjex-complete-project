import 'package:flutter/material.dart';

const kPricingMethods = ['SPREAD_ONLY', 'COMMISSION_ONLY', 'SPREAD_AND_COMMISSION'];

String pricingMethodLabel(String m) => switch (m) {
      'COMMISSION_ONLY' => 'Commission only',
      'SPREAD_AND_COMMISSION' => 'Spread + Commission',
      _ => 'Spread only',
    };

num mappingNum(dynamic v) => v == null ? 0 : (v is num ? v : num.tryParse('$v') ?? 0);

/// Draft row: feed symbol → client alias + pricing (spread / commission / both).
class SymbolMappingDraft {
  String lpSymbol;
  String clientSymbol;
  String pricingMethod;
  final TextEditingController minSpread;
  final TextEditingController maxSpread;
  String commissionType;
  final TextEditingController commissionValue;

  SymbolMappingDraft({
    required this.lpSymbol,
    required this.clientSymbol,
    this.pricingMethod = 'SPREAD_ONLY',
    int minSpreadPoints = 0,
    int maxSpreadPoints = 0,
    this.commissionType = 'NONE',
    num commissionValue = 0,
  })  : minSpread = TextEditingController(text: '$minSpreadPoints'),
        maxSpread = TextEditingController(text: '$maxSpreadPoints'),
        commissionValue = TextEditingController(text: '$commissionValue');

  factory SymbolMappingDraft.fromJson(Map<String, dynamic> j) => SymbolMappingDraft(
        lpSymbol: '${j['lpSymbol'] ?? ''}',
        clientSymbol: '${j['clientSymbol'] ?? ''}',
        pricingMethod: '${j['pricingMethod'] ?? 'SPREAD_ONLY'}',
        minSpreadPoints: (j['minSpreadPoints'] as num?)?.toInt() ?? 0,
        maxSpreadPoints: (j['maxSpreadPoints'] as num?)?.toInt() ?? 0,
        commissionType: '${j['commissionType'] ?? 'NONE'}',
        commissionValue: mappingNum(j['commissionValue']),
      );

  Map<String, dynamic> toJson() => {
        'lpSymbol': lpSymbol.trim().toUpperCase(),
        'clientSymbol': clientSymbol.trim(),
        'pricingMethod': pricingMethod,
        'minSpreadPoints': int.tryParse(minSpread.text) ?? 0,
        'maxSpreadPoints': int.tryParse(maxSpread.text) ?? 0,
        'commissionType': pricingMethod == 'SPREAD_ONLY' ? 'NONE' : commissionType,
        'commissionValue': double.tryParse(commissionValue.text) ?? 0,
        'enabled': true,
      };
}

class SymbolMappingEditor extends StatelessWidget {
  const SymbolMappingEditor({
    super.key,
    required this.lpSymbols,
    required this.mappings,
    required this.onChanged,
    this.loading = false,
  });

  final List<Map<String, dynamic>> lpSymbols;
  final List<SymbolMappingDraft> mappings;
  final VoidCallback onChanged;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AddMappingRow(
          lpSymbols: lpSymbols,
          onAdd: (row) {
            mappings.add(row);
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        if (mappings.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No aliases yet — pick a feed symbol, set your name (e.g. XAUUSD.s), then choose spread, commission, or both.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        ...mappings.asMap().entries.map((e) {
          final i = e.key;
          final m = e.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${m.lpSymbol}  →  ${m.clientSymbol}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          mappings.removeAt(i);
                          onChanged();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: m.pricingMethod,
                    decoration: const InputDecoration(
                      labelText: 'Apply on live trades',
                      helperText: 'Spread, commission, or both — only when this pack is on the trading group',
                      isDense: true,
                    ),
                    items: kPricingMethods
                        .map((p) => DropdownMenuItem(value: p, child: Text(pricingMethodLabel(p))))
                        .toList(),
                    onChanged: (v) {
                      m.pricingMethod = v ?? 'SPREAD_ONLY';
                      onChanged();
                    },
                  ),
                  if (m.pricingMethod != 'COMMISSION_ONLY') ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: m.minSpread,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Min spread (points)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: m.maxSpread,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Max spread (points)',
                            isDense: true,
                            helperText: '0 = no cap',
                          ),
                        ),
                      ),
                    ]),
                  ],
                  if (m.pricingMethod != 'SPREAD_ONLY') ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: m.commissionType == 'NONE' ? 'PER_LOT' : m.commissionType,
                          decoration: const InputDecoration(labelText: 'Commission type', isDense: true),
                          items: const [
                            DropdownMenuItem(value: 'PER_LOT', child: Text('Per lot')),
                            DropdownMenuItem(value: 'PER_SIDE', child: Text('Per side')),
                            DropdownMenuItem(value: 'ROUND_TURN', child: Text('Round turn')),
                          ],
                          onChanged: (v) {
                            m.commissionType = v ?? 'PER_LOT';
                            onChanged();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: m.commissionValue,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Commission value',
                            isDense: true,
                          ),
                        ),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _AddMappingRow extends StatefulWidget {
  const _AddMappingRow({required this.lpSymbols, required this.onAdd});
  final List<Map<String, dynamic>> lpSymbols;
  final void Function(SymbolMappingDraft row) onAdd;

  @override
  State<_AddMappingRow> createState() => _AddMappingRowState();
}

class _AddMappingRowState extends State<_AddMappingRow> {
  final _lpCtrl = TextEditingController();
  final _clientCtrl = TextEditingController();
  final _lpFocus = FocusNode();
  String? _selectedLp;

  @override
  void dispose() {
    _lpCtrl.dispose();
    _clientCtrl.dispose();
    _lpFocus.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _lpCtrl.text.trim().toUpperCase();
    if (q.isEmpty) return widget.lpSymbols.take(40).toList();
    return widget.lpSymbols.where((s) => '${s['symbol']}'.toUpperCase().contains(q)).take(40).toList();
  }

  void _add() {
    final lp = (_selectedLp ?? _lpCtrl.text).trim().toUpperCase();
    final client = _clientCtrl.text.trim().isEmpty ? lp : _clientCtrl.text.trim();
    if (lp.isEmpty) return;
    widget.onAdd(SymbolMappingDraft(lpSymbol: lp, clientSymbol: client));
    setState(() {
      _lpCtrl.clear();
      _clientCtrl.clear();
      _selectedLp = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: RawAutocomplete<Map<String, dynamic>>(
                textEditingController: _lpCtrl,
                focusNode: _lpFocus,
                optionsBuilder: (v) {
                  final q = v.text.trim().toUpperCase();
                  if (q.isEmpty) return widget.lpSymbols.take(30);
                  return widget.lpSymbols.where((s) => '${s['symbol']}'.toUpperCase().contains(q)).take(30);
                },
                displayStringForOption: (o) => '${o['symbol']}',
                onSelected: (o) {
                  setState(() {
                    _selectedLp = '${o['symbol']}';
                    _lpCtrl.text = _selectedLp!;
                    if (_clientCtrl.text.trim().isEmpty) _clientCtrl.text = _selectedLp!;
                  });
                },
                fieldViewBuilder: (ctx, controller, focus, onSubmit) => TextField(
                  controller: controller,
                  focusNode: focus,
                  decoration: InputDecoration(
                    labelText: 'Feed symbol',
                    hintText: widget.lpSymbols.isEmpty ? 'Connect LP / feed first' : 'Search XAUUSD, EURUSD…',
                    isDense: true,
                    suffixIcon: widget.lpSymbols.any((s) => s['live'] == true)
                        ? const Tooltip(message: 'Live feed symbols available', child: Icon(Icons.sensors, size: 18))
                        : null,
                  ),
                  onChanged: (_) => setState(() => _selectedLp = null),
                  onSubmitted: (_) => onSubmit(),
                ),
                optionsViewBuilder: (ctx, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (_, i) {
                          final o = options.elementAt(i);
                          final live = o['live'] == true;
                          return ListTile(
                            dense: true,
                            title: Text('${o['symbol']}'),
                            subtitle: Text('${o['class']}${live ? ' · live' : ''}'),
                            onTap: () => onSelected(o),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _clientCtrl,
                decoration: const InputDecoration(
                  labelText: 'Our symbol',
                  hintText: 'e.g. XAUUSD.s',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonal(
                onPressed: _add,
                child: const Text('Add'),
              ),
            ),
          ],
        ),
        if (_lpCtrl.text.isNotEmpty && _filtered.isNotEmpty && _selectedLp == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Suggestions: ${_filtered.take(5).map((s) => s['symbol']).join(', ')}',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ),
      ],
    );
  }
}
