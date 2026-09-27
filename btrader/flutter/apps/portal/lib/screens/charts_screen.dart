import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sound_service.dart';
import '../session/sessions.dart';
import '../state/pending_orders.dart';
import '../widgets/candle_chart.dart';
import '../widgets/drawings_sheet.dart';
import '../widgets/indicators_sheet.dart';
import '../widgets/manage_accounts.dart';
import '../widgets/pending_panel.dart';
import '../widgets/trade_toast.dart';

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

/// Live, interactive candlestick chart.
///
/// * Pan in any direction, pinch to zoom, long-press crosshair, "Auto fit" to reset.
/// * Open positions and pending orders draw as thin lines with a large touch area;
///   SL / TP / pending lines are dragged directly, then confirmed with Apply.
/// * Picking Buy/Sell Limit/Stop puts the line on the chart at once; drag it, Apply.
/// * SELL / BUY panels show Bid / Ask only; the candle price line is separate.
class ChartsScreen extends ConsumerStatefulWidget {
  const ChartsScreen({super.key, this.symbol});
  final String? symbol;

  @override
  ConsumerState<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends ConsumerState<ChartsScreen> {
  String get _symbol => ref.read(chartSymbolProvider);
  set _symbol(String v) => ref.read(chartSymbolProvider.notifier).set(v);
  ChartType _type = ChartType.candles;
  DrawingType? _activeTool;
  List<DrawingAnchor> _pendingAnchors = [];
  double _volume = 0.10;
  late final TextEditingController _volCtrl = TextEditingController(text: _volume.toStringAsFixed(2));
  bool _placing = false;
  bool _applying = false;
  ChartEdit? _edit;
  String? _serverError; // last server rejection, shown inside the panel

  @override
  void initState() {
    super.initState();
    final s = widget.symbol;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (s != null) ref.read(chartSymbolProvider.notifier).set(s);
      final sym = ref.read(chartSymbolProvider);
      prefetchChartHistory(sym, (req) => ref.read(candlesProvider(req).future));
    });
  }

  @override
  void dispose() {
    _volCtrl.dispose();
    super.dispose();
  }

  void _setVolume(double v, TradeSymbol? spec) {
    final mn = spec?.minLot ?? 0.01, mx = spec?.maxLot ?? 100;
    final clamped = double.parse(v.clamp(mn, mx).toStringAsFixed(2));
    setState(() => _volume = clamped);
    _volCtrl.text = clamped.toStringAsFixed(2);
    _volCtrl.selection = TextSelection.collapsed(offset: _volCtrl.text.length);
  }

  TradeSymbol? _spec() {
    final symbols = ref.read(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    for (final s in symbols) {
      if (s.symbol == _symbol) return s;
    }
    return null;
  }

  /// The prices the user sees on the SELL / BUY panels (group spread applied).
  Tick? _shownQuote() {
    final q = ref.read(quotesProvider)[_symbol];
    if (q == null) return null;
    return _spec()?.applyGroupMarkup(q) ?? q;
  }

  bool get _readonly => ref.read(tradingSessionProvider).readonly;

  void _toastReadonly() {
    final tc = Theme.of(context).extension<TradeColors>()!;
    ToastHost.show('Read-only account', 'Signed in with the investor password — trading is disabled.', accent: tc.loss);
  }

  // ── Market order (one click) ──────────────────────────────────────────────

  Future<void> _placeMarket(String side) async {
    if (_readonly) return _toastReadonly();
    if (_placing) return; // double-click guard; the server also de-duplicates on clientOrderId
    final accountId = ref.read(activeAccountIdProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (accountId == null) {
      ToastHost.show('No account', 'Select a trading account first', accent: tc.loss);
      return;
    }
    final q = _shownQuote();
    if (q == null) return;
    final sym = _symbol;
    final vol = _volume;
    final px = side == 'BUY' ? q.ask : q.bid;
    setState(() => _placing = true);
    try {
      final req = PlaceOrderRequest(
        accountId: accountId,
        symbol: sym,
        side: side,
        type: OrderType.market,
        volume: vol,
        oneClick: true,
        price: px,
      );
      final res = await ref.read(apiClientProvider).post('/orders', req.toJson());
      if (res['accepted'] == true) {
        // Feedback first — the instant the server confirms — then refresh state.
        SoundService.instance.orderPlaced('${res['orderId'] ?? ''}');
        ref.invalidate(accountsProvider);
        ref.invalidate(openPositionsProvider);
        ToastHost.show('$side $sym  ${vol.toStringAsFixed(2)}', 'Filled @ ${res['fillPrice'] ?? '—'}', accent: side == 'BUY' ? tc.buy : tc.sell);
      } else {
        SoundService.instance.error();
        ToastHost.show('Order rejected', '${res['reason'] ?? ''}', accent: tc.loss);
      }
    } catch (e) {
      SoundService.instance.error();
      ToastHost.show('Order failed', _errMessage(e), accent: tc.loss);
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  // ── Pending orders and SL / TP editing (one panel for all of it) ──────────

  ({double min, double max, double step}) _lots() {
    final sp = _spec();
    return (min: sp?.minLot ?? 0.01, max: sp?.maxLot ?? 100.0, step: sp?.lotStep ?? 0.01);
  }

  double _snapLot(double v) {
    final l = _lots();
    final steps = (v / l.step).round();
    return double.parse((steps * l.step).clamp(l.min, l.max).toStringAsFixed(2));
  }

  double _defaultGap(double price, int digits) => double.parse((price * 0.002).toStringAsFixed(digits));

  double? _defaultEntry(OrderType t) {
    final q = _shownQuote();
    if (q == null) return null;
    final digits = _spec()?.digits ?? 5;
    final gap = _defaultGap(q.bid, digits);
    final v = switch (t) {
      OrderType.buyLimit => q.ask - gap,
      OrderType.sellLimit => q.bid + gap,
      OrderType.buyStop => q.ask + gap,
      _ => q.bid - gap,
    };
    return double.parse(v.toStringAsFixed(digits));
  }

  /// Pending-order icon: opens the panel with Buy Limit selected (its line is drawn
  /// on the chart straight away), or closes it when it is already open.
  void _togglePendingPanel() {
    if (_readonly) return _toastReadonly();
    if (_edit?.isDraft == true) {
      setState(() {
        _edit = null;
        _serverError = null;
      });
      return;
    }
    _startDraft(OrderType.buyLimit);
  }

  /// Choose (or switch) the pending type. The line appears / moves immediately.
  void _startDraft(OrderType type) {
    final entry = _defaultEntry(type);
    if (entry == null) {
      final tc = Theme.of(context).extension<TradeColors>()!;
      ToastHost.show('No live price', 'Waiting for a price on this symbol.', accent: tc.loss);
      return;
    }
    setState(() {
      _serverError = null;
      final e = _edit;
      if (e != null && e.isDraft) {
        // Keep the volume. SL / TP sit on opposite sides for buy vs sell, so reset them.
        e.draftType = type;
        e.side = type.api.startsWith('BUY') ? 'BUY' : 'SELL';
        e.entry = entry;
        e.sl = null;
        e.tp = null;
      } else {
        _edit = ChartEdit.draft(type: type, entry: entry, volume: _snapLot(_volume));
      }
    });
  }

  void _beginPositionEdit(Position p) {
    if (_readonly) return _toastReadonly();
    setState(() {
      _serverError = null;
      _edit = ChartEdit.position(id: p.id, side: p.side, entry: p.openPrice, sl: p.slPrice, tp: p.tpPrice);
    });
  }

  void _beginOrderEdit(PendingOrder o) {
    if (_readonly) return _toastReadonly();
    setState(() {
      _serverError = null;
      _edit = ChartEdit.order(
        id: o.id,
        orderType: o.type,
        side: o.side,
        entry: o.entry,
        sl: o.sl,
        tp: o.tp,
        volume: o.volume,
        hasStopField: o.hasStopField,
      );
    });
  }

  void _onLevelTap(ChartLevel l) {
    final id = l.id;
    if (id == null || _edit?.isDraft == true) return;
    if (l.kind == LevelKind.entry) {
      final p = (ref.read(openPositionsProvider).valueOrNull ?? const <Position>[]).where((x) => x.id == id);
      if (p.isNotEmpty) _beginPositionEdit(p.first);
    } else if (l.kind == LevelKind.pending) {
      final o = (ref.read(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[]).where((x) => x.id == id);
      if (o.isNotEmpty) _beginOrderEdit(o.first);
    }
  }

  void _onLevelDragEnd(ChartLevel l, double price) {
    if (_readonly) return _toastReadonly();
    FocusManager.instance.primaryFocus?.unfocus(); // let the panel fields show the dragged value
    final digits = _spec()?.digits ?? 5;
    final v = double.parse(price.toStringAsFixed(digits));
    final id = l.id ?? '';
    // A draft in progress is the main flow — never silently swap it for another target.
    if (_edit != null && _edit!.isDraft && _edit!.targetId != id) return;
    if (_edit == null || _edit!.targetId != id) {
      final pos = (ref.read(openPositionsProvider).valueOrNull ?? const <Position>[]).where((x) => x.id == id);
      final ord = (ref.read(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[]).where((x) => x.id == id);
      if (pos.isNotEmpty) {
        final p = pos.first;
        _edit = ChartEdit.position(id: p.id, side: p.side, entry: p.openPrice, sl: p.slPrice, tp: p.tpPrice);
      } else if (ord.isNotEmpty) {
        final o = ord.first;
        _edit = ChartEdit.order(id: o.id, orderType: o.type, side: o.side, entry: o.entry, sl: o.sl, tp: o.tp, volume: o.volume, hasStopField: o.hasStopField);
      }
    }
    final e = _edit;
    if (e == null || e.targetId != id) return;
    setState(() {
      _serverError = null;
      switch (l.kind) {
        case LevelKind.sl:
          e.sl = v;
        case LevelKind.tp:
          e.tp = v;
        case LevelKind.pending:
        case LevelKind.draft:
          e.entry = v;
        case LevelKind.entry:
          break;
      }
    });
  }

  /// "+" on the SL / TP field: drop a line at a sensible distance so it can be dragged.
  void _addProtective({required bool sl}) {
    final e = _edit;
    final q = _shownQuote();
    if (e == null) return;
    final digits = _spec()?.digits ?? 5;
    final base = e.entry ?? (q == null ? null : (e.isBuy ? q.ask : q.bid));
    if (base == null) return;
    final gap = _defaultGap(base, digits);
    final buy = e.isBuy;
    final v = sl ? (buy ? base - gap : base + gap) : (buy ? base + gap : base - gap);
    setState(() {
      final r = double.parse(v.toStringAsFixed(digits));
      if (sl) {
        e.sl = r;
      } else {
        e.tp = r;
      }
    });
  }

  Future<void> _apply() async {
    final e = _edit;
    if (e == null || _applying) return;
    if (_readonly) return _toastReadonly();
    final tc = Theme.of(context).extension<TradeColors>()!;
    final l = _lots();
    final errs = e.errors(_shownQuote(), minLot: l.min, maxLot: l.max, lotStep: l.step);
    if (errs.isNotEmpty) {
      ToastHost.show('Check the values', errs.values.first, accent: tc.loss);
      return;
    }
    setState(() {
      _applying = true;
      _serverError = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      if (e.isDraft) {
        final accountId = ref.read(activeAccountIdProvider);
        if (accountId == null) throw Exception('No account');
        final isStop = e.draftType == OrderType.buyStop || e.draftType == OrderType.sellStop;
        final req = PlaceOrderRequest(
          accountId: accountId,
          symbol: _symbol,
          side: e.side,
          type: e.draftType!,
          volume: e.volume!,
          price: e.entry,
          stopPrice: isStop ? e.entry : null,
          slPrice: e.sl,
          tpPrice: e.tp,
        );
        final res = await api.post('/orders', req.toJson());
        if (res['accepted'] != true) {
          SoundService.instance.error();
          if (mounted) setState(() => _serverError = '${res['reason'] ?? 'The order was rejected.'}');
          return;
        }
        SoundService.instance.orderPlaced('${res['orderId'] ?? ''}');
        ToastHost.show('${e.typeLabel} placed', '${e.volume!.toStringAsFixed(2)} @ ${e.entry}', accent: e.isBuy ? tc.buy : tc.sell);
      } else if (e.isPosition) {
        // null clears the value on the server (it is not "keep the old one").
        await api.patch('/positions/${e.id}', {'slPrice': e.sl, 'tpPrice': e.tp});
        ToastHost.show('Position updated', 'SL ${e.sl ?? '—'}  ·  TP ${e.tp ?? '—'}', accent: tc.profit);
      } else {
        await api.patch('/orders/${e.id}', {
          e.hasStopField ? 'stopPrice' : 'price': e.entry,
          'slPrice': e.sl,
          'tpPrice': e.tp,
          if (e.volume != null && e.volume != e.originalVolume) 'volume': e.volume,
        });
        ToastHost.show('Order updated', '@ ${e.entry}  ·  ${e.volume?.toStringAsFixed(2)} lots', accent: tc.profit);
      }
      ref.invalidate(openPositionsProvider);
      ref.invalidate(accountsProvider);
      ref.read(pendingOrdersProvider.notifier).reload();
      if (mounted) setState(() => _edit = null);
    } catch (err) {
      SoundService.instance.error();
      final msg = _errMessage(err);
      if (mounted) setState(() => _serverError = msg);
      ToastHost.show('Update failed', msg, accent: tc.loss);
      // The server is authoritative: reload so the chart shows what really exists.
      ref.invalidate(openPositionsProvider);
      ref.read(pendingOrdersProvider.notifier).reload();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _cancelPendingOrder() async {
    final e = _edit;
    if (e == null || !e.isOrder || _applying) return;
    final tc = Theme.of(context).extension<TradeColors>()!;
    setState(() {
      _applying = true;
      _serverError = null;
    });
    try {
      await ref.read(apiClientProvider).delete('/orders/${e.id}');
      ref.read(pendingOrdersProvider.notifier).removeLocal(e.id!);
      ToastHost.show('Order cancelled', e.typeLabel, accent: tc.profit);
      if (mounted) setState(() => _edit = null);
    } catch (err) {
      final msg = _errMessage(err);
      if (mounted) setState(() => _serverError = msg);
      ref.read(pendingOrdersProvider.notifier).reload();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  List<ChartLevel> _levels(List<Position> positions, List<PendingOrder> pendings, TradeColors tc, bool readonly) {
    final out = <ChartLevel>[];
    final edit = _edit;
    for (final p in positions.where((p) => p.symbol == _symbol)) {
      final editing = edit != null && edit.isPosition && edit.id == p.id;
      out.add(ChartLevel(p.openPrice, p.side == 'BUY' ? tc.buy : tc.sell, '${p.side} ${p.volume.toStringAsFixed(2)}',
          id: p.id, kind: LevelKind.entry, tappable: !readonly));
      final sl = editing ? edit.sl : p.slPrice;
      final tp = editing ? edit.tp : p.tpPrice;
      if (sl != null) out.add(ChartLevel(sl, tc.loss, 'SL', id: p.id, kind: LevelKind.sl, draggable: !readonly));
      if (tp != null) out.add(ChartLevel(tp, tc.profit, 'TP', id: p.id, kind: LevelKind.tp, draggable: !readonly));
    }
    for (final o in pendings.where((o) => o.symbol == _symbol)) {
      final editing = edit != null && edit.isOrder && edit.id == o.id;
      final entry = editing ? (edit.entry ?? o.entry) : o.entry;
      final sl = editing ? edit.sl : o.sl;
      final tp = editing ? edit.tp : o.tp;
      final label = editing ? '${edit.typeLabel} ${(edit.volume ?? o.volume).toStringAsFixed(2)}' : o.label;
      out.add(ChartLevel(entry, o.side == 'BUY' ? tc.buy : tc.sell, label,
          id: o.id, kind: LevelKind.pending, draggable: !readonly, tappable: !readonly));
      if (sl != null) out.add(ChartLevel(sl, tc.loss, 'SL', id: o.id, kind: LevelKind.sl, draggable: !readonly));
      if (tp != null) out.add(ChartLevel(tp, tc.profit, 'TP', id: o.id, kind: LevelKind.tp, draggable: !readonly));
    }
    if (edit != null && edit.isDraft) {
      out.add(ChartLevel(edit.entry ?? 0, edit.isBuy ? tc.buy : tc.sell, '${edit.typeLabel} ${(edit.volume ?? _volume).toStringAsFixed(2)}',
          id: 'draft', kind: LevelKind.draft, draggable: true, dashed: false));
      if (edit.sl != null) out.add(ChartLevel(edit.sl!, tc.loss, 'SL', id: 'draft', kind: LevelKind.sl, draggable: true));
      if (edit.tp != null) out.add(ChartLevel(edit.tp!, tc.profit, 'TP', id: 'draft', kind: LevelKind.tp, draggable: true));
    }
    return out;
  }

  void _onAnchor(DrawingAnchor a) {
    final tool = _activeTool;
    if (tool == null) return;
    final next = [..._pendingAnchors, a];
    if (next.length >= tool.anchorCount) {
      ref.read(chartDrawingsProvider.notifier).add(DrawingObject(
            id: '${tool.name}-${DateTime.now().microsecondsSinceEpoch}',
            symbol: _symbol,
            type: tool,
            anchors: next,
            colorArgb: tool.defaultColor,
          ));
      setState(() {
        _activeTool = null;
        _pendingAnchors = [];
      });
    } else {
      setState(() => _pendingAnchors = next);
    }
  }

  void _cancelDrawing() => setState(() {
        _activeTool = null;
        _pendingAnchors = [];
      });

  @override
  Widget build(BuildContext context) {
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    ref.watch(chartSymbolProvider);
    ref.listen<String>(chartSymbolProvider, (prev, next) {
      if (prev == next || next.isEmpty) return;
      setState(() => _edit = null); // an edit belongs to one symbol
      prefetchChartHistory(next, (req) => ref.read(candlesProvider(req).future));
    });
    // The order / position being edited was filled, cancelled or closed elsewhere:
    // close the panel instead of letting Apply fail against something that is gone.
    ref.listen<AsyncValue<List<PendingOrder>>>(pendingOrdersProvider, (_, next) {
      final e = _edit;
      final list = next.valueOrNull;
      if (e != null && e.isOrder && list != null && !list.any((o) => o.id == e.id)) {
        setState(() => _edit = null);
        ToastHost.show('Order no longer pending', e.typeLabel, accent: Theme.of(context).extension<TradeColors>()!.profit);
      }
    });
    ref.listen<AsyncValue<List<Position>>>(openPositionsProvider, (_, next) {
      final e = _edit;
      final list = next.valueOrNull;
      if (e != null && e.isPosition && list != null && !list.any((p) => p.id == e.id)) {
        setState(() => _edit = null);
      }
    });
    final readonly = ref.watch(tradingSessionProvider.select((s) => s.readonly));
    final selectedTf = ref.watch(chartTfProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final spec = symbols.where((s) => s.symbol == _symbol);
    final digits = spec.isEmpty ? 5 : spec.first.digits;
    final lotStep = spec.isEmpty ? 0.01 : spec.first.lotStep;
    final req = ChartReq(_symbol, selectedTf);
    final series = ref.watch(liveCandlesProvider(req));
    final indicatorCfgs = ref.watch(chartIndicatorsProvider);
    final activeIndicators = indicatorCfgs.where((c) => c.enabled).length;
    final drawings = ref.watch(chartDrawingsProvider).where((d) => d.symbol == _symbol).toList();
    final rawQuote = ref.watch(quotesProvider)[_symbol];
    final quote = rawQuote == null ? null : (spec.isEmpty ? rawQuote : spec.first.applyGroupMarkup(rawQuote));
    final forming = ref.watch(formingCandleProvider(req));
    final livePrice = forming?.c ?? rawQuote?.bid;
    final positions = ref.watch(openPositionsProvider).valueOrNull ?? const <Position>[];
    final pendings = ref.watch(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[];
    final tc = Theme.of(context).extension<TradeColors>()!;
    final levels = _levels(positions, pendings, tc, readonly);
    void stepLot(double by) => _setVolume(_volume + by, spec.isEmpty ? null : spec.first);
    final symbolValue = symbols.any((s) => s.symbol == _symbol) ? _symbol : null;

    Widget tool(IconData i, String tip, VoidCallback onTap, {Color? color}) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(i, color: color),
          onPressed: onTap,
        );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // Compact header — no app bar, so the chart starts right under it.
          SizedBox(
            height: 48,
            child: Row(children: [
              const SizedBox(width: 14),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: symbolValue,
                    hint: Text(spec.isEmpty ? _symbol : spec.first.displaySymbol, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                    style: TextStyle(fontSize: 17, color: Theme.of(context).colorScheme.onSurface),
                    items: [for (final s in symbols) DropdownMenuItem(value: s.symbol, child: Text(s.displaySymbol, overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _symbol = v ?? _symbol),
                  ),
                ),
              ),
              DropdownButtonHideUnderline(
                child: DropdownButton<Timeframe>(
                  value: selectedTf,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
                  items: [for (final tf in Timeframe.values) DropdownMenuItem(value: tf, child: Text(tf.label))],
                  onChanged: (tf) {
                    if (tf != null) ref.read(chartTfProvider.notifier).set(tf);
                  },
                ),
              ),
              tool(_type == ChartType.candles ? Icons.show_chart : Icons.candlestick_chart, _type == ChartType.candles ? 'Line chart' : 'Candlestick chart',
                  () => setState(() => _type = _type == ChartType.candles ? ChartType.line : ChartType.candles)),
              IconButton(
                tooltip: 'Indicators',
                visualDensity: VisualDensity.compact,
                icon: Badge(isLabelVisible: activeIndicators > 0, label: Text('$activeIndicators'), child: const Icon(Icons.insights_outlined)),
                onPressed: () => showIndicatorsSheet(context),
              ),
              tool(Icons.timeline, 'Draw', () => showDrawingsSheet(
                    context,
                    symbol: _symbol,
                    digits: digits,
                    onSelectTool: (t) => setState(() {
                      _activeTool = t;
                      _pendingAnchors = [];
                    }),
                  ), color: _activeTool != null ? Theme.of(context).colorScheme.primary : null),
              tool(Icons.assignment_outlined, 'Pending order', _togglePendingPanel, color: _edit?.isDraft == true ? Theme.of(context).colorScheme.primary : null),
              const SizedBox(width: 4),
            ]),
          ),
          const ActiveAccountBar(compact: true, onlyWhenSpecial: true),
          Expanded(
            child: series.when(
              loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, _) => Center(child: Text('Chart unavailable\n$e', textAlign: TextAlign.center)),
              data: (candles) {
                if (candles.isEmpty) return const Center(child: Text('No data for this symbol yet.'));
                final overlays = <ComputedIndicator>[];
                final oscillators = <ComputedIndicator>[];
                for (final cfg in indicatorCfgs) {
                  if (!cfg.enabled) continue;
                  final ind = computeIndicator(cfg, candles).withLabel(cfg.summary);
                  (ind.isOverlay ? overlays : oscillators).add(ind);
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    padding: const EdgeInsets.fromLTRB(6, 2, 4, 4),
                    child: Stack(children: [
                      CandleChart(
                        candles: candles,
                        digits: digits,
                        tf: selectedTf,
                        livePrice: livePrice,
                        type: _type,
                        levels: levels,
                        overlays: overlays,
                        oscillators: oscillators,
                        drawings: drawings,
                        activeTool: _activeTool,
                        pendingAnchors: _pendingAnchors,
                        onAnchor: _onAnchor,
                        onMoveAnchor: (id, i, a) => ref.read(chartDrawingsProvider.notifier).updateAnchor(id, i, a),
                        onDeleteDrawing: (id) => ref.read(chartDrawingsProvider.notifier).remove(id),
                        onLevelDragEnd: _onLevelDragEnd,
                        onLevelTap: _onLevelTap,
                      ),
                      Positioned(top: 6, right: 70, child: _BarCountdown(selectedTf)),
                      if (_activeTool != null)
                        Positioned(
                          top: 40,
                          left: 6,
                          child: Material(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text('Tap to place ${_activeTool!.shortLabel}  ${_pendingAnchors.length}/${_activeTool!.anchorCount}',
                                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                InkWell(onTap: _cancelDrawing, child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 15, color: Colors.white))),
                              ]),
                            ),
                          ),
                        ),
                    ]),
                  ),
                );
              },
            ),
          ),
          if (_edit != null)
            SafeArea(
              top: false,
              child: PendingPanel(
                edit: _edit!,
                symbolLabel: spec.isEmpty ? _symbol : spec.first.displaySymbol,
                digits: digits,
                quote: quote,
                minLot: _lots().min,
                maxLot: _lots().max,
                lotStep: _lots().step,
                busy: _applying,
                serverError: _serverError,
                onChanged: () => setState(() => _serverError = null),
                onPickType: _startDraft,
                onAddSl: () => _addProtective(sl: true),
                onAddTp: () => _addProtective(sl: false),
                onApply: _apply,
                onClose: () => setState(() {
                  _edit = null;
                  _serverError = null;
                }),
                onCancelOrder: _cancelPendingOrder,
              ),
            )
          else
          // SELL / lots / BUY. Bid and Ask are shown here (and only here).
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: Row(children: [
                Expanded(
                  child: _DealCard(
                    label: 'SELL',
                    price: quote?.bid,
                    digits: digits,
                    base: tc.sell,
                    up: tc.up,
                    down: tc.down,
                    enabled: !_placing && quote != null,
                    locked: readonly,
                    onTap: () => _placeMarket('SELL'),
                  ),
                ),
                Container(
                  width: 120,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    _StepIcon(icon: Icons.remove, onTap: () => stepLot(-lotStep)),
                    Expanded(
                      child: TextField(
                        controller: _volCtrl,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, fontFeatures: [FontFeature.tabularFigures()]),
                        decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero, filled: false),
                        onChanged: (v) {
                          final d = double.tryParse(v);
                          if (d != null) setState(() => _volume = d);
                        },
                        onEditingComplete: () {
                          _setVolume(_volume, spec.isEmpty ? null : spec.first);
                          FocusScope.of(context).unfocus();
                        },
                      ),
                    ),
                    _StepIcon(icon: Icons.add, onTap: () => stepLot(lotStep)),
                  ]),
                ),
                Expanded(
                  child: _DealCard(
                    label: 'BUY',
                    price: quote?.ask,
                    digits: digits,
                    base: tc.buy,
                    up: tc.up,
                    down: tc.down,
                    enabled: !_placing && quote != null,
                    locked: readonly,
                    onTap: () => _placeMarket('BUY'),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Counts down the time remaining on the current forming bar.
class _BarCountdown extends StatefulWidget {
  const _BarCountdown(this.tf);
  final Timeframe tf;
  @override
  State<_BarCountdown> createState() => _BarCountdownState();
}

class _BarCountdownState extends State<_BarCountdown> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String _fmt(int s) {
    if (s >= 86400) return '${s ~/ 86400}d${((s % 86400) ~/ 3600).toString().padLeft(2, '0')}h';
    if (s >= 3600) return '${s ~/ 3600}h${((s % 3600) ~/ 60).toString().padLeft(2, '0')}';
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = widget.tf.nextBucketStart(now) - now;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.timer_outlined, size: 12, color: Theme.of(context).hintColor),
        const SizedBox(width: 4),
        Text(_fmt(remaining),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

/// SELL / BUY panel. The whole panel takes its colour from the direction of the
/// latest tick on that side — blue when it moved up, red when it moved down — and
/// settles back to its normal colour shortly after (MT5-style).
class _DealCard extends StatefulWidget {
  const _DealCard({
    required this.label,
    required this.price,
    required this.digits,
    required this.base,
    required this.up,
    required this.down,
    required this.enabled,
    required this.locked,
    required this.onTap,
  });
  final String label;
  final double? price;
  final int digits;
  final Color base; // side identity (red SELL / blue BUY) for label + border
  final Color up; // price moved up
  final Color down; // price moved down
  final bool enabled;
  final bool locked; // investor / read-only
  final VoidCallback onTap;

  @override
  State<_DealCard> createState() => _DealCardState();
}

class _DealCardState extends State<_DealCard> {
  Color? _flash;
  Timer? _revert;

  @override
  void didUpdateWidget(covariant _DealCard old) {
    super.didUpdateWidget(old);
    final o = old.price, n = widget.price;
    if (o == null || n == null || n == o) return;
    // Ignore symbol switches / feed restarts (a jump that big is not a tick).
    if (o > 0 && (n - o).abs() / o >= 0.05) return;
    _flash = n > o ? widget.up : widget.down;
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !widget.locked;
    // MT5 style: the whole panel takes the colour of the latest tick on this side
    // (blue = moved up, red = moved down), white text. It settles back to the
    // side's normal colour (SELL red / BUY blue) after a moment.
    final fill = _flash ?? widget.base;
    return Opacity(
      opacity: active || widget.locked ? 1 : 0.6,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: active ? widget.onTap : (widget.locked ? widget.onTap : null),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.6)),
              Text(
                widget.price == null ? '—' : widget.price!.toStringAsFixed(widget.digits),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, size: 18)),
      );
}
