import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../state/account_view.dart';

String _errMessage(Object e) {
  try {
    final d = (e as dynamic).response?.data;
    if (d is Map) {
      final m = d['message'] ?? (d['error'] is Map ? d['error']['message'] : d['error']);
      if (m is String && m.trim().isNotEmpty) return m;
    }
  } catch (_) {}
  return e.toString().replaceFirst('Exception: ', '');
}

class TradeScreen extends ConsumerStatefulWidget {
  const TradeScreen({super.key, this.symbol});
  final String? symbol;
  @override
  ConsumerState<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends ConsumerState<TradeScreen> {
  late String _symbol;
  double _volume = 0.10;
  final _sl = TextEditingController();
  final _tp = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _symbol = widget.symbol ?? ref.read(chartSymbolProvider);
  }

  @override
  void dispose() {
    _sl.dispose();
    _tp.dispose();
    super.dispose();
  }

  Future<void> _place(String side) async {
    final accountId = ref.read(activeAccountIdProvider);
    if (accountId == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).post(
            '/orders',
            PlaceOrderRequest(
              accountId: accountId,
              symbol: _symbol,
              side: side,
              type: OrderType.market,
              volume: _volume,
              slPrice: double.tryParse(_sl.text),
              tpPrice: double.tryParse(_tp.text),
              oneClick: true,
            ).toJson(),
          );
      ref.invalidate(openPositionsProvider);
      ref.invalidate(accountsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$side $_volume lots')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_errMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(String id, {double? volume}) async {
    try {
      await ref.read(apiClientProvider).post('/positions/$id/close', volume != null ? {'volume': volume} : {});
      ref.invalidate(openPositionsProvider);
      ref.invalidate(accountsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_errMessage(e))));
      }
    }
  }

  Future<void> _modify(Position p) async {
    final sl = TextEditingController(text: p.slPrice?.toString() ?? '');
    final tp = TextEditingController(text: p.tpPrice?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modify position'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: sl, decoration: const InputDecoration(labelText: 'Stop loss'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          TextField(controller: tp, decoration: const InputDecoration(labelText: 'Take profit'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).patch('/positions/${p.id}', {
        if (double.tryParse(sl.text) != null) 'slPrice': double.parse(sl.text),
        if (double.tryParse(tp.text) != null) 'tpPrice': double.parse(tp.text),
      });
      ref.invalidate(openPositionsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_errMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    final acc = ref.watch(activeAccountProvider);
    final positions = ref.watch(openPositionsProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final quotes = ref.watch(quotesProvider);
    final livePL = ref.watch(livePositionProvider);
    final anchors = ref.watch(livePositionAnchorProvider);
    final vols = ref.watch(livePositionVolumeProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    final suffix = ref.watch(clientSuffixProvider);
    TradeSymbol? spec;
    for (final s in symbols) {
      if (s.symbol == _symbol) spec = s;
    }
    final tick = quotes[_symbol];

    final posList = positions.valueOrNull ?? const <Position>[];
    double floating = 0;
    for (final p in posList) {
      floating += resolvePositionPl(p, livePl: livePL, quotes: quotes, symbols: symbols, anchors: anchors, volumes: vols);
    }
    final balance = acc?.balance ?? 0;
    final credit = acc?.credit ?? 0;
    final margin = posList.isEmpty ? 0.0 : (acc?.margin ?? 0);
    final equity = balance + credit + floating;
    final free = equity - margin;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(openPositionsProvider)),
        ],
      ),
      body: Column(children: [
        if (acc != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(children: [
              Expanded(child: _kv(context, 'Balance', money(balance))),
              Expanded(child: _kv(context, 'Equity', money(equity))),
              Expanded(child: _kv(context, 'Credit', money(credit))),
              Expanded(child: _kv(context, 'Margin', money(margin))),
              Expanded(child: _kv(context, 'Free margin', money(free))),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(children: [
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: symbols.any((s) => s.symbol == _symbol)
                      ? _symbol
                      : (symbols.isNotEmpty ? symbols.first.symbol : null),
                  hint: const Text('Symbol'),
                  items: [
                    for (final s in symbols)
                      DropdownMenuItem(value: s.symbol, child: Text(s.displaySymbol)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _symbol = v);
                    ref.read(chartSymbolProvider.notifier).set(v);
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 88,
              child: TextFormField(
                initialValue: _volume.toStringAsFixed(2),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(labelText: 'Lots'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) {
                  final n = double.tryParse(v);
                  if (n != null) _volume = n;
                },
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(child: TextField(controller: _sl, decoration: const InputDecoration(labelText: 'SL'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _tp, decoration: const InputDecoration(labelText: 'TP'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: tc.sell, minimumSize: const Size.fromHeight(44)),
                onPressed: _busy ? null : () => _place('SELL'),
                child: Text(tick == null ? 'SELL' : 'SELL ${tick.bid.toStringAsFixed(spec?.digits ?? 5)}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: tc.buy, minimumSize: const Size.fromHeight(44)),
                onPressed: _busy ? null : () => _place('BUY'),
                child: Text(tick == null ? 'BUY' : 'BUY ${tick.ask.toStringAsFixed(spec?.digits ?? 5)}'),
              ),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: positions.when(
            loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('$e')),
            data: (rows) {
              if (rows.isEmpty) {
                return Center(child: Text('No open trades.', style: TextStyle(color: Theme.of(context).hintColor)));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = rows[i];
                  final pl = resolvePositionPl(
                    p,
                    livePl: livePL,
                    quotes: quotes,
                    symbols: symbols,
                    anchors: anchors,
                    volumes: vols,
                  );
                  final color = pl >= 0 ? tc.profit : tc.loss;
                  return ListTile(
                    title: Text('${symbolDisplay(p.symbol, suffix)}  ${p.side}  ${p.volume.toStringAsFixed(2)}'),
                    subtitle: Text('Open ${p.openPrice.toStringAsFixed(p.digits)}  SL ${p.slPrice ?? '—'}  TP ${p.tpPrice ?? '—'}'),
                    trailing: Text(money(pl), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                    onTap: () => _posMenu(p),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }

  void _posMenu(Position p) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('Modify position'),
            onTap: () {
              Navigator.pop(ctx);
              _modify(p);
            },
          ),
          ListTile(
            title: const Text('Partial close'),
            onTap: () {
              Navigator.pop(ctx);
              _close(p.id, volume: p.volume / 2);
            },
          ),
          ListTile(
            title: const Text('Close trade', style: TextStyle(color: Color(0xFFE5484D))),
            onTap: () {
              Navigator.pop(ctx);
              _close(p.id);
            },
          ),
        ]),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Column(
        children: [
          Text(k, style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      );
}
