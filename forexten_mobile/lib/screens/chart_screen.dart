import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../state/account_view.dart';
import '../widgets/candle_chart.dart';

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

class ChartScreen extends ConsumerStatefulWidget {
  const ChartScreen({super.key, this.symbol});
  final String? symbol;
  @override
  ConsumerState<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends ConsumerState<ChartScreen> {
  double _volume = 0.10;
  late final TextEditingController _volCtrl = TextEditingController(text: '0.10');
  bool _busy = false;

  @override
  void dispose() {
    _volCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final s = widget.symbol;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (s != null && s.isNotEmpty) ref.read(chartSymbolProvider.notifier).set(s);
    });
  }

  Future<void> _place(String side) async {
    final accountId = ref.read(activeAccountIdProvider);
    final symbol = ref.read(chartSymbolProvider);
    if (accountId == null) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider);
      await api.post('/orders', PlaceOrderRequest(
        accountId: accountId,
        symbol: symbol,
        side: side,
        type: OrderType.market,
        volume: _volume,
        oneClick: true,
      ).toJson());
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

  @override
  Widget build(BuildContext context) {
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    final symbol = ref.watch(chartSymbolProvider);
    final tf = ref.watch(chartTfProvider);
    final req = ChartReq(symbol, tf);
    final series = ref.watch(liveCandlesProvider(req));
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    TradeSymbol? spec;
    for (final s in symbols) {
      if (s.symbol == symbol) spec = s;
    }
    final tick = ref.watch(quotesProvider.select((m) => m[symbol]));
    final digits = spec?.digits ?? 5;
    final last = tick == null ? null : (tick.bid + tick.ask) / 2;
    final suffix = ref.watch(clientSuffixProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;

    return Scaffold(
      appBar: AppBar(
        title: Text(symbolDisplay(spec?.displaySymbol ?? symbol, suffix)),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Symbol',
            onSelected: (v) => ref.read(chartSymbolProvider.notifier).set(v),
            itemBuilder: (_) => [
              for (final s in symbols.take(40))
                PopupMenuItem(value: s.symbol, child: Text(s.displaySymbol)),
            ],
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final t in Timeframe.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: Text(t.label),
                    selected: t == tf,
                    onSelected: (_) => ref.read(chartTfProvider.notifier).set(t),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: series.when(
            loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('$e')),
            data: (bars) => Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: CandleChart(candles: bars, digits: digits, lastPrice: last),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: tc.sell, minimumSize: const Size.fromHeight(48)),
                  onPressed: _busy ? null : () => _place('SELL'),
                  child: Text(tick == null ? 'SELL' : 'SELL ${tick.bid.toStringAsFixed(digits)}'),
                ),
              ),
              SizedBox(
                width: 88,
                child: TextField(
                  controller: _volCtrl,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onSubmitted: (v) {
                    final n = double.tryParse(v) ?? _volume;
                    setState(() {
                      _volume = n.clamp(spec?.minLot ?? 0.01, spec?.maxLot ?? 100);
                      _volCtrl.text = _volume.toStringAsFixed(2);
                    });
                  },
                ),
              ),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: tc.buy, minimumSize: const Size.fromHeight(48)),
                  onPressed: _busy ? null : () => _place('BUY'),
                  child: Text(tick == null ? 'BUY' : 'BUY ${tick.ask.toStringAsFixed(digits)}'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
