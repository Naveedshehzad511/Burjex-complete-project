// import 'dart:math' as math; // needed again when the SL/TP "points" text is restored
import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sound_service.dart';
import '../session/sessions.dart';
import '../state/chart_trade.dart';
import '../state/pending_orders.dart';
import '../widgets/big_figure_price.dart';
import '../widgets/candle_chart.dart';
import '../widgets/drawings_sheet.dart';
import '../widgets/indicators_sheet.dart';
import '../widgets/manage_accounts.dart';
import '../widgets/pending_panel.dart';
import '../widgets/portal_drawer.dart';
import '../widgets/trade_toast.dart';

/// Pull a human-readable message out of a Dio/API error (e.g. "market closed").
String _errMessage(Object e) {
  try {
    final d = (e as dynamic).response?.data;
    if (d is Map) {
      final m = d['message'] ??
          (d['error'] is Map ? d['error']['message'] : d['error']);
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

  // ── MT5-style chart-window management (Duplicate / Tile) ──────────────────
  // Window 0 is always the primary chart above (driven by the existing
  // chartSymbolProvider / chartTfProvider, with full trading). At most one
  // extra, view-only chart window is supported today — its own symbol,
  // timeframe, candles, zoom/pan/crosshair (via its own CandleChart instance)
  // and drawings, but it does not place trades itself.
  static const int _kMaxChartWindows = 2;
  final List<_ExtraChartWindow> _extraWindows = [];
  Axis? _tileAxis; // null while only one window is shown
  int _chartsMenuSelection = 0; // which window the Charts sheet's radio targets
  DrawingType? _activeTool2;
  List<DrawingAnchor> _pendingAnchors2 = [];
  // Volume lives in chartTradeProvider (one value for SELL / BUY and new orders).
  double get _volume => ref.read(chartTradeProvider).volume;
  late final TextEditingController _volCtrl = TextEditingController(
      text: ref.read(chartTradeProvider).volume.toStringAsFixed(2));
  final _volFocus = FocusNode();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Chart interaction tools (header). Screen-local: they only steer the chart.
  bool _crosshair = false;
  bool _tfStripOpen = false;
  bool _applying = false;
  ChartEdit? _edit;

  /// Collapsed (default) vs expanded order panel — screen-local UI state, exactly
  /// like the flags above; the order data itself always lives in [_edit].
  bool _panelExpanded = false;
  String? _serverError; // last server rejection, shown inside the panel

  // Session-boundary clock: nothing here depends on the network, so this just
  // forces a rebuild often enough that "market closed → open" (or the
  // reverse) flips the BUY/SELL buttons on its own, with no refresh needed.
  Timer? _sessionClock;

  // Memoized indicator recompute — see `_computeIndicatorsMemoized`. Two slots
  // so the (view-only) second chart window's recompute never thrashes the
  // primary window's cache — each holds a different symbol/timeframe series.
  _IndicatorCacheEntry? _indicatorCache;
  _IndicatorCacheEntry? _indicatorCache2;

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
    _sessionClock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _volCtrl.dispose();
    _volFocus.dispose();
    _sessionClock?.cancel();
    super.dispose();
  }

  /// Whether the current symbol's market is open right now, per its actual
  /// admin-configured session (or the CRYPTO/forex-week default) — never a
  /// hardcoded per-symbol assumption. `true` while the symbol spec hasn't
  /// loaded yet, so the buttons don't flash disabled before data arrives.
  bool _tradableNow(TradeSymbol? spec) {
    if (spec == null) return true;
    return isSymbolTradableNow(spec, DateTime.now().toUtc());
  }

  /// `computeIndicator` runs over the WHOLE candle series (up to thousands of
  /// bars) and this build method used to call it, for every enabled
  /// indicator, on every rebuild — including one triggered by nothing more
  /// than the still-forming candle's close ticking. Recomputed:
  ///  - immediately when the indicator set/params/enabled state changed
  ///    (the user just edited something — must reflect it at once),
  ///  - immediately when a new bar closed (`candles.length` grew — the
  ///    indicator needs a value for the new bar),
  ///  - otherwise at most once per [_kIndicatorThrottle] while only the live
  ///    tip's price is moving — indicator lines still track the forming bar,
  ///    just not on literally every one of several ticks a second.
  /// Never changes what value is computed, only how often — the indicator
  /// math itself is untouched.
  static const _kIndicatorThrottle = Duration(milliseconds: 200);

  _IndicatorBundle _computeIndicatorsMemoized(
          List<Candle> candles, List<IndicatorConfig> cfgs) =>
      _computeIndicatorsCached(
          candles, cfgs, _indicatorCache, (e) => _indicatorCache = e);

  /// Second window's variant of the memoized recompute above — same logic,
  /// its own cache slot (see [_indicatorCache2]).
  _IndicatorBundle _computeIndicatorsMemoized2(
          List<Candle> candles, List<IndicatorConfig> cfgs) =>
      _computeIndicatorsCached(
          candles, cfgs, _indicatorCache2, (e) => _indicatorCache2 = e);

  _IndicatorBundle _computeIndicatorsCached(
    List<Candle> candles,
    List<IndicatorConfig> cfgs,
    _IndicatorCacheEntry? cache,
    void Function(_IndicatorCacheEntry) store,
  ) {
    final enabled = cfgs.where((c) => c.enabled).toList();
    final sig = enabled
        .map((c) =>
            '${c.id}:${c.type.name}:${c.source.name}:${c.params}:${c.colors}')
        .join('|');
    final sameShape =
        cache != null && cache.sig == sig && cache.len == candles.length;
    final dueForTipRefresh = cache == null ||
        DateTime.now().difference(cache.at) >= _kIndicatorThrottle;
    if (cache != null && sameShape && !dueForTipRefresh) return cache.bundle;

    final overlays = <ComputedIndicator>[];
    final oscillators = <ComputedIndicator>[];
    for (final cfg in enabled) {
      final ind = computeIndicator(cfg, candles).withLabel(cfg.summary);
      (ind.isOverlay ? overlays : oscillators).add(ind);
    }
    final bundle = _IndicatorBundle(overlays, oscillators);
    store(_IndicatorCacheEntry(
        sig: sig, len: candles.length, at: DateTime.now(), bundle: bundle));
    return bundle;
  }

  void _setVolume(double v, TradeSymbol? spec) {
    final mn = spec?.minLot ?? 0.01, mx = spec?.maxLot ?? 100;
    final clamped = double.parse(v.clamp(mn, mx).toStringAsFixed(2));
    ref.read(chartTradeProvider.notifier).setVolume(clamped);
    final e = _edit;
    if (e != null && e.isDraft)
      setState(() => e.volume = clamped); // same value everywhere
    _syncVolField(clamped, force: true);
  }

  void _syncVolField(double v, {bool force = false}) {
    if (_volFocus.hasFocus && !force) return;
    final t = v.toStringAsFixed(2);
    if (_volCtrl.text == t) return;
    _volCtrl.text = t;
    _volCtrl.selection = TextSelection.collapsed(offset: t.length);
  }

  TradeSymbol? _spec() {
    final symbols =
        ref.read(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
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
    ToastHost.show('Read-only account',
        'Signed in with the investor password — trading is disabled.',
        accent: tc.loss);
  }

  // ── Market order (one click) ──────────────────────────────────────────────

  Future<void> _placeMarket(String side) async {
    if (_readonly) return _toastReadonly();
    final accountId = ref.read(activeAccountIdProvider);
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (accountId == null) {
      ToastHost.show('No account', 'Select a trading account first',
          accent: tc.loss);
      return;
    }
    if (!_tradableNow(_spec())) {
      ToastHost.show('Market closed', 'This symbol is not tradable right now.',
          accent: tc.loss);
      return;
    }
    final q = _shownQuote();
    if (q == null) return;
    final sym = _symbol;
    final vol = _volume;
    final px = side == 'BUY' ? q.ask : q.bid;
    // Market mode open in the order panel: its SL / TP go with the order.
    final m = _edit != null && _edit!.isMarket ? _edit : null;
    final sl = m?.sl, tp = m?.tp;
    if (m != null) {
      final err = _marketProtectiveError(side, q, sl, tp);
      if (err != null) {
        ToastHost.show('Check SL / TP', err, accent: tc.loss);
        return;
      }
    }
    // Not a lock: every click is its own request and the buttons stay usable, so a burst of
    // clicks becomes a burst of independent orders (each with its own clientOrderId).
    try {
      final req = PlaceOrderRequest(
        accountId: accountId,
        symbol: sym,
        side: side,
        type: OrderType.market,
        volume: vol,
        oneClick: m == null,
        price: px,
        slPrice: sl,
        tpPrice: tp,
      );
      final res =
          await ref.read(apiClientProvider).post('/orders', req.toJson());
      if (res['accepted'] == true) {
        // Feedback first — the instant the server confirms — then refresh state.
        SoundService.instance.orderPlaced('${res['orderId'] ?? ''}');
        // The backend has confirmed this fill: show it now, then reconcile with the server
        // (one coalesced refetch for a whole burst, not one restart per order).
        ref.read(openPositionsProvider.notifier).addConfirmedFill(
              res,
              accountId: accountId,
              symbol: sym,
              digits: _spec()?.digits ?? 5,
              side: side,
              volume: vol,
              slPrice: sl,
              tpPrice: tp,
            );
        ref.read(accountsRefreshProvider).request();
        ref.read(positionsRefreshProvider).request();
        // Chart BUY / SELL confirms by sound only (no popup) — the filled line and
        // P/L label on the chart are the visual confirmation. Errors below still toast.
        // Like MT5: the market order window closes once the trade is done.
        if (m != null && identical(_edit, m) && mounted)
          setState(() => _edit = null);
      } else {
        SoundService.instance.error();
        ToastHost.show('Order rejected', '${res['reason'] ?? ''}',
            accent: tc.loss);
      }
    } catch (e) {
      SoundService.instance.error();
      ToastHost.show('Order failed', _errMessage(e), accent: tc.loss);
    }
  }

  // ── Pending orders and SL / TP editing (one panel for all of it) ──────────

  ({double min, double max, double step}) _lots() {
    final sp = _spec();
    return (
      min: sp?.minLot ?? 0.01,
      max: sp?.maxLot ?? 100.0,
      step: sp?.lotStep ?? 0.01
    );
  }

  double _snapLot(double v) {
    final l = _lots();
    final steps = (v / l.step).round();
    return double.parse(
        (steps * l.step).clamp(l.min, l.max).toStringAsFixed(2));
  }

  double _defaultGap(double price, int digits) =>
      double.parse((price * 0.002).toStringAsFixed(digits));

  /// Market SL / TP are judged against the side's closing price, as the engine does:
  /// a buy closes at the Bid (SL below, TP above), a sell at the Ask.
  String? _marketProtectiveError(String side, Tick q, double? sl, double? tp) {
    final buy = side == 'BUY';
    final px = buy ? q.bid : q.ask;
    if (sl != null && (buy ? sl >= px : sl <= px))
      return 'Stop loss must be ${buy ? 'below the Bid' : 'above the Ask'} for a $side';
    if (tp != null && (buy ? tp <= px : tp >= px))
      return 'Take profit must be ${buy ? 'above the Bid' : 'below the Ask'} for a $side';
    return null;
  }

  /// Default prices for a new order: entry (the stop trigger for a Stop Limit) and,
  /// for a Stop Limit, the limit half a gap back towards the market.
  ({double entry, double? limit})? _defaultPrices(OrderMode m) {
    final q = _shownQuote();
    if (q == null) return null;
    final digits = _spec()?.digits ?? 5;
    final gap = _defaultGap(q.bid, digits);
    double r(double v) => double.parse(v.toStringAsFixed(digits));
    return switch (m) {
      OrderMode.buyLimit => (entry: r(q.ask - gap), limit: null),
      OrderMode.sellLimit => (entry: r(q.bid + gap), limit: null),
      OrderMode.buyStop => (entry: r(q.ask + gap), limit: null),
      OrderMode.sellStop => (entry: r(q.bid - gap), limit: null),
      OrderMode.buyStopLimit => (
          entry: r(q.ask + gap),
          limit: r(q.ask + gap / 2)
        ),
      OrderMode.sellStopLimit => (
          entry: r(q.bid - gap),
          limit: r(q.bid - gap / 2)
        ),
      OrderMode.market => (entry: 0.0, limit: null),
    };
  }

  /// Order-mode icon (MT5's order tool): opens the order panel on the last-used
  /// mode, or closes it when a new order is already open.
  void _toggleOrderPanel() {
    if (_readonly) return _toastReadonly();
    if (_edit?.isDraft == true) {
      setState(() {
        _edit = null;
        _serverError = null;
      });
      return;
    }
    _startDraft(ref.read(chartTradeProvider).mode);
  }

  /// Choose (or switch) the order mode. A pending line (two for a Stop Limit)
  /// appears / moves on the chart immediately.
  void _startDraft(OrderMode mode) {
    final prices = _defaultPrices(mode);
    if (prices == null && !mode.isMarket) {
      final tc = Theme.of(context).extension<TradeColors>()!;
      ToastHost.show('No live price', 'Waiting for a price on this symbol.',
          accent: tc.loss);
      return;
    }
    ref.read(chartTradeProvider.notifier).setMode(mode);
    setState(() {
      _serverError = null;
      final e = _edit;
      if (e != null && e.isDraft) {
        // Keep the volume. SL / TP sit on opposite sides for buy vs sell, so reset them.
        e.draftType = mode.type;
        e.side = mode.side;
        e.entry = mode.isMarket ? null : prices!.entry;
        e.limit = prices?.limit;
        e.sl = null;
        e.tp = null;
      } else {
        _panelExpanded =
            false; // a brand-new order/target always starts collapsed
        _edit = ChartEdit.draft(
          type: mode.type,
          side: mode.side,
          entry: mode.isMarket ? null : prices!.entry,
          limit: prices?.limit,
          volume: _snapLot(_volume),
        );
      }
    });
  }

  void _beginPositionEdit(Position p) {
    if (_readonly) return _toastReadonly();
    setState(() {
      _serverError = null;
      _panelExpanded = false;
      _edit = ChartEdit.position(
          id: p.id,
          side: p.side,
          entry: p.openPrice,
          sl: p.slPrice,
          tp: p.tpPrice);
    });
  }

  void _beginOrderEdit(PendingOrder o) {
    if (_readonly) return _toastReadonly();
    setState(() {
      _serverError = null;
      _panelExpanded = false;
      _edit = ChartEdit.order(
        id: o.id,
        orderType: o.type,
        side: o.side,
        entry: o.entry,
        sl: o.sl,
        tp: o.tp,
        volume: o.volume,
        hasStopField: o.hasStopField,
        limit: o.limit,
      );
    });
  }

  void _onLevelTap(ChartLevel l) {
    final id = l.id;
    if (id == null || _edit?.isDraft == true) return;
    if (l.kind == LevelKind.entry) {
      final p =
          (ref.read(openPositionsProvider).valueOrNull ?? const <Position>[])
              .where((x) => x.id == id);
      if (p.isNotEmpty) _beginPositionEdit(p.first);
    } else if (l.kind == LevelKind.sl || l.kind == LevelKind.tp) {
      // A protective line is plain until tapped; tapping opens its owner's editor,
      // which is what makes the drag handle appear (see `_levels`).
      final p = (ref.read(openPositionsProvider).valueOrNull ?? const <Position>[]).where((x) => x.id == id);
      if (p.isNotEmpty) return _beginPositionEdit(p.first);
      final o = (ref.read(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[]).where((x) => x.id == id);
      if (o.isNotEmpty) _beginOrderEdit(o.first);
    } else if (l.kind == LevelKind.pending || l.kind == LevelKind.limit) {
      final o = (ref.read(pendingOrdersProvider).valueOrNull ??
              const <PendingOrder>[])
          .where((x) => x.id == id);
      if (o.isNotEmpty) _beginOrderEdit(o.first);
    }
  }

  void _onLevelDragEnd(ChartLevel l, double price) {
    if (_readonly) return _toastReadonly();
    FocusManager.instance.primaryFocus
        ?.unfocus(); // let the panel fields show the dragged value
    final digits = _spec()?.digits ?? 5;
    final v = double.parse(price.toStringAsFixed(digits));
    final id = l.id ?? '';
    // A draft in progress is the main flow — never silently swap it for another target.
    if (_edit != null && _edit!.isDraft && _edit!.targetId != id) return;
    if (_edit == null || _edit!.targetId != id) {
      final pos =
          (ref.read(openPositionsProvider).valueOrNull ?? const <Position>[])
              .where((x) => x.id == id);
      final ord = (ref.read(pendingOrdersProvider).valueOrNull ??
              const <PendingOrder>[])
          .where((x) => x.id == id);
      if (pos.isNotEmpty) {
        final p = pos.first;
        _panelExpanded = false;
        _edit = ChartEdit.position(
            id: p.id,
            side: p.side,
            entry: p.openPrice,
            sl: p.slPrice,
            tp: p.tpPrice);
      } else if (ord.isNotEmpty) {
        final o = ord.first;
        _panelExpanded = false;
        _edit = ChartEdit.order(
            id: o.id,
            orderType: o.type,
            side: o.side,
            entry: o.entry,
            sl: o.sl,
            tp: o.tp,
            volume: o.volume,
            hasStopField: o.hasStopField,
            limit: o.limit);
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
        case LevelKind.limit:
          e.limit = v;
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
    // A market order has no entry yet: start from the Bid (lines default to the buy side).
    final base = e.protectiveRef ??
        (q == null ? null : (e.isMarket ? q.bid : (e.isBuy ? q.ask : q.bid)));
    if (base == null) return;
    final gap = _defaultGap(base, digits);
    final buy = e.isBuy;
    final v =
        sl ? (buy ? base - gap : base + gap) : (buy ? base + gap : base - gap);
    _setProtective(sl: sl, value: double.parse(v.toStringAsFixed(digits)));
  }

  /// SL / TP toggle, "set" half is [_addProtective]; this is the "remove" half.
  void _removeProtective({required bool sl}) => _setProtective(sl: sl, value: null);

  /// True while an SL / TP change on an existing order / position is being saved.
  bool _protectiveSaving = false;

  /// Set ([value]) or remove (null) the SL or TP of the order panel's target.
  ///
  /// The panel and chart line update at once. A NEW order has nothing on the server yet, so the
  /// level simply goes with the placement. For an EXISTING order / position the change is saved
  /// right away (only that field is sent, the other level and the price are untouched); if the
  /// backend rejects it, the previous value is restored and the reason is shown, so the panel
  /// never claims a level the server does not have.
  Future<void> _setProtective({required bool sl, required double? value}) async {
    final e = _edit;
    if (e == null || _protectiveSaving) return;
    final before = sl ? e.sl : e.tp;
    void put(double? v) {
      if (sl) {
        e.sl = v;
      } else {
        e.tp = v;
      }
    }

    setState(() {
      put(value);
      _serverError = null;
    });
    if (e.isDraft) return;
    final tc = Theme.of(context).extension<TradeColors>()!;
    if (_readonly) {
      setState(() => put(before));
      return _toastReadonly();
    }
    final key = sl ? 'slPrice' : 'tpPrice';
    _protectiveSaving = true;
    try {
      final api = ref.read(apiClientProvider);
      await (e.isPosition
          ? api.patch('/positions/${e.id}', {key: value})
          : api.patch('/orders/${e.id}', {key: value}));
      SoundService.instance.orderModified();
      ref.invalidate(openPositionsProvider);
      ref.read(pendingOrdersProvider.notifier).reload();
    } catch (err) {
      SoundService.instance.error();
      final msg = _errMessage(err);
      if (mounted && identical(_edit, e)) {
        setState(() {
          put(before);
          _serverError = msg;
        });
      }
      ToastHost.show(value == null ? 'Could not remove ${sl ? 'SL' : 'TP'}' : 'Could not set ${sl ? 'SL' : 'TP'}', msg, accent: tc.loss);
    } finally {
      _protectiveSaving = false;
    }
  }

  Future<void> _apply() async {
    final e = _edit;
    if (e == null || _applying) return;
    if (_readonly) return _toastReadonly();
    final tc = Theme.of(context).extension<TradeColors>()!;
    final l = _lots();
    final errs =
        e.errors(_shownQuote(), minLot: l.min, maxLot: l.max, lotStep: l.step);
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
        final isStop = e.draftType == OrderType.buyStop ||
            e.draftType == OrderType.sellStop;
        // Stop Limit: stopPrice = trigger, price = limit (fill); the engine checks both.
        final req = PlaceOrderRequest(
          accountId: accountId,
          symbol: _symbol,
          side: e.side,
          type: e.draftType!,
          volume: e.volume!,
          price: e.isStopLimit ? e.limit : e.entry,
          stopPrice: isStop || e.isStopLimit ? e.entry : null,
          slPrice: e.sl,
          tpPrice: e.tp,
          timeInForce: e.timeInForce,
          expiresAt: e.expiresAt,
        );
        final res = await api.post('/orders', req.toJson());
        if (res['accepted'] != true) {
          SoundService.instance.error();
          if (mounted)
            setState(() =>
                _serverError = '${res['reason'] ?? 'The order was rejected.'}');
          return;
        }
        SoundService.instance.orderPlaced('${res['orderId'] ?? ''}');
        ToastHost.show('${e.typeLabel} placed',
            '${e.volume!.toStringAsFixed(2)} @ ${e.entry}',
            accent: e.isBuy ? tc.buy : tc.sell);
      } else if (e.isPosition) {
        // null clears the value on the server (it is not "keep the old one").
        await api
            .patch('/positions/${e.id}', {'slPrice': e.sl, 'tpPrice': e.tp});
        SoundService.instance.orderModified();
        ToastHost.show(
            'Position updated', 'SL ${e.sl ?? '—'}  ·  TP ${e.tp ?? '—'}',
            accent: tc.profit);
      } else {
        await api.patch('/orders/${e.id}', {
          if (e.isStopLimit) ...{'stopPrice': e.entry, 'price': e.limit} else
            e.hasStopField ? 'stopPrice' : 'price': e.entry,
          'slPrice': e.sl,
          'tpPrice': e.tp,
          if (e.volume != null && e.volume != e.originalVolume)
            'volume': e.volume,
        });
        SoundService.instance.orderModified();
        ToastHost.show('Order updated',
            '@ ${e.entry}  ·  ${e.volume?.toStringAsFixed(2)} lots',
            accent: tc.profit);
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
      SoundService.instance.orderCancelled();
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

  /// MT5's protective-level label: `SL, -1 477.20 USD, -4924 points` — the profit or
  /// loss the trade would book if price reaches [px], and the distance from [ref]
  /// (entry / open price) in points. Computed from the real symbol spec (contract
  /// size, digits) and account currency; nothing is fixed.
  String _protLabel(String tag, String side, double vol, double ref, double px, String sym, List<TradeSymbol> symbols) {
    TradeSymbol? spec;
    for (final s in symbols) {
      if (s.symbol == sym) spec = s;
    }
    final cs = spec?.contractSize ?? 100000.0;
    // final digits = spec?.digits ?? 5; // only needed for points
    final dir = side.toUpperCase() == 'BUY' ? 1.0 : -1.0;
    final pl = (px - ref) * dir * vol * cs;
    // final pts = ((px - ref) * dir / math.pow(10, -digits)).round();
    final cur = _accountCurrency() ?? 'USD';
    // Points are hidden for now; restore by appending `, ${pts >= 0 ? '+' : ''}$pts points`.
    // return '$tag, ${pl >= 0 ? '+' : '-'}${money(pl.abs())} $cur, ${pts >= 0 ? '+' : ''}$pts points';
    return '$tag, ${pl >= 0 ? '+' : '-'}${money(pl.abs())} $cur';
  }

  /// Currency of the active trading account, when known.
  String? _accountCurrency() {
    final id = ref.read(activeAccountIdProvider);
    for (final a in ref.read(accountsProvider).valueOrNull ?? const <Account>[]) {
      if (a.id == id) return a.currency;
    }
    return null;
  }

  /// [symbol] defaults to the primary chart's symbol; [includeDraft] is false
  /// for the second (view-only) window, since a draft order belongs only to
  /// the primary chart it was started from.
  List<ChartLevel> _levels(List<Position> positions,
      List<PendingOrder> pendings, TradeColors tc, bool readonly,
      {String? symbol,
      bool includeDraft = true,
      Map<String, double> livePl = const {},
      Map<String, Tick> quotes = const {},
      List<TradeSymbol> symbols = const []}) {
    final sym = symbol ?? _symbol;
    final out = <ChartLevel>[];
    final edit = _edit;
    for (final p in positions.where((p) => p.symbol == sym)) {
      final editing = edit != null && edit.isPosition && edit.id == p.id;
      // MT5 inline label: "BUY 0.68, +1.50 USD" — P/L from the same live source
      // as the Trade tab (engine push first, else the live quote).
      final pl = resolvePositionPl(p, livePl: livePl, quotes: quotes, symbols: symbols);
      // Profit blue, loss red, exactly zero the neutral text colour (judged on the 2 decimals shown).
      final plShown = double.parse(pl.toStringAsFixed(2));
      final plColor = plShown > 0
          ? tc.profit
          : plShown < 0
              ? tc.loss
              : Theme.of(context).colorScheme.onSurface;
      out.add(ChartLevel(p.openPrice, p.side == 'BUY' ? tc.buy : tc.sell,
          '${p.side} ${p.volume.toStringAsFixed(2)}, ${pl >= 0 ? '+' : '-'}${pl.abs().toStringAsFixed(2)} ${_accountCurrency() ?? 'USD'}',
          id: p.id, kind: LevelKind.entry, tappable: !readonly, boxed: false, plColor: plColor));
      final sl = editing ? edit.sl : p.slPrice;
      final tp = editing ? edit.tp : p.tpPrice;
      if (sl != null)
        out.add(ChartLevel(sl, tc.loss,
            _protLabel('SL', p.side, p.volume, p.openPrice, sl, sym, symbols),
            id: p.id,
            kind: LevelKind.sl,
            draggable: !readonly && editing,
            tappable: !readonly,
            labelFor: (px) => _protLabel('SL', p.side, p.volume, p.openPrice, px, sym, symbols)));
      if (tp != null)
        out.add(ChartLevel(tp, tc.profit,
            _protLabel('TP', p.side, p.volume, p.openPrice, tp, sym, symbols),
            id: p.id,
            kind: LevelKind.tp,
            draggable: !readonly && editing,
            tappable: !readonly,
            labelFor: (px) => _protLabel('TP', p.side, p.volume, p.openPrice, px, sym, symbols)));
    }
    for (final o in pendings.where((o) => o.symbol == sym)) {
      // MT5: a resting order is a plain line + label until tapped; only then does it
      // get the drag handle (draggable) and the edit panel.
      final editing = edit != null && edit.isOrder && edit.id == o.id;
      final entry = editing ? (edit.entry ?? o.entry) : o.entry;
      final sl = editing ? edit.sl : o.sl;
      final tp = editing ? edit.tp : o.tp;
      final label = (editing
              ? '${edit.typeLabel} ${(edit.volume ?? o.volume).toStringAsFixed(2)}'
              : o.label)
          .toUpperCase();
      out.add(ChartLevel(entry, o.side == 'BUY' ? tc.buy : tc.sell,
          o.isStopLimit ? '$label · Stop' : label,
          id: o.id,
          kind: LevelKind.pending,
          draggable: !readonly && editing,
          tappable: !readonly));
      final limit = editing ? edit.limit : o.limit;
      if (o.isStopLimit && limit != null) {
        out.add(ChartLevel(limit, o.side == 'BUY' ? tc.buy : tc.sell, 'Limit',
            id: o.id,
            kind: LevelKind.limit,
            draggable: !readonly && editing,
            tappable: !readonly));
      }
      // SL / TP are judged from where the order would fill: the limit for a Stop
      // Limit, otherwise its entry price.
      final fillRef = (o.isStopLimit ? (editing ? edit.limit : o.limit) : null) ?? entry;
      final oVol = editing ? (edit.volume ?? o.volume) : o.volume;
      if (sl != null)
        out.add(ChartLevel(sl, tc.loss,
            _protLabel('SL', o.side, oVol, fillRef, sl, sym, symbols),
            id: o.id,
            kind: LevelKind.sl,
            draggable: !readonly && editing,
            tappable: !readonly,
            labelFor: (px) => _protLabel('SL', o.side, oVol, fillRef, px, sym, symbols)));
      if (tp != null)
        out.add(ChartLevel(tp, tc.profit,
            _protLabel('TP', o.side, oVol, fillRef, tp, sym, symbols),
            id: o.id,
            kind: LevelKind.tp,
            draggable: !readonly && editing,
            tappable: !readonly,
            labelFor: (px) => _protLabel('TP', o.side, oVol, fillRef, px, sym, symbols)));
    }
    if (includeDraft && edit != null && edit.isDraft) {
      if (!edit.isMarket) {
        out.add(ChartLevel(edit.entry ?? 0, edit.isBuy ? tc.buy : tc.sell,
            '${edit.typeLabel} ${(edit.volume ?? _volume).toStringAsFixed(2)}${edit.isStopLimit ? ' · Stop' : ''}'.toUpperCase(),
            id: 'draft',
            kind: LevelKind.draft,
            draggable: true,
            dashed: false));
      }
      if (edit.isStopLimit && edit.limit != null) {
        out.add(ChartLevel(edit.limit!, edit.isBuy ? tc.buy : tc.sell, 'Limit',
            id: 'draft', kind: LevelKind.limit, draggable: true));
      }
      final dRef = edit.protectiveRef;
      final dVol = edit.volume ?? _volume;
      if (edit.sl != null)
        out.add(ChartLevel(edit.sl!, tc.loss,
            dRef == null ? 'SL' : _protLabel('SL', edit.side, dVol, dRef, edit.sl!, sym, symbols),
            id: 'draft',
            kind: LevelKind.sl,
            draggable: true,
            labelFor: dRef == null ? null : (px) => _protLabel('SL', edit.side, dVol, dRef, px, sym, symbols)));
      if (edit.tp != null)
        out.add(ChartLevel(edit.tp!, tc.profit,
            dRef == null ? 'TP' : _protLabel('TP', edit.side, dVol, dRef, edit.tp!, sym, symbols),
            id: 'draft',
            kind: LevelKind.tp,
            draggable: true,
            labelFor: dRef == null ? null : (px) => _protLabel('TP', edit.side, dVol, dRef, px, sym, symbols)));
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

  /// A multi-point tool finished its touch-drag-release on the chart: add the drawing (start, end
  /// anchors) and disarm the tool, so the next plain tap opens the round menu again.
  void _onCreateDrawing(DrawingType tool, List<DrawingAnchor> anchors) {
    ref.read(chartDrawingsProvider.notifier).add(DrawingObject(
          id: '${tool.name}-${DateTime.now().microsecondsSinceEpoch}',
          symbol: _symbol,
          type: tool,
          anchors: anchors,
          colorArgb: tool.defaultColor,
        ));
    setState(() {
      _activeTool = null;
      _pendingAnchors = [];
    });
  }

  void _cancelDrawing() => setState(() {
        _activeTool = null;
        _pendingAnchors = [];
      });

  /// Same as [_onAnchor]/[_cancelDrawing] above but for the second (view-only)
  /// chart window — its own tool state, own symbol.
  void _onAnchor2(DrawingAnchor a) {
    final tool = _activeTool2;
    final win = _extraWindows.isEmpty ? null : _extraWindows.first;
    if (tool == null || win == null) return;
    final next = [..._pendingAnchors2, a];
    if (next.length >= tool.anchorCount) {
      ref.read(chartDrawingsProvider.notifier).add(DrawingObject(
            id: '${tool.name}-${DateTime.now().microsecondsSinceEpoch}',
            symbol: win.symbol,
            type: tool,
            anchors: next,
            colorArgb: tool.defaultColor,
          ));
      setState(() {
        _activeTool2 = null;
        _pendingAnchors2 = [];
      });
    } else {
      setState(() => _pendingAnchors2 = next);
    }
  }

  void _onCreateDrawing2(DrawingType tool, List<DrawingAnchor> anchors) {
    final win = _extraWindows.isEmpty ? null : _extraWindows.first;
    if (win == null) return;
    ref.read(chartDrawingsProvider.notifier).add(DrawingObject(
          id: '${tool.name}-${DateTime.now().microsecondsSinceEpoch}',
          symbol: win.symbol,
          type: tool,
          anchors: anchors,
          colorArgb: tool.defaultColor,
        ));
    setState(() {
      _activeTool2 = null;
      _pendingAnchors2 = [];
    });
  }

  void _cancelDrawing2() => setState(() {
        _activeTool2 = null;
        _pendingAnchors2 = [];
      });

  /// MT5-style "Charts" management sheet, opened from either chart window's
  /// round menu (Duplicate wedge): add/select/remove chart windows and tile
  /// them once a second one exists.
  void _showChartsMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheetState) {
        final windowCount = 1 + _extraWindows.length;
        final canAddMore = windowCount < _kMaxChartWindows;
        final tc = Theme.of(ctx).extension<TradeColors>()!;
        void refresh(VoidCallback f) {
          setState(f);
          setSheetState(() {});
        }

        // On a short phone screen the list of windows + tile options + Remove
        // can be taller than the sheet's default cap — scroll it instead of
        // letting the bottom (Remove) get clipped off-screen.
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Charts',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800))),
                ),
                ListTile(
                  enabled: canAddMore,
                  leading: Icon(Icons.add,
                      color: canAddMore ? null : Theme.of(ctx).disabledColor),
                  title: Text('New Window',
                      style: canAddMore
                          ? null
                          : TextStyle(color: Theme.of(ctx).disabledColor)),
                  onTap: canAddMore
                      ? () => refresh(() {
                            _extraWindows.add(_ExtraChartWindow(
                                _symbol, ref.read(chartTfProvider)));
                            _tileAxis ??= Axis.horizontal;
                            _chartsMenuSelection = 1;
                          })
                      : null,
                ),
                for (var i = 0; i < windowCount; i++)
                  RadioListTile<int>(
                    value: i,
                    groupValue: _chartsMenuSelection,
                    onChanged: (v) =>
                        refresh(() => _chartsMenuSelection = v ?? 0),
                    title: Text(i == 0 ? _symbol : _extraWindows[i - 1].symbol),
                    secondary: const Icon(Icons.drag_handle),
                  ),
                if (windowCount > 1) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.table_rows_outlined),
                    title: const Text('Tile Horizontally'),
                    trailing: _tileAxis == Axis.horizontal
                        ? Icon(Icons.check,
                            color: Theme.of(ctx).colorScheme.primary)
                        : null,
                    onTap: () => refresh(() => _tileAxis = Axis.horizontal),
                  ),
                  ListTile(
                    leading: const Icon(Icons.view_column_outlined),
                    title: const Text('Tile Vertically'),
                    trailing: _tileAxis == Axis.vertical
                        ? Icon(Icons.check,
                            color: Theme.of(ctx).colorScheme.primary)
                        : null,
                    onTap: () => refresh(() => _tileAxis = Axis.vertical),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: windowCount > 1 ? tc.loss : null),
                      onPressed: windowCount > 1
                          ? () {
                              setState(() {
                                if (_chartsMenuSelection == 0) {
                                  // Removing the primary: promote the extra window into its place
                                  // so trading (positions/orders/SL-TP) keeps working uninterrupted.
                                  final promoted = _extraWindows.removeAt(0);
                                  _symbol = promoted.symbol;
                                  ref
                                      .read(chartTfProvider.notifier)
                                      .set(promoted.tf);
                                } else {
                                  _extraWindows
                                      .removeAt(_chartsMenuSelection - 1);
                                }
                                _chartsMenuSelection = 0;
                                if (_extraWindows.isEmpty) {
                                  _tileAxis = null;
                                  _activeTool2 = null;
                                  _pendingAnchors2 = [];
                                }
                              });
                              Navigator.pop(ctx);
                            }
                          : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove'),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }

  /// Builds [build] with [symbol]'s live quote. Only this subtree rebuilds on a tick - not the whole
  /// screen (a tick used to rebuild ~350 widgets: toolbar buttons, panels, text fields...). Only THIS
  /// symbol's tick matters: the app streams every subscribed symbol.
  Widget _tickQuote(String symbol, TradeSymbol? spec, Widget Function(Tick? raw, Tick? quote) build) =>
      Consumer(builder: (context, ref, _) {
        final raw = ref.watch(quotesProvider.select((m) => m[symbol]));
        final q = raw == null ? null : (spec == null ? raw : spec.applyGroupMarkup(raw));
        return build(raw, q);
      });

  @override
  Widget build(BuildContext context) {
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    ref.watch(chartSymbolProvider);
    ref.listen<String>(chartSymbolProvider, (prev, next) {
      if (prev == next || next.isEmpty) return;
      setState(() => _edit = null); // an edit belongs to one symbol
      prefetchChartHistory(
          next, (req) => ref.read(candlesProvider(req).future));
    });
    // The order / position being edited was filled, cancelled or closed elsewhere:
    // close the panel instead of letting Apply fail against something that is gone.
    ref.listen<AsyncValue<List<PendingOrder>>>(pendingOrdersProvider,
        (_, next) {
      final e = _edit;
      final list = next.valueOrNull;
      if (e != null &&
          e.isOrder &&
          list != null &&
          !list.any((o) => o.id == e.id)) {
        setState(() => _edit = null);
        ToastHost.show('Order no longer pending', e.typeLabel,
            accent: Theme.of(context).extension<TradeColors>()!.profit);
      }
    });
    ref.listen<AsyncValue<List<Position>>>(openPositionsProvider, (_, next) {
      final e = _edit;
      final list = next.valueOrNull;
      if (e != null &&
          e.isPosition &&
          list != null &&
          !list.any((p) => p.id == e.id)) {
        setState(() => _edit = null);
      }
    });
    final readonly =
        ref.watch(tradingSessionProvider.select((s) => s.readonly));
    final selectedTf = ref.watch(chartTfProvider);
    final symbols =
        ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final spec = symbols.where((s) => s.symbol == _symbol);
    final digits = spec.isEmpty ? 5 : spec.first.digits;
    final lotStep = spec.isEmpty ? 0.01 : spec.first.lotStep;
    final req = ChartReq(_symbol, selectedTf);
    final indicatorCfgs = ref.watch(chartIndicatorsProvider);
    final activeIndicators = indicatorCfgs.where((c) => c.enabled).length;
    final drawings = ref
        .watch(chartDrawingsProvider)
        .where((d) => d.symbol == _symbol)
        .toList();
    final positions =
        ref.watch(openPositionsProvider).valueOrNull ?? const <Position>[];
    final pendings =
        ref.watch(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[];
    final tc = Theme.of(context).extension<TradeColors>()!;
    void stepLot(double by) =>
        _setVolume(_volume + by, spec.isEmpty ? null : spec.first);
    final trade = ref.watch(chartTradeProvider);
    // Keep the lot field in step with the shared volume (e.g. restored from disk,
    // or changed from the order panel) — never while the user is typing in it.
    ref.listen<double>(
        chartTradeProvider.select((s) => s.volume), (_, v) => _syncVolField(v));
    final cs = Theme.of(context).colorScheme;
    final tradable = _tradableNow(spec.isEmpty ? null : spec.first);
    final draftOpen = _edit?.isDraft == true;

    // MT5-compact sizing: scales gently with screen width (clamped so phones,
    // tablets and desktop all keep the same tight proportions).
    final uiK = (MediaQuery.sizeOf(context).width / 420).clamp(0.9, 1.15);
    final toolIcon = 20.0 * uiK;
    Widget tool(IconData i, String tip, VoidCallback onTap,
            {bool active = false, Widget? child}) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: toolIcon,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: 36 * uiK, height: 36 * uiK),
          isSelected: active,
          style: active
              ? IconButton.styleFrom(
                  backgroundColor: cs.primary.withValues(alpha: 0.14))
              : null,
          icon: child ??
              Icon(i, size: toolIcon, color: active ? cs.primary : null),
          onPressed: onTap,
        );

    void pickTf(Timeframe tf) {
      ref.read(chartTfProvider.notifier).set(tf);
      setState(() => _tfStripOpen = false);
    }

    final tfStrip = _TfStrip(
      selected: selectedTf,
      onPick: pickTf,
      onSettings: () => _showChartSettings(context),
    );

    // MT5 chart toolbar: ☰ ✛ ƒ ✎  M1  ◔ ▭ — the order-mode and Buy/Sell toggles on the
    // right. Tapping the timeframe swaps the row for the full timeframe strip.
    final header = SizedBox(
      height: 40 * uiK,
      child: _tfStripOpen
          ? tfStrip
          : Row(children: [
              Expanded(
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      tool(Icons.add, 'Crosshair',
                          () => setState(() => _crosshair = !_crosshair),
                          active: _crosshair),
                      tool(Icons.functions, 'Indicators',
                          () => showIndicatorsSheet(context),
                          child: Badge(
                              isLabelVisible: activeIndicators > 0,
                              label: Text('$activeIndicators'),
                              child: const Icon(Icons.functions))),
                      // Chart type (Candlesticks / Line chart). The drawing tools live on the round menu
                      // (tap the chart), so they are no longer offered from here.
                      tool(Icons.timeline, 'Chart type', () => _showChartSettings(context),
                          active: _type == ChartType.line),
                      TextButton(
                        key: const ValueKey('tf-current'),
                        onPressed: () => setState(() => _tfStripOpen = true),
                        style: TextButton.styleFrom(
                            minimumSize: Size(40, 36 * uiK),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 6)),
                        child: Text(selectedTf.mt5Label,
                            style: TextStyle(
                                fontSize: 15 * uiK,
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface)),
                      ),
                      tool(
                          Icons.pending_actions_outlined,
                          draftOpen ? 'Close order panel' : 'New order',
                          _toggleOrderPanel,
                          active: draftOpen),
                      tool(
                          trade.panelVisible
                              ? Icons.toggle_on
                              : Icons.toggle_off_outlined,
                          trade.panelVisible
                              ? 'Hide Buy / Sell'
                              : 'Show Buy / Sell',
                          () => ref
                              .read(chartTradeProvider.notifier)
                              .togglePanel(),
                          active: trade.panelVisible),
                    ]),
              ),
            ]),
    );

    // MT5 one-click bar: SELL | ˅ volume ˄ | BUY, edge to edge. Bid and Ask are shown
    // here (and only here). One instance, present only while enabled, so hiding it
    // hands its height to the chart.
    // Proportions follow MT5 (≈ 5 : 7 : 5), so the bar scales with the screen width.
    final tradePanel = SizedBox(
      key: const ValueKey('trade-panel'),
      height: 36 * uiK,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 5,
          child: _tickQuote(
            _symbol,
            spec.isEmpty ? null : spec.first,
            (rawQuote, quote) => _DealCard(
              label: 'SELL',
              price: quote?.bid,
              digits: digits,
              base: tc.sell,
              up: tc.up,
              down: tc.down,
              enabled: quote != null,
              locked: readonly,
              tradable: tradable,
              onTap: () => _placeMarket('SELL'),
            ),
          ),
        ),
        Expanded(
          flex: 7,
          child: ColoredBox(
            color: cs.surface,
            child: Row(children: [
              _StepIcon(
                  icon: Icons.expand_more,
                  tooltip: 'Decrease volume',
                  onTap: () => stepLot(-lotStep)),
              Expanded(
                child: TextField(
                  key: const ValueKey('trade-volume'),
                  controller: _volCtrl,
                  focusNode: _volFocus,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14 * uiK,
                      color: cs.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                  decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      filled: false),
                  onChanged: (v) {
                    final d = double.tryParse(v.replaceAll(',', '.'));
                    if (d != null && d > 0) {
                      ref.read(chartTradeProvider.notifier).setVolume(d);
                      final e = _edit;
                      if (e != null && e.isDraft) setState(() => e.volume = d);
                    }
                  },
                  onEditingComplete: () {
                    _setVolume(_volume, spec.isEmpty ? null : spec.first);
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),
              _StepIcon(
                  icon: Icons.expand_less,
                  tooltip: 'Increase volume',
                  onTap: () => stepLot(lotStep)),
            ]),
          ),
        ),
        Expanded(
          flex: 5,
          child: _tickQuote(
            _symbol,
            spec.isEmpty ? null : spec.first,
            (rawQuote, quote) => _DealCard(
              label: 'BUY',
              price: quote?.ask,
              digits: digits,
              base: tc.buy,
              up: tc.up,
              down: tc.down,
              enabled: quote != null,
              locked: readonly,
              tradable: tradable,
              onTap: () => _placeMarket('BUY'),
            ),
          ),
        ),
      ]),
    );

    // Primary chart (MT5's tradable window): unchanged from before, just
    // extracted into a closure so it can sit either alone or tiled beside a
    // second, view-only window (see `_showChartsMenu` / `_extraWindows`).
    Widget primaryChartPane() => Consumer(builder: (context, ref, _) {
      final series = ref.watch(liveCandlesProvider(req));
      final rawQuote = ref.watch(quotesProvider.select((m) => m[_symbol]));
      final quote = rawQuote == null
          ? null
          : (spec.isEmpty ? rawQuote : spec.first.applyGroupMarkup(rawQuote));
      final forming = ref.watch(formingCandleProvider(req));
      final livePrice = forming?.c ?? rawQuote?.bid;
      final levels = _levels(positions, pendings, tc, readonly,
          // read, not watch: the label refreshes with every quote tick this pane already
          // rebuilds on; subscribing to the P/L push too would double the rebuilds (and
          // janks panning while a position is open).
          livePl: ref.read(livePositionProvider),
          // _levels only prices this symbol's positions, so this symbol's quote is all it can read.
          quotes: {if (rawQuote != null) _symbol: rawQuote},
          symbols: ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[]);
      return series.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (e, _) => Center(
              child:
                  Text('Chart unavailable\n$e', textAlign: TextAlign.center)),
          data: (candles) {
            if (candles.isEmpty)
              return const Center(child: Text('No data for this symbol yet.'));
            final indicators =
                _computeIndicatorsMemoized(candles, indicatorCfgs);
            final overlays = indicators.overlays;
            final oscillators = indicators.oscillators;
            return Padding(
              // Edge to edge like MT5: the frame lines run right to the screen edges.
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                height: double.infinity,
                child: Stack(children: [
                  CandleChart(
                    candles: candles,
                    digits: digits,
                    tf: selectedTf,
                    viewKey: _symbol,
                    crosshairMode: _crosshair,
                    livePrice: livePrice,
                    askPrice: quote?.ask,
                    type: _type,
                    levels: levels,
                    overlays: overlays,
                    oscillators: oscillators,
                    drawings: drawings,
                    activeTool: _activeTool,
                    pendingAnchors: _pendingAnchors,
                    onAnchor: _onAnchor,
                    onCreateDrawing: _onCreateDrawing,
                    onMoveDrawing: (id, a) => ref.read(chartDrawingsProvider.notifier).updateAnchors(id, a),
                    onMoveAnchor: (id, i, a) => ref
                        .read(chartDrawingsProvider.notifier)
                        .updateAnchor(id, i, a),
                    onDeleteDrawing: (id) =>
                        ref.read(chartDrawingsProvider.notifier).remove(id),
                    onLevelDragEnd: _onLevelDragEnd,
                    onLevelTap: _onLevelTap,
                    onNeedOlder: (n, urgent) => ref
                        .read(chartHistoryLoaderProvider(req))
                        .loadOlder(visibleBars: n, urgent: urgent),
                    olderPending: () => ref.read(chartHistoryStateProvider(req)).loadingOlder,
                    olderExhausted: () => ref.read(chartHistoryStateProvider(req)).exhausted,
                    onSelectTool: (t) => setState(() {
                      _activeTool = t;
                      _pendingAnchors = [];
                    }),
                    onOpenIndicators: () => showIndicatorsSheet(context),
                    onOpenObjects: () => showDrawingsSheet(
                      context,
                      symbol: _symbol,
                      digits: digits,
                      onSelectTool: (t) => setState(() {
                        _activeTool = t;
                        _pendingAnchors = [];
                      }),
                    ),
                    onDuplicate: () => _showChartsMenu(context),
                  ),
                  // MT5's chart caption: symbol ▾ timeframe / description / market state.
                  Positioned(
                    top: 4,
                    left: 4,
                    child: _SymbolCaption(
                      symbol: spec.isEmpty ? _symbol : spec.first.displaySymbol,
                      tf: selectedTf.mt5Label,
                      description: spec.isEmpty ? null : spec.first.description,
                      closed: !tradable,
                      onTap: () => _pickSymbol(context, symbols),
                    ),
                  ),
                  Positioned(
                      top: 6, right: 70, child: _BarCountdown(selectedTf)),
                  if (_activeTool != null)
                    Positioned(
                      top: 64,
                      left: 6,
                      child: Material(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                                '${_activeTool!.shortLabel}: ${_activeTool!.anchorCount >= 2 ? 'drag on the chart' : 'tap the chart'}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                            InkWell(
                                onTap: _cancelDrawing,
                                child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.close,
                                        size: 15, color: Colors.white))),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            );
          },
        );
    });

    // Second, view-only chart window (MT5's Duplicate / Tile): its own symbol,
    // timeframe, candles, zoom/pan/crosshair (own CandleChart instance) and
    // drawings — it does not place trades (see the class doc on
    // [_ExtraChartWindow] for the scope of what "independent" means here).
    Widget secondaryChartPane(_ExtraChartWindow win) => Consumer(builder: (context, ref, _) {
      final spec2 = symbols.where((s) => s.symbol == win.symbol);
      final digits2 = spec2.isEmpty ? 5 : spec2.first.digits;
      final req2 = ChartReq(win.symbol, win.tf);
      final series2 = ref.watch(liveCandlesProvider(req2));
      final drawings2 = ref
          .watch(chartDrawingsProvider)
          .where((d) => d.symbol == win.symbol)
          .toList();
      final rawQuote2 = ref.watch(quotesProvider.select((m) => m[win.symbol]));
      final quote2 = rawQuote2 == null
          ? null
          : (spec2.isEmpty
              ? rawQuote2
              : spec2.first.applyGroupMarkup(rawQuote2));
      final forming2 = ref.watch(formingCandleProvider(req2));
      final livePrice2 = forming2?.c ?? rawQuote2?.bid;
      final positions2 =
          ref.watch(openPositionsProvider).valueOrNull ?? const <Position>[];
      final pendings2 = ref.watch(pendingOrdersProvider).valueOrNull ??
          const <PendingOrder>[];
      final levels2 = _levels(positions2, pendings2, tc, readonly,
          symbol: win.symbol,
          includeDraft: false,
          // read, not watch: the label refreshes with every quote tick this screen already
          // rebuilds on; subscribing to the P/L push too would double the rebuilds (and
          // janks panning while a position is open).
          livePl: ref.read(livePositionProvider),
          quotes: {if (rawQuote2 != null) win.symbol: rawQuote2},
          symbols: ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[]);
      final tradable2 = _tradableNow(spec2.isEmpty ? null : spec2.first);

      return series2.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
            child: Text('Chart unavailable\n$e', textAlign: TextAlign.center)),
        data: (candles) {
          if (candles.isEmpty)
            return const Center(child: Text('No data for this symbol yet.'));
          final indicators =
              _computeIndicatorsMemoized2(candles, indicatorCfgs);
          final overlays2 = indicators.overlays;
          final oscillators2 = indicators.oscillators;
          return Padding(
            // Edge to edge like MT5: the frame lines run right to the screen edges.
              padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: Stack(children: [
                CandleChart(
                  candles: candles,
                  digits: digits2,
                  tf: win.tf,
                  viewKey: win.symbol,
                  livePrice: livePrice2,
                  askPrice: quote2?.ask,
                  type: _type,
                  levels: levels2,
                  overlays: overlays2,
                  oscillators: oscillators2,
                  drawings: drawings2,
                  activeTool: _activeTool2,
                  pendingAnchors: _pendingAnchors2,
                  onAnchor: _onAnchor2,
                  onCreateDrawing: _onCreateDrawing2,
                  onMoveDrawing: (id, a) => ref.read(chartDrawingsProvider.notifier).updateAnchors(id, a),
                  onMoveAnchor: (id, i, a) => ref
                      .read(chartDrawingsProvider.notifier)
                      .updateAnchor(id, i, a),
                  onDeleteDrawing: (id) =>
                      ref.read(chartDrawingsProvider.notifier).remove(id),
                  onNeedOlder: (n, urgent) => ref
                      .read(chartHistoryLoaderProvider(req2))
                      .loadOlder(visibleBars: n, urgent: urgent),
                  olderPending: () => ref.read(chartHistoryStateProvider(req2)).loadingOlder,
                  olderExhausted: () => ref.read(chartHistoryStateProvider(req2)).exhausted,
                  onSelectTool: (t) => setState(() {
                    _activeTool2 = t;
                    _pendingAnchors2 = [];
                  }),
                  onOpenIndicators: () => showIndicatorsSheet(context),
                  onOpenObjects: () => showDrawingsSheet(
                    context,
                    symbol: win.symbol,
                    digits: digits2,
                    onSelectTool: (t) => setState(() {
                      _activeTool2 = t;
                      _pendingAnchors2 = [];
                    }),
                  ),
                  onDuplicate: () => _showChartsMenu(context),
                ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: _SymbolCaption(
                    symbol:
                        spec2.isEmpty ? win.symbol : spec2.first.displaySymbol,
                    tf: win.tf.mt5Label,
                    description: spec2.isEmpty ? null : spec2.first.description,
                    closed: !tradable2,
                    onTap: () => _pickSymbol2(context, symbols, win),
                  ),
                ),
                Positioned(top: 6, right: 70, child: _BarCountdown(win.tf)),
                if (_activeTool2 != null)
                  Positioned(
                    top: 64,
                    left: 6,
                    child: Material(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(
                              '${_activeTool2!.shortLabel}: ${_activeTool2!.anchorCount >= 2 ? 'drag on the chart' : 'tap the chart'}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                          InkWell(
                              onTap: _cancelDrawing2,
                              child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.close,
                                      size: 15, color: Colors.white))),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      );
    });

    return Scaffold(
      key: _scaffoldKey,
      drawer: const PortalDrawer(),
      // The rest of the screen stays visible, just dimmed enough to give the menu focus.
      drawerScrimColor: Colors.black.withValues(alpha: 0.45),
      body: SafeArea(
        bottom: false,
        // The toolbar floats above the page (a Stack, not the first Column item) so its
        // drop shadow paints over the SELL / BUY panel and chart below it.
        child: Stack(children: [
          Column(children: [
          // Space reserved for the floating toolbar (40 * uiK) + its 1 px rule.
          SizedBox(height: 40 * uiK + 1),
          const ActiveAccountBar(compact: true, onlyWhenSpecial: true),
          if (trade.panelVisible) tradePanel,
          Expanded(
            child: _extraWindows.isEmpty
                ? primaryChartPane()
                : (_tileAxis == Axis.vertical
                    ? Row(children: [
                        Expanded(child: primaryChartPane()),
                        VerticalDivider(
                            width: 1, color: Theme.of(context).dividerColor),
                        Expanded(
                            child: secondaryChartPane(_extraWindows.first)),
                      ])
                    : Column(children: [
                        Expanded(child: primaryChartPane()),
                        Divider(
                            height: 1, color: Theme.of(context).dividerColor),
                        Expanded(
                            child: secondaryChartPane(_extraWindows.first)),
                      ])),
          ),
          if (_edit != null)
            SafeArea(
              top: false,
              child: _tickQuote(
                _symbol,
                spec.isEmpty ? null : spec.first,
                (rawQuote, quote) => PendingPanel(
                edit: _edit!,
                symbolLabel: spec.isEmpty ? _symbol : spec.first.displaySymbol,
                symbolDescription: spec.isEmpty ? null : spec.first.description,
                digits: digits,
                quote: quote,
                minLot: _lots().min,
                maxLot: _lots().max,
                lotStep: _lots().step,
                busy: _applying,
                serverError: _serverError,
                expanded: _panelExpanded,
                onExpandedChanged: (v) => setState(() => _panelExpanded = v),
                onChanged: () {
                  setState(() => _serverError = null);
                  // A new order's volume is the shared volume.
                  final e = _edit;
                  final v = e?.volume;
                  if (e != null && e.isDraft && v != null && v > 0)
                    ref.read(chartTradeProvider.notifier).setVolume(v);
                },
                onPickType: _startDraft,
                onAddSl: () => _addProtective(sl: true),
                onAddTp: () => _addProtective(sl: false),
                onRemoveSl: () => _removeProtective(sl: true),
                onRemoveTp: () => _removeProtective(sl: false),
                onApply: _apply,
                onMarket: _placeMarket,
                marketEnabled: quote != null && tradable && !readonly,
                onClose: () => setState(() {
                  _edit = null;
                  _panelExpanded = false;
                  _serverError = null;
                }),
                onCancelOrder: _cancelPendingOrder,
              )),
            ),
          ]),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                header,
                // MT5 rule under the toolbar. The rule under the SELL / BUY panel is the
                // chart's own top frame line (see the painter), so none is added here.
                Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  void _showChartSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Chart',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          for (final t in ChartType.values)
            ListTile(
              leading: Icon(t == ChartType.candles
                  ? Icons.candlestick_chart
                  : Icons.show_chart),
              title:
                  Text(t == ChartType.candles ? 'Candlesticks' : 'Line chart'),
              trailing: _type == t
                  ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () {
                setState(() => _type = t);
                Navigator.pop(ctx);
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _pickSymbol(BuildContext context, List<TradeSymbol> symbols) {
    if (symbols.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _SymbolPicker(
        symbols: symbols,
        current: _symbol,
        onPick: (s) {
          Navigator.pop(ctx);
          if (s != _symbol) _symbol = s;
        },
      ),
    );
  }

  /// Same as [_pickSymbol] but for the second (view-only) chart window — sets
  /// that window's own symbol instead of the shared [chartSymbolProvider].
  void _pickSymbol2(
      BuildContext context, List<TradeSymbol> symbols, _ExtraChartWindow win) {
    if (symbols.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _SymbolPicker(
        symbols: symbols,
        current: win.symbol,
        onPick: (s) {
          Navigator.pop(ctx);
          if (s != win.symbol) setState(() => win.symbol = s);
        },
      ),
    );
  }
}

/// MT5 timeframe strip: M1 M5 M15 M30 H1 H4 D1 W1 MN ⚙. The active timeframe is
/// highlighted.
class _TfStrip extends StatelessWidget {
  const _TfStrip(
      {required this.selected, required this.onPick, required this.onSettings});
  final Timeframe selected;
  final void Function(Timeframe) onPick;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // All nine share the row equally (MT5); a label only shrinks if a very narrow
    // phone can't fit it at full size — never scrolls a timeframe out of sight.
    return Row(children: [
      const SizedBox(width: 4),
      for (final tf in Timeframe.values)
        Expanded(
          child: InkWell(
            key: ValueKey('tf-${tf.name}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => onPick(tf),
            child: SizedBox(
              height: 44,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    tf.mt5Label,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight:
                          tf == selected ? FontWeight.w800 : FontWeight.w600,
                      color: tf == selected
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      IconButton(
          tooltip: 'Chart settings',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.settings_outlined),
          onPressed: onSettings),
    ]);
  }
}

/// Chart caption, top-left over the chart (MT5): "EURUSD ▾ M1", the description
/// and "Market closed" when the session is shut. Only the first line is tappable
/// (it opens the symbol list); the rest lets gestures through to the chart.
class _SymbolCaption extends StatelessWidget {
  const _SymbolCaption(
      {required this.symbol,
      required this.tf,
      required this.description,
      required this.closed,
      required this.onTap});
  final String symbol;
  final String tf;
  final String? description;
  final bool closed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub =
        TextStyle(fontSize: 11.5, height: 1.2, color: cs.onSurface.withValues(alpha: 0.85));
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const ValueKey('symbol-caption'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 1, 6, 1),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(symbol,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: cs.primary)),
                Icon(Icons.arrow_drop_down, size: 16, color: cs.primary),
                Text(tf,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface)),
              ]),
            ),
          ),
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (description != null && description!.trim().isNotEmpty)
                      Text(description!, style: sub),
                    if (closed) Text('Market closed', style: sub),
                  ]),
            ),
          ),
        ]);
  }
}

