import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../widgets/account_panel.dart';
import '../widgets/big_figure_price.dart';
import '../widgets/trade_toast.dart';
import '../services/sound_service.dart';

/// Pull a human-readable message out of a Dio/API error (e.g. "market closed").
String _errMessage(Object e) {
  try {
    final d = (e as dynamic).response?.data;
    if (d is Map) {
      final m = d['message'] ?? (d['error'] is Map ? d['error']['message'] : d['error']);
      if (m is String && m.trim().isNotEmpty) return m;
    }
  } catch (_) {/* fall through */}
  return 'Please try again';
}

/// Order ticket supporting every order type plus one-click market execution.
class TradeScreen extends ConsumerStatefulWidget {
  const TradeScreen({super.key, this.symbol});
  final String? symbol;

  @override
  ConsumerState<TradeScreen> createState() => _TradeScreenState();
}

/// A quote older than this (ms) is treated as no-live-price; market orders block.
const int _kStalePriceMs = 8000;

class _TradeScreenState extends ConsumerState<TradeScreen> {
  bool _isStale(Tick? q) =>
      q == null || DateTime.now().millisecondsSinceEpoch - q.ts > _kStalePriceMs;

  late String _symbol;
  OrderType _type = OrderType.market;
  double _volume = 0.10;
  final _price = TextEditingController();
  final _sl = TextEditingController();
  final _tp = TextEditingController();
  late final TextEditingController _volCtrl = TextEditingController(text: _volume.toStringAsFixed(2));
  bool _oneClick = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Keep the last symbol the user was looking at (shared with the chart)
    // instead of defaulting to EURUSD.
    _symbol = widget.symbol ?? ref.read(chartSymbolProvider);
  }

  @override
  void dispose() {
    _volCtrl.dispose();
    super.dispose();
  }

  /// Clamp + round the typed/stepped volume to the symbol's lot limits.
  void _setVolume(double v, TradeSymbol? spec) {
    final mn = spec?.minLot ?? 0.01, mx = spec?.maxLot ?? 100;
    final clamped = double.parse(v.clamp(mn, mx).toStringAsFixed(2));
    setState(() => _volume = clamped);
    _volCtrl.text = clamped.toStringAsFixed(2);
    _volCtrl.selection = TextSelection.collapsed(offset: _volCtrl.text.length);
  }

  @override
  void didUpdateWidget(covariant TradeScreen old) {
    super.didUpdateWidget(old);
    if (widget.symbol != null && widget.symbol != _symbol) {
      setState(() => _symbol = widget.symbol!);
    }
  }

  Future<void> _submit(String side) async {
    final accountId = ref.read(activeAccountIdProvider);
    if (accountId == null) return;
    final oneClick = _type == OrderType.market && _oneClick;
    final q = ref.read(quotesProvider)[_symbol];
    // Live-price guard: never send a market order on a missing/stale quote (the
    // server enforces this too, but block here so the user sees why).
    if (_type == OrderType.market && _isStale(q)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No live price — trading paused until the feed updates')));
      return;
    }
    final tc = Theme.of(context).extension<TradeColors>()!;
    final accent = side == 'BUY' ? tc.buy : tc.sell;
    final vol = _volume;
    final sym = _symbol;
    final req = PlaceOrderRequest(
      accountId: accountId,
      symbol: _symbol,
      side: side,
      type: _type,
      volume: _volume,
      oneClick: oneClick,
      price: _type == OrderType.market
          ? (side == 'BUY' ? q?.ask : q?.bid)
          : double.tryParse(_price.text),
      stopPrice: _type.api.contains('STOP') ? double.tryParse(_price.text) : null,
      slPrice: double.tryParse(_sl.text),
      tpPrice: double.tryParse(_tp.text),
    );
    // One-click stays instant: don't disable the buttons, so the client can fire
    // multiple trades back-to-back. Each result shows a non-blocking toast.
    if (!oneClick) setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).post('/orders', req.toJson());
      if (res['accepted'] == true) {
        ref.invalidate(accountsProvider);
        SoundService.instance.tradeOpen();
        ToastHost.show('$side $sym  ${vol.toStringAsFixed(2)}', 'Filled @ ${res['fillPrice'] ?? '—'}', accent: accent);
      } else {
        SoundService.instance.error();
        ToastHost.show('Order rejected', '${res['reason'] ?? ''}', accent: tc.loss);
      }
    } catch (e) {
      SoundService.instance.error();
      ToastHost.show('Order failed', _errMessage(e), accent: tc.loss);
    } finally {
      if (mounted && !oneClick) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final q = ref.watch(quotesProvider)[_symbol];
    TradeSymbol? spec;
    for (final s in symbols) {
      if (s.symbol == _symbol) {
        spec = s;
        break;
      }
    }
    final digits = spec?.digits ?? 5;
    final tc = Theme.of(context).extension<TradeColors>()!;
    final pending = _type != OrderType.market;
    final stale = _isStale(q);
    final blockMarket = _type == OrderType.market && stale;

    return Scaffold(
      appBar: AppBar(title: Text(symbolDisplay(_symbol, ref.watch(clientSuffixProvider)))),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const AccountPanel(),
        const SizedBox(height: 12),
        if (stale)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x22E5484D),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x55E5484D)),
            ),
            child: const Row(children: [
              Icon(Icons.wifi_off_rounded, size: 16, color: Color(0xFFE5484D)),
              SizedBox(width: 8),
              Expanded(child: Text('No live price — market trading is paused until the feed updates.',
                  style: TextStyle(fontSize: 12.5))),
            ]),
          ),
        Row(children: [
          _PriceTile(label: 'SELL', value: q?.bid, digits: digits, color: tc.sell),
          const SizedBox(width: 8),
          _PriceTile(label: 'BUY', value: q?.ask, digits: digits, color: tc.buy),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 36,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final t in OrderType.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(t.label), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        Text('Volume (lots)', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        Row(children: [
          IconButton.filledTonal(onPressed: () => _setVolume(_volume - (spec?.lotStep ?? 0.01), spec), icon: const Icon(Icons.remove)),
          Expanded(child: TextField(
            controller: _volCtrl,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            decoration: const InputDecoration(isDense: true, border: InputBorder.none),
            onChanged: (v) { final d = double.tryParse(v); if (d != null) setState(() => _volume = d); },
            onEditingComplete: () { _setVolume(_volume, spec); FocusScope.of(context).unfocus(); },
          )),
          IconButton.filledTonal(onPressed: () => _setVolume(_volume + (spec?.lotStep ?? 0.01), spec), icon: const Icon(Icons.add)),
        ]),
        if (pending) ...[
          const SizedBox(height: 8),
          TextField(controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price / Stop')),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _sl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stop loss'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _tp, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Take profit'))),
        ]),
        if (_type == OrderType.market)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _oneClick,
            onChanged: (v) => setState(() => _oneClick = v),
            title: const Text('One-click trading'),
            secondary: const Icon(Icons.bolt_rounded),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _ActionButton(label: blockMarket ? 'SELL' : 'SELL ${_volume.toStringAsFixed(2)}', color: tc.sell, busy: _busy, enabled: !blockMarket, onTap: () => _submit('SELL'))),
          const SizedBox(width: 8),
          Expanded(child: _ActionButton(label: blockMarket ? 'BUY' : 'BUY ${_volume.toStringAsFixed(2)}', color: tc.buy, busy: _busy, enabled: !blockMarket, onTap: () => _submit('BUY'))),
        ]),
      ]),
    );
  }
}

class _PriceTile extends StatelessWidget {
  const _PriceTile({required this.label, required this.value, required this.digits, required this.color});
  final String label;
  final double? value;
  final int digits;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
        child: Column(children: [
          Text(label, style: TextStyle(color: color, fontSize: 12)),
          value == null
              ? const Text('—', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500))
              : BigFigurePrice(value: value!, digits: digits, color: color, baseSize: 18),
        ]),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.color, required this.busy, required this.onTap, this.enabled = true});
  final String label;
  final Color color;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: (busy || !enabled) ? null : onTap,
      style: FilledButton.styleFrom(backgroundColor: color, padding: const EdgeInsets.symmetric(vertical: 16)),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
  }
}