/// Searchable symbol list for the chart caption.
class _SymbolPicker extends StatefulWidget {
  const _SymbolPicker(
      {required this.symbols, required this.current, required this.onPick});
  final List<TradeSymbol> symbols;
  final String current;
  final void Function(String symbol) onPick;
  @override
  State<_SymbolPicker> createState() => _SymbolPickerState();
}

class _SymbolPickerState extends State<_SymbolPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.symbols
        .where((s) =>
            q.isEmpty ||
            s.displaySymbol.toLowerCase().contains(q) ||
            s.symbol.toLowerCase().contains(q) ||
            (s.description ?? '').toLowerCase().contains(q))
        .toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, 8 + MediaQuery.of(context).viewInsets.bottom * 0),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search symbol'),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final s = list[i];
              final sel = s.symbol == widget.current;
              return ListTile(
                dense: true,
                title: Text(s.displaySymbol,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: sel
                            ? Theme.of(context).colorScheme.primary
                            : null)),
                subtitle:
                    (s.description ?? '').isEmpty ? null : Text(s.description!),
                trailing: sel
                    ? Icon(Icons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => widget.onPick(s.symbol),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Counts down the time remaining on the current forming bar.
class _BarCountdown extends ConsumerStatefulWidget {
  const _BarCountdown(this.tf);
  final Timeframe tf;
  @override
  ConsumerState<_BarCountdown> createState() => _BarCountdownState();
}

class _BarCountdownState extends ConsumerState<_BarCountdown> {
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
    if (s >= 86400)
      return '${s ~/ 86400}d${((s % 86400) ~/ 3600).toString().padLeft(2, '0')}h';
    if (s >= 3600)
      return '${s ~/ 3600}h${((s % 3600) ~/ 60).toString().padLeft(2, '0')}';
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = widget.tf.nextBucketStart(now, brokerOffsetSec: ref.watch(brokerOffsetSecProvider).valueOrNull ?? 0) - now;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.timer_outlined,
            size: 12, color: Theme.of(context).hintColor),
        const SizedBox(width: 4),
        Text(_fmt(remaining),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

/// Result of one indicator recompute pass — see `_computeIndicatorsMemoized`.
class _IndicatorBundle {
  const _IndicatorBundle(this.overlays, this.oscillators);
  final List<ComputedIndicator> overlays;
  final List<ComputedIndicator> oscillators;
}

/// A second, view-only chart window opened via the round menu's Duplicate
/// wedge (MT5-style). Its symbol/timeframe are independent of the primary
/// chart's; candles, zoom, pan and crosshair come for free per-instance from
/// [CandleChart] and [candlesProvider]/[liveCandlesProvider]'s per-request cache.
class _ExtraChartWindow {
  _ExtraChartWindow(this.symbol, this.tf);
  String symbol;
  Timeframe tf;
}

class _IndicatorCacheEntry {
  const _IndicatorCacheEntry(
      {required this.sig,
      required this.len,
      required this.at,
      required this.bundle});
  final String
      sig; // enabled indicator set + params + colors, as a comparable string
  final int len; // candles.length at the time this was computed
  final DateTime at;
  final _IndicatorBundle bundle;
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
    this.tradable = true,
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

  /// The symbol's market is open right now. When false the panel is fully
  /// disabled/grey regardless of tick movement or [enabled] — this is
  /// resolved dynamically per symbol (see `_tradableNow`), never hardcoded.
  final bool tradable;
  final VoidCallback onTap;

  @override
  State<_DealCard> createState() => _DealCardState();
}

/// Flat grey used only for the market-closed state — deliberately not derived
/// from [TradeColors] so it can never be mistaken for a real up/down tick.
const _kMarketClosedGrey = Color(0xFF6B7280);

class _DealCardState extends State<_DealCard> {
  Color? _flash;
  Timer? _revert;

  @override
  void didUpdateWidget(covariant _DealCard old) {
    super.didUpdateWidget(old);
    if (!widget.tradable) {
      // Market closed (or just closed): never compute or show a movement
      // colour, and drop one that was mid-fade when it closed.
      if (_flash != null || _revert != null) {
        _revert?.cancel();
        _revert = null;
        setState(() => _flash = null);
      }
      return;
    }
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
    final active = widget.enabled && !widget.locked && widget.tradable;
    // MT5: a flat grey panel with white text — "SELL" / "BUY" small top-left, the
    // price bottom-right with the pip digits enlarged. The panel flashes blue / red
    // on an up / down tick and settles back to grey. Market closed: dim grey, no flash.
    final fill = !widget.tradable ? _kMarketClosedGrey : (_flash ?? _kDealGrey);
    return Opacity(
      opacity: active || widget.locked ? 1 : 0.6,
      child: Material(
        color: fill,
        child: InkWell(
          onTap: active ? widget.onTap : (widget.locked ? widget.onTap : null),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(5, 2, 6, 2),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.label,
                  style: const TextStyle(
                      fontSize: 9, height: 1.1, color: Colors.white)),
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: widget.price == null
                        ? const Text('—',
                            style: TextStyle(fontSize: 15, color: Colors.white))
                        : BigFigurePrice(
                            value: widget.price!,
                            digits: widget.digits,
                            color: Colors.white,
                            baseSize: 12),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// MT5's resting colour for the SELL / BUY panels.
const _kDealGrey = Color(0xFFB9BCC2);

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(icon, size: 18, color: Theme.of(context).hintColor)),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
