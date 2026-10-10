import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show Gradient;
import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:btrader_core/btrader_core.dart';

import 'radial_chart_menu.dart';

enum ChartType { candles, line }

/// What a chart level represents. Drives colour, dragging and what a tap does.
/// [LevelKind.limit] is a Stop Limit order's limit (fill) price; its stop trigger
/// uses [LevelKind.pending] / [LevelKind.draft] like any other pending entry.
enum LevelKind { entry, sl, tp, pending, draft, limit }

/// A horizontal price level to draw on the chart (entry / SL / TP / pending).
///
/// The VISIBLE line is thin; interaction uses [kHitSlop] either side of it, so
/// a level is easy to grab on a phone without looking heavy.
class ChartLevel {
  final double price;
  final Color color;
  final String label;
  final bool dashed;
  final String? id;
  final LevelKind kind;

  /// Can be dragged to a new price (SL / TP / pending / draft while editing).
  final bool draggable;

  /// Tap opens the SL/TP editor for this level's position / pending order.
  final bool tappable;

  /// false = MT5's plain inline label (coloured text on the line, no box) — used by
  /// open-position lines. true = a filled tag. Every on-chart level now uses the
  /// plain MT5 style (false); the filled variant is kept only for opt-in callers.
  final bool boxed;

  /// Re-labels the level for a price it is being dragged to (so "SL, -12.30 USD,
  /// -41 points" follows the finger). Null = the static [label].
  final String Function(double price)? labelFor;

  /// Colour for the P&L part of the label (the text after the last ", "), e.g. blue profit /
  /// red loss on an open position's `BUY 0.10, -2.90 USD`. Null = the whole label is [color].
  final Color? plColor;
  const ChartLevel(
    this.price,
    this.color,
    this.label, {
    this.dashed = true,
    this.id,
    this.kind = LevelKind.entry,
    this.draggable = false,
    this.tappable = false,
    this.boxed = false,
    this.labelFor,
    this.plColor,
  });
}

/// Half-height (logical px) of the touch target around a level line.
const double kHitSlop = 22;

/// Visible stroke of order lines (entry / SL / TP / pending) — slightly thinner
/// than before; the hit area above is unchanged.
const double kLevelStroke = 0.8;

/// Visible stroke of candle wicks — thinner and cleaner; bodies are untouched.
const double kWickStroke = 0.7;

/// The visible (non-null) values of overlay indicator lines within the given
/// window. Shared by the painter and the tap→price mapping so the price range
/// (and therefore the crosshair/tap math) folds overlays in identically.
List<double> overlayValuesInWindow(List<ComputedIndicator> overlays, int start, int end) {
  final out = <double>[];
  for (final ind in overlays) {
    for (final ln in ind.lines) {
      final v = ln.values;
      for (var i = start; i < end && i < v.length; i++) {
        final x = v[i];
        if (x != null) out.add(x);
      }
    }
  }
  return out;
}

/// Map a chart-space time to an x-pixel over the visible window [w] with the
/// given [slot] width. Interpolates between bracketing bars (handles
/// weekend/holiday gaps) and extrapolates beyond the edges using the edge bar
/// spacing. Shared by the painter (drawing render) and the state (hit-testing).
double xForTimeInWindow(List<Candle> w, int t, double slot) {
  final n = w.length;
  if (n == 0) return 0;
  if (n == 1) return slot / 2;
  if (t <= w.first.t) {
    final sp = w[1].t - w[0].t;
    return slot / 2 + (sp == 0 ? 0 : (t - w.first.t) / sp) * slot;
  }
  if (t >= w.last.t) {
    final sp = w[n - 1].t - w[n - 2].t;
    return slot * (n - 1) + slot / 2 + (sp == 0 ? 0 : (t - w.last.t) / sp) * slot;
  }
  for (var i = 0; i < n - 1; i++) {
    if (t >= w[i].t && t <= w[i + 1].t) {
      final span = w[i + 1].t - w[i].t;
      final frac = span == 0 ? 0.0 : (t - w[i].t) / span;
      return slot * i + slot / 2 + frac * slot;
    }
  }
  return slot * (n - 1) + slot / 2;
}

/// Padded visible price range (high/low) for a window of candles + overlay
/// levels + indicator overlay values. Shared by the painter and the tap→price
/// mapping so they never drift.
///
/// [priceZoom] is the independent vertical/price-axis zoom (1 = auto-fitted
/// to the data, <1 = compressed/zoomed in, >1 = expanded/zoomed out) — driven
/// by dragging the right-hand price ladder, and kept deliberately separate
/// from [vShift] (a pure pan of that same range, from dragging the chart
/// body) so "zoom the price scale" and "shift the price scale" never fight
/// over the same state.
({double hi, double lo}) chartRange(List<Candle> cs, List<ChartLevel> levels,
    {List<double> extra = const [], double vShift = 0, double priceZoom = 1}) {
  var hi = cs.first.h, lo = cs.first.l;
  for (final k in cs) {
    if (k.h > hi) hi = k.h;
    if (k.l < lo) lo = k.l;
  }
  // Fold open-position / SL / TP levels into the range so a trade near the price is never hidden -
  // but only those within reach of the candles. A line far from the visible bars (several open
  // trades spread over a wide price band, an entry from long ago, an SL / TP far away) used to
  // stretch the scale until the candles were a thin sliver and the chart looked dead; MT5 scales
  // to the candles and simply lets such a line sit off-screen. A line being edited / dragged is
  // always kept in view so it can be placed.
  final candleHi = hi, candleLo = lo;
  final reach = math.max(candleHi - candleLo, candleHi.abs() * 0.0002) * 0.4;
  for (final lv in levels) {
    if (lv.price <= 0) continue;
    if (!lv.draggable && (lv.price > candleHi + reach || lv.price < candleLo - reach)) continue;
    if (lv.price > hi) hi = lv.price;
    if (lv.price < lo) lo = lv.price;
  }
  // Fold in overlay indicator values (moving averages, Bollinger bands) so they
  // stay on-screen instead of clipping at the extremes.
  for (final v in extra) {
    if (v > hi) hi = v;
    if (v < lo) lo = v;
  }
  final pad = (hi - lo) * 0.08;
  var top = hi + pad, bottom = lo - pad;
  if (priceZoom != 1) {
    final mid = (top + bottom) / 2;
    final half = (top - bottom) / 2 * priceZoom;
    top = mid + half;
    bottom = mid - half;
  }
  // Vertical pan: slide the whole price window by a fraction of its height.
  final shift = vShift * (top - bottom);
  return (hi: top + shift, lo: bottom + shift);
}

/// Interactive candlestick/line chart — pan (drag), zoom (pinch), crosshair
/// (long-press), candle/line types, MT5-style price ladder + time axis, and
/// entry/SL/TP level overlays. Tapping the right price axis fires [onPriceTap]
/// with the price at that level. Indicator overlays draw on the price pane;
/// oscillators stack in resizable sub-panes below. No external charting dep.
class CandleChart extends StatefulWidget {
  const CandleChart({
    super.key,
    required this.candles,
    required this.digits,
    required this.tf,
    this.livePrice,
    this.askPrice,
    this.type = ChartType.candles,
    this.levels = const [],
    this.overlays = const [],
    this.oscillators = const [],
    this.drawings = const [],
    this.activeTool,
    this.pendingAnchors = const [],
    this.onAnchor,
    this.onMoveAnchor,
    this.onCreateDrawing,
    this.onMoveDrawing,
    this.onDeleteDrawing,
    this.onPriceTap,
    this.onLevelDragEnd,
    this.onLevelTap,
    this.onEmptyTap,
    this.onAutoFit,
    this.onNeedOlder,
    this.olderPending,
    this.olderExhausted,
    this.debugViewport,
    this.loadingOlder = false,
    this.crosshairMode = false,
    this.viewKey,
    this.onSelectTool,
    this.onOpenIndicators,
    this.onOpenObjects,
    this.onDuplicate,
  });
  final List<Candle> candles;
  final int digits;
  final Timeframe tf;

  /// The current dealable Bid — the dashed Bid line locks to this and stays
  /// put while you scroll back, instead of following the last visible candle.
  final double? livePrice;

  /// The current dealable Ask (group-markup applied, same as the BUY panel).
  /// Drawn as a second dashed line above Bid, color-coded like the SELL/BUY
  /// panels so the two are distinguishable at a glance. Null (no line drawn)
  /// until a live quote exists for the symbol.
  final double? askPrice;
  final ChartType type;
  final List<ChartLevel> levels;

  /// Indicator overlays (SMA/EMA/WMA/Bollinger), full-length aligned to
  /// [candles]. Drawn on the price pane.
  final List<ComputedIndicator> overlays;

  /// Oscillator indicators (RSI/MACD/Stochastic/ATR), full-length aligned to
  /// [candles]. Each gets its own stacked sub-pane below the price chart.
  final List<ComputedIndicator> oscillators;

  /// User-drawn objects (horizontal lines, trendlines, Fibonacci) for the
  /// active symbol. Rendered on the price pane, pinned by (time, price).
  final List<DrawingObject> drawings;

  /// When non-null the chart is in placement mode: taps on the price pane emit
  /// [onAnchor] instead of trading, and [pendingAnchors] preview the placement.
  final DrawingType? activeTool;
  final List<DrawingAnchor> pendingAnchors;
  final void Function(DrawingAnchor anchor)? onAnchor;

  /// Fired once when a drag of an existing drawing's anchor is released.
  final void Function(String id, int anchorIndex, DrawingAnchor anchor)? onMoveAnchor;

  /// Fired once when a touch-drag-release made with a multi-point tool ends: the tool and its
  /// anchors (start, end). The caller adds the drawing and resets the tool.
  final void Function(DrawingType tool, List<DrawingAnchor> anchors)? onCreateDrawing;

  /// Fired once when a whole drawing has been dragged to a new place and released.
  final void Function(String id, List<DrawingAnchor> anchors)? onMoveDrawing;

  /// Fired when the on-chart delete button is tapped for the selected drawing.
  final void Function(String id)? onDeleteDrawing;

  /// Called with the price the user tapped on the right price ladder (MT5-style
  /// trade-from-chart).
  final void Function(double price)? onPriceTap;

  /// A draggable level was released at [price] (SL / TP / pending / draft).
  final void Function(ChartLevel level, double price)? onLevelDragEnd;

  /// A tappable level (entry / pending line) was tapped.
  final void Function(ChartLevel level)? onLevelTap;

  /// A tap that hit no line, drawing or axis (the one that opens the round menu).
  final VoidCallback? onEmptyTap;

  /// "Auto fit" pressed (the chart has already reset its own view).
  final VoidCallback? onAutoFit;

  /// The user panned near the start of the currently loaded history — fetch
  /// and prepend an older page. Safe to call repeatedly; the caller
  /// (`loadOlderCandles`) de-duplicates in-flight requests itself.
  ///
  /// [visibleBars] is what is on screen (plus whatever a fling is about to cover) and sizes the
  /// batch; [urgent] means less than one screen is buffered, so ask for a small, fast batch first.
  final void Function(int visibleBars, bool urgent)? onNeedOlder;

  /// Non-reactive reads of the history loader's state. While older bars may still arrive the
  /// chart lets the finger / a fling run on into a blank margin instead of hitting a wall, then
  /// eases back if nothing came. (Reading, not watching: no rebuild when they flip.)
  final bool Function()? olderPending;
  final bool Function()? olderExhausted;

  /// Test hook: receives the scroll offset (bars back from the newest) and the candle slot width.
  final ValueNotifier<({double offset, double slot})>? debugViewport;

  /// An older-history page is currently loading, for the left-edge spinner.
  final bool loadingOlder;

  /// MT5's crosshair tool: while on, a tap places the crosshair and a one-finger
  /// drag moves it (instead of panning). Pinch still zooms; order lines still drag.
  final bool crosshairMode;

  /// Identity of the series shown (e.g. the symbol). When it or [tf] changes the
  /// zoom is kept, but the view snaps back to the newest bars with the price range
  /// re-fitted — an offset in bars / a price shift means nothing on another series.
  final Object? viewKey;

  /// MT5-style round chart menu: tapping empty chart space opens it (see
  /// [_CandleChartState.handleSelectOrTrade]); picking a timeframe here fires
  /// this and closes the menu.
  /// A drawing tool was picked on the round menu — the caller arms it for placement.
  final void Function(DrawingType)? onSelectTool;

  /// Round menu's "Indicators" wedge — opens the app's real indicators sheet.
  final VoidCallback? onOpenIndicators;

  /// Round menu's "Objects" wedge — opens the app's real drawing-tools sheet.
  final VoidCallback? onOpenObjects;

  /// Round menu's "Duplicate" wedge — opens MT5-style chart-window management
  /// (new window / tile / remove).
  final VoidCallback? onDuplicate;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

/// How far the newest bar can be pushed off the price axis: dragging the chart
/// forward reveals up to this many empty candle-slots of headroom on the right.
/// The default view rests flush (newest bar at the axis, no gap); the margin is
/// only scroll headroom, not a resting offset — so the live forming bar never
/// looks detached from the edge.
const double _kRightPad = 5;

/// How far the user may drag the newest bar in from the right edge, as a share of the visible bars
/// (never a pixel count, so it follows the width and the zoom). The view still OPENS flush at the
/// edge; this only widens how much empty chart a horizontal drag can reveal, so the live bar can be
/// brought to the middle and a little beyond. [_kRightPad] stays the floor for very small views.
const double _kMaxHeadroomFraction = 0.6;

/// Laid-out text, reused across frames. The price ladder, time labels and Bid/Ask tags are the same
/// few strings frame after frame while panning (a label stays glued to its bar; the ladder only
/// changes when the visible high/low does), yet each was laid out from scratch on every frame -
/// the largest single cost of a frame at normal zoom. Painters are only ever painted, never
/// mutated, so sharing them is safe.
class _TextCache {
  static final Map<String, TextPainter> _m = {};
  static const int _cap = 1500;

  /// Keep the cache bounded by dropping only the least recently used quarter. The old wholesale
  /// clear() threw away the price ladder, time axis and every other still-live label with the
  /// stale ones, so a chart with many trades (whose P/L labels change constantly) re-laid out
  /// everything in a single frame every few seconds.
  static void _trim() {
    if (_m.length < _cap) return;
    final drop = _m.keys.take(_cap ~/ 4).toList();
    for (final k in drop) {
      _m.remove(k);
    }
  }

  static TextPainter get(String text, double size, Color color, [FontWeight weight = FontWeight.normal]) {
    final key = '$size|${weight.index}|${color.toARGB32()}|$text';
    final hit = _m.remove(key);
    if (hit != null) return _m[key] = hit; // re-insert: most recently used goes last
    _trim();
    return _m[key] = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: weight)),
    )..layout();
  }

  /// A laid-out rich-text label, kept while its inputs are unchanged (the key must name every input).
  static TextPainter rich(String key, InlineSpan Function() span, {double? maxWidth}) {
    final k = 'r|${maxWidth?.round()}|$key';
    final hit = _m.remove(k);
    if (hit != null) return _m[k] = hit;
    _trim();
    return _m[k] = TextPainter(textDirection: TextDirection.ltr, text: span())..layout(maxWidth: maxWidth ?? double.infinity);
  }

  /// Width only (the axis-width probe): colour does not affect it.
  static double width(String text, double size, FontWeight weight) => get(text, size, const Color(0xFF000000), weight).width;
}

/// Which axis a single-finger drag that started on an axis strip is zooming.
enum _AxisDrag { price, time }

class _CandleChartState extends State<CandleChart> with SingleTickerProviderStateMixin {
  double _perScreen = 80; // visible candle count (zoom)
  // Candles scrolled back from the latest. 0 = newest bar flush at the axis
  // (default); negative = dragged forward into the right-margin headroom.
  double _rightOffset = 0;

  /// Empty slots the newest bar may be dragged in from the right edge at the current zoom.
  double _headroomSlots = _kRightPad;
  double _lastScale = 1.0;
  double _chartW = 1;

  // ── Continuous pan / fling ──────────────────────────────────────────────────────────────
  // One controller drives both the fling after a swipe and the ease-back from the blank margin.
  late final AnimationController _motion = AnimationController.unbounded(vsync: this)
    ..addListener(_onMotionTick)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        _flinging = false;
        _settleSoon();
      }
    });
  Timer? _settleTimer;
  double _slotPx = 1; // candle slot width, refreshed every build; converts finger px <-> bars
  int _total = 0; // candle count at the last build, for clamps outside build()
  double _panCarryX = 0, _panCarryY = 0; // finger travel the gesture slop swallowed, to catch up on
  bool _panning = false, _gestureZoomed = false, _tapStoppedFling = false, _flinging = false;
  bool _prefetchQueued = false;
  bool _panCarryPending = false;
  int _lastPointerCount = 0;
  double _flingTarget = 0;

  // Finger travel before a scale gesture is recognised is not reported (Flutter hands over only the
  // per-event delta once it starts), so a stock detector makes the chart lag the finger by the slop.
  // A smaller slop (8 px -> pan starts after 16) plus the catch-up above keeps it 1:1.
  static const DeviceGestureSettings _chartGesture = DeviceGestureSettings(touchSlop: 8);

  /// Furthest the view may scroll back: the oldest loaded bar at the left edge...
  double get _hardMax => math.max(0.0, _total - _perScreen);

  /// ...or, while older history may still arrive, up to ~one screen of blank margin past it so the
  /// movement never hits a wall.
  double get _softMax {
    final more = widget.onNeedOlder != null && !(widget.olderExhausted?.call() ?? false);
    return _hardMax + (more ? _perScreen * 0.85 : 0);
  }

  double _clampOffset(double v) => v.clamp(-_headroomSlots, _softMax).toDouble();

  void _onMotionTick() {
    final v = _motion.value;
    final c = _clampOffset(v);
    setState(() => _rightOffset = c);
    if (c != v) {
      // Ran into the live edge or the end of the margin.
      _motion.stop();
      _flinging = false;
      _settleSoon();
    }
  }

  void _stopMotion() {
    if (_motion.isAnimating) _motion.stop();
    _flinging = false;
    _settleTimer?.cancel();
  }

  void _startFling(double vxPx) {
    final slot = _slotPx;
    if (slot <= 0) return;
    final vPx = vxPx.clamp(-9000.0, 9000.0);
    if (vPx.abs() < 120) return;
    final sim = FrictionSimulation(0.135, _rightOffset, vPx / slot, tolerance: const Tolerance(velocity: 0.02, distance: 0.001));
    _flingTarget = sim.finalX;
    _flinging = true;
    _motion.animateWith(sim);
  }

  /// If the view is parked in the blank margin, wait for the older bars that are on their way
  /// (they fill it in place) and ease back to the real edge only if none arrive.
  void _settleSoon() {
    _settleTimer?.cancel();
    if (!mounted || _rightOffset <= _hardMax + 0.001) return;
    var waited = 0;
    _settleTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      waited += 100;
      if (!mounted || _rightOffset <= _hardMax + 0.001) {
        t.cancel();
        return;
      }
      final pending = widget.olderPending?.call() ?? false;
      final exhausted = widget.olderExhausted?.call() ?? false;
      if (exhausted || (!pending && waited >= 600) || waited >= 5000) {
        t.cancel();
        _motion.value = _rightOffset;
        _motion.animateTo(_hardMax, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
      }
    });
  }

  double _oscFraction = 0.32; // share of chart height taken by the osc region
  bool _oscCollapsed = false;

  // Drawing selection + drag. During a drag the moved anchor is held locally
  // (_dragAnchor) so only this widget repaints; the provider is updated once on
  // release, avoiding a full screen rebuild (indicator recompute) per frame.
  String? _selectedDrawingId;
  int? _dragAnchorIndex;
  DrawingAnchor? _dragAnchor;

  /// The true touch-down point. A scale gesture only reports its start after the finger has moved past
  /// the touch slop, so drag-to-create / drag-to-move begin from THIS, not from the first scale update.
  Offset? _downPos;

  /// Live anchors while a multi-point tool is being drag-created (null otherwise).
  List<DrawingAnchor>? _createAnchors;
  Offset? _createFromPx;
  Offset? _createToPx;

  /// Live anchors while an existing drawing is being dragged as a whole (null otherwise).
  String? _moveId;
  List<DrawingAnchor>? _moveAnchors;
  Offset? _moveStartPx;
  List<Offset>? _moveOrigPx;

  Offset? _cross; // crosshair local position (null = off)

  // MT5-style round chart menu: tap empty chart space to open, tap anywhere
  // (a wedge, or empty space) to act/close — see [RadialChartMenu].
  bool _radialOpen = false;

  /// True for a moment after the round menu closes. A tap landing in that window is the tail of the
  /// menu interaction itself (the tap that picked a tool / dismissed it), not a new chart tap, so it
  /// must neither place a drawing point nor reopen the menu.
  bool _justClosedRadial = false;
  Timer? _radialGuard;
  static const Duration _kMenuTapGuard = Duration(milliseconds: 300);

  void _closeRadial() {
    _justClosedRadial = true;
    _radialGuard?.cancel();
    _radialGuard = Timer(_kMenuTapGuard, () => _justClosedRadial = false);
    setState(() => _radialOpen = false);
  }

  // Vertical pan as a fraction of the visible price range (0 = auto-fitted).
  // Together with the horizontal offset this lets the chart be dragged freely in
  // every direction; "Auto fit" / double-tap puts it back.
  double _vShift = 0;

  // Independent vertical/price-axis zoom (1 = auto-fitted). Set only by
  // dragging the right-hand price ladder — see `_AxisDrag.price` below —
  // deliberately never touched by the body pan/pinch gesture, so "zoom the
  // price scale" and "pan the price scale" (`_vShift`) can never fight.
  double _priceZoom = 1;

  // Which axis (if any) the CURRENT single-finger drag is zooming, decided
  // once in onScaleStart from where the finger went down. Kept separate from
  // `_dragLevelKey`/`_dragAnchorIndex`, which are always checked first, so a
  // drag that starts on a draggable SL/TP/pending line is never reinterpreted
  // as an axis-zoom just because it happens to be near an axis.
  _AxisDrag? _axisDrag;

  // A level being dragged: held locally so only the chart repaints per frame; the
  // owner is told once on release.
  String? _dragLevelKey;
  ChartLevel? _dragLevel;
  double? _dragLevelPrice;

  String _levelKey(ChartLevel l) => '${l.kind.name}:${l.id ?? l.label}';

  double _chartH = 1;

  // Zoom survives the chart being rebuilt from scratch (e.g. a spinner while a
  // not-yet-cached timeframe loads) via the page's storage bucket.
  static const _kZoomKey = 'candle_chart_zoom';

  @override
  void initState() {
    super.initState();
    final saved = PageStorage.maybeOf(context)?.readState(context, identifier: _kZoomKey);
    if (saved is double && saved > 0) _perScreen = saved;
  }

  // deactivate, not dispose: ancestors (the storage bucket) can still be looked up here.
  @override
  void deactivate() {
    PageStorage.maybeOf(context)?.writeState(context, _perScreen, identifier: _kZoomKey);
    super.deactivate();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _motion.dispose();
    _radialGuard?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CandleChart old) {
    super.didUpdateWidget(old);
    if (old.tf != widget.tf || old.viewKey != widget.viewKey) {
      _rightOffset = 0;
      _vShift = 0;
      _priceZoom = 1;
      _cross = widget.crosshairMode ? _cross : null;
      _selectedDrawingId = null;
      _dragLevelKey = null;
      _dragLevel = null;
      _dragLevelPrice = null;
      _dragAnchorIndex = null;
      _dragAnchor = null;
      _createAnchors = null;
      _moveAnchors = null;
      _moveId = null;
      _radialOpen = false;
    }
    if (old.tf == widget.tf &&
        old.viewKey == widget.viewKey &&
        _rightOffset > 0 &&
        old.candles.isNotEmpty &&
        widget.candles.isNotEmpty) {
      // MT5: when scrolled back, a newly formed bar must not drag the view along - the bars you are
      // looking at stay where they are. (At the live edge the view keeps following the newest bar.)
      final oldLast = old.candles.last.t;
      var added = 0;
      for (var i = widget.candles.length - 1; i >= 0 && widget.candles[i].t > oldLast; i--) {
        added++;
      }
      if (added > 0) _rightOffset += added;
    }
    if (old.crosshairMode != widget.crosshairMode) {
      // On: start in the middle of the price pane (MT5); off: remove it.
      _cross = widget.crosshairMode ? Offset(_chartW / 2, _chartH / 2) : null;
    }
  }

  void _resetView() => setState(() {
        _stopMotion();
        _perScreen = 60;
        _rightOffset = 0;
        _vShift = 0;
        _priceZoom = 1;
        if (!widget.crosshairMode) _cross = null;
      });


  /// Right price-ladder width, sized to what it will actually display: the
  /// widest ladder tick (hi/lo of the visible range) and the widest live
  /// Bid/Ask tag, both at this symbol's real digit count — never a fixed
  /// constant, so a 2-digit symbol (e.g. gold) doesn't carry the same margin
  /// as a 5-digit one (e.g. a forex pair), and the axis never clips either way.
  double _computeAxisWidth(double hi, double lo, int digits, double? bid, double? ask) {
    double widthFor(String text, double fontSize, FontWeight weight) => _TextCache.width(text, fontSize, weight);

    var ladder = 0.0;
    for (final p in [hi, lo]) {
      ladder = math.max(ladder, widthFor(p.toStringAsFixed(digits), 9, FontWeight.normal));
    }
    var tag = 0.0;
    for (final p in [bid, ask]) {
      if (p == null) continue;
      tag = math.max(tag, widthFor(p.toStringAsFixed(digits), 9.5, FontWeight.w800));
    }
    // Ladder labels sit past an 8px gap from the axis line; tags sit in a
    // rounded pill with ~5px of padding each side — see the painter's `_tag`
    // and the ladder-label loop below.
    return math.max(ladder + 12, tag + 10).clamp(40.0, 90.0);
  }

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final total = widget.candles.length;
    if (total == 0) return const SizedBox.shrink();

    final oscs = _oscCollapsed ? const <ComputedIndicator>[] : widget.oscillators;

    return LayoutBuilder(builder: (_, c) {
      _chartH = c.maxHeight.isFinite ? c.maxHeight : 1;
      // Guard the zoom bounds when there are very few candles (e.g. history is
      // still rebuilding): the lower bound must never exceed the upper bound.
      final minPer = math.min(12.0, total.toDouble());
      final per = _perScreen.clamp(minPer, total.toDouble());
      final perI = per.round();
      _total = total;
      // Ichimoku projects its cloud into the future - reserve that many empty slots on the right so
      // the projection is visible (0 when no Ichimoku).
      final futureSlots = widget.overlays.fold<int>(0, (m, o) => math.max(m, o.futureShift));

      // Pixel-continuous layout. `_rightOffset` (bars scrolled back from the newest, fractional) is
      // never rounded: the bars overlapping the viewport are drawn at a fractional pixel shift, so the
      // chart moves exactly as far as the finger did. The window needs no pixel sizes, so it can be
      // chosen before the price axis (which depends on the window) is measured.
      _headroomSlots = math.max(_kRightPad, per * _kMaxHeadroomFraction);
      final off = _rightOffset;
      final start = (total - per - off).floor().clamp(0, total - 1);
      final dataEnd = (total - off + futureSlots).ceil().clamp(start + 1, total);
      final window = widget.candles.sublist(start, dataEnd);
      final trailingGap = 0;

      // Keep ~3 screens of history buffered to the left of the viewport (scaled by the zoom, not a
      // fixed count) and look ahead by whatever a fling is about to cover, so the oldest loaded bar
      // is never reached: the user just keeps dragging. The loader runs silently in the background.
      final bufferBars = total - per - off;
      final ahead = _flinging ? math.max(0.0, _flingTarget - _rightOffset) : 0.0;
      if (widget.onNeedOlder != null && !_prefetchQueued && bufferBars - ahead < math.max(150, perI * 3)) {
        _prefetchQueued = true;
        final urgent = bufferBars - ahead < perI;
        final want = perI + ahead.round();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _prefetchQueued = false;
          if (mounted) widget.onNeedOlder?.call(want, urgent);
        });
      }
      final overlayExtra = overlayValuesInWindow(widget.overlays, start, dataEnd);

      // Right price-ladder width, measured from the labels it will actually
      // show (not a fixed constant) — a symbol/timeframe with fewer price
      // digits gets a narrower axis and hands the freed width to the candles,
      // instead of every chart reserving the same generous margin regardless
      // of screen size or content (MT5 keeps this strip tight).
      final axisRange = chartRange(window, widget.levels, extra: overlayExtra, vShift: _vShift, priceZoom: _priceZoom);
      final axisW = _computeAxisWidth(axisRange.hi, axisRange.lo, widget.digits, widget.livePrice, widget.askPrice);
      _chartW = (c.maxWidth - axisW).clamp(1, double.infinity);
      final slotPx = _chartW / (per + futureSlots);
      _slotPx = slotPx;
      // Where window[0] starts, in px (-slot..0 normally; positive while the blank margin is showing).
      final xShift = (per + off - (total - start)) * slotPx;
      widget.debugViewport?.value = (offset: off, slot: slotPx);

      // Vertical geometry: reserve the osc region from the bottom (above the
      // time axis). Kept in sync with the painter so the resize handle lands on
      // the boundary line.
      final metrics = _paneMetrics(c.maxHeight, oscs.length);

      void handlePriceTap(Offset pos) {
        if (widget.onPriceTap == null || pos.dx < _chartW) return; // axis region only
        // Only the price pane's axis trades; taps on an oscillator pane's axis
        // don't map to a tradeable price.
        if (pos.dy > metrics.priceTop + metrics.priceH) return;
        final r = chartRange(window, widget.levels, extra: overlayExtra, vShift: _vShift, priceZoom: _priceZoom);
        final price = r.hi - (pos.dy - metrics.priceTop) / metrics.priceH * (r.hi - r.lo);
        if (price > 0) widget.onPriceTap!(price);
      }

      // Placement mode: a tap on the price pane becomes a drawing anchor. The
      // time snaps to the nearest visible bar; the price is exact.
      void handlePlacementTap(Offset pos) {
        if (widget.onAnchor == null || window.isEmpty) return;
        if (pos.dx < 0 || pos.dx >= _chartW) return;
        if (pos.dy < metrics.priceTop || pos.dy > metrics.priceTop + metrics.priceH) return;
        final idx = ((pos.dx - xShift) / slotPx).floor().clamp(0, window.length - 1);
        final r = chartRange(window, widget.levels, extra: overlayExtra, vShift: _vShift, priceZoom: _priceZoom);
        final price = r.hi - (pos.dy - metrics.priceTop) / metrics.priceH * (r.hi - r.lo);
        widget.onAnchor!(DrawingAnchor(window[idx].t, price));
      }

      void zoom(double factor) => setState(() {
            _perScreen = (_perScreen * factor).clamp(minPer, total.toDouble());
            _rightOffset = _clampOffset(_rightOffset);
          });

      // ── Chart-space ↔ pixel mapping for drawing hit-testing / dragging. ──
      final slotB = slotPx;
      final r = chartRange(window, widget.levels, extra: overlayExtra, vShift: _vShift, priceZoom: _priceZoom);
      final priceSpan = (r.hi - r.lo) == 0 ? 1.0 : (r.hi - r.lo);
      double pyForPrice(double p) => metrics.priceTop + (r.hi - p) / priceSpan * metrics.priceH;
      double priceAtY(double dy) =>
          r.hi - (dy.clamp(metrics.priceTop, metrics.priceTop + metrics.priceH) - metrics.priceTop) / metrics.priceH * priceSpan;
      double pxForTime(int t) => xForTimeInWindow(window, t, slotB) + xShift;
      int timeAtX(double dx) => window[((dx - xShift) / slotB).floor().clamp(0, window.length - 1)].t;

      // Inverse of [xForTimeInWindow] WITHOUT clamping to the visible bars: interpolates between
      // bars and extrapolates past the edges, so a drawing dragged partly off-screen keeps its shape.
      int timeAtXFree(double dx) {
        final n = window.length;
        if (n < 2) return window.isEmpty ? 0 : window.first.t;
        final f = (dx - xShift) / slotB - 0.5; // fractional bar index
        if (f <= 0) return (window.first.t + f * (window[1].t - window[0].t)).round();
        if (f >= n - 1) return (window.last.t + (f - (n - 1)) * (window[n - 1].t - window[n - 2].t)).round();
        final i = f.floor();
        return (window[i].t + (f - i) * (window[i + 1].t - window[i].t)).round();
      }

      double priceAtYFree(double dy) => r.hi - (dy - metrics.priceTop) / metrics.priceH * priceSpan;

      // A touch point as a drawing anchor: time snapped to the nearest visible bar, price exact —
      // the same rule as a placement tap — clamped into the price pane so a drag may leave it.
      DrawingAnchor? anchorAtPx(Offset pos) {
        if (window.isEmpty) return null;
        final dx = pos.dx.clamp(0.0, _chartW - 0.01).toDouble();
        return DrawingAnchor(timeAtX(dx), priceAtY(pos.dy));
      }

      DrawingObject? selected() {
        for (final d in widget.drawings) {
          if (d.id == _selectedDrawingId) return d;
        }
        return null;
      }

      double distToSeg(Offset p, Offset a, Offset b) {
        final ab = b - a, ap = p - a;
        final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
        final t = len2 == 0 ? 0.0 : ((ap.dx * ab.dx + ap.dy * ab.dy) / len2).clamp(0.0, 1.0);
        return (p - (a + ab * t)).distance;
      }

      bool inPricePane(Offset p) =>
          p.dx >= 0 && p.dx < _chartW && p.dy >= metrics.priceTop && p.dy <= metrics.priceTop + metrics.priceH;

      bool hitDrawing(DrawingObject d, Offset p) {
        if (!inPricePane(p)) return false;
        switch (d.type) {
          case DrawingType.horizontalLine:
            return (p.dy - pyForPrice(d.anchors.first.price)).abs() < 8;
          case DrawingType.verticalLine:
            return (p.dx - pxForTime(d.anchors.first.t)).abs() < 8;
          case DrawingType.trendline:
          case DrawingType.arrow:
            return distToSeg(p, Offset(pxForTime(d.anchors[0].t), pyForPrice(d.anchors[0].price)),
                    Offset(pxForTime(d.anchors[1].t), pyForPrice(d.anchors[1].price))) <
                9;
          case DrawingType.ray:
            final ra = Offset(pxForTime(d.anchors[0].t), pyForPrice(d.anchors[0].price));
            final rb = Offset(pxForTime(d.anchors[1].t), pyForPrice(d.anchors[1].price));
            final dir = rb - ra;
            final far = dir.distance == 0 ? rb : ra + dir / dir.distance * 4000;
            return distToSeg(p, ra, far) < 9;
          case DrawingType.rectangle:
          case DrawingType.ellipse:
            final a0 = Offset(pxForTime(d.anchors[0].t), pyForPrice(d.anchors[0].price));
            final b0 = Offset(pxForTime(d.anchors[1].t), pyForPrice(d.anchors[1].price));
            return Rect.fromPoints(a0, b0).inflate(8).contains(p);
          case DrawingType.fibRetracement:
            final a = d.anchors[0], b = d.anchors[1];
            if (p.dx < math.min(pxForTime(a.t), pxForTime(b.t)) - 4) return false;
            for (final lv in kFibLevels) {
              if ((p.dy - pyForPrice(a.price + lv * (b.price - a.price))).abs() < 7) return true;
            }
            return false;
        }
      }

      // Which anchor handle (if any) a drag started on, for the selected drawing.
      int? grabAnchor(DrawingObject d, Offset p) {
        if (d.type == DrawingType.horizontalLine) {
          return (p.dy - pyForPrice(d.anchors.first.price)).abs() < 16 ? 0 : null;
        }
        if (d.type == DrawingType.verticalLine) {
          return (p.dx - pxForTime(d.anchors.first.t)).abs() < 16 ? 0 : null;
        }
        for (var i = 0; i < d.anchors.length; i++) {
          if ((p.dx - pxForTime(d.anchors[i].t)).abs() < 22 && (p.dy - pyForPrice(d.anchors[i].price)).abs() < 22) {
            return i;
          }
        }
        return null;
      }

      // Nearest interactive level under the touch. The visible line is thin; the
      // touch target is [kHitSlop] each side so it is easy to catch on a phone.
      ChartLevel? levelAt(Offset p, {required bool drag}) {
        if (!inPricePane(p) && !(p.dx >= _chartW - 44 && p.dx <= _chartW + 60 && p.dy >= metrics.priceTop && p.dy <= metrics.priceTop + metrics.priceH)) {
          return null;
        }
        ChartLevel? best;
        var bestD = kHitSlop + 1.0;
        for (final l in widget.levels) {
          if (l.price <= 0 || !(drag ? l.draggable : (l.tappable || l.draggable))) continue;
          final ly = pyForPrice(l.price);
          if (ly < metrics.priceTop || ly > metrics.priceTop + metrics.priceH) continue; // off-screen line
          final d = (p.dy - ly).abs();
          if (d < bestD) {
            bestD = d;
            best = l;
          }
        }
        return best;
      }

      void handleSelectOrTrade(Offset pos) {
        final lv = levelAt(pos, drag: false);
        if (lv != null && lv.tappable) {
          widget.onLevelTap?.call(lv);
          return;
        }
        if (pos.dx >= _chartW) {
          handlePriceTap(pos);
          return;
        }
        String? hit;
        for (final d in widget.drawings) {
          if (hitDrawing(d, pos)) {
            hit = d.id;
            break;
          }
        }
        if (hit != null) {
          if (hit != _selectedDrawingId) setState(() => _selectedDrawingId = hit);
          return;
        }
        if (_selectedDrawingId != null) {
          // First tap off a selected drawing just deselects it (MT5-style);
          // the round menu opens on the next, now-empty tap.
          setState(() => _selectedDrawingId = null);
          return;
        }
        widget.onEmptyTap?.call();
        setState(() => _radialOpen = true);
      }

      return Stack(children: [
        MediaQuery(
          data: MediaQuery.of(context).copyWith(gestureSettings: _chartGesture),
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (_tapStoppedFling) {
              // This touch only stopped a coasting chart (MT5): it is not a chart tap.
              _tapStoppedFling = false;
              return;
            }
            if (_justClosedRadial) return; // tail of the menu tap, not a chart tap
            if (widget.activeTool != null) return handlePlacementTap(d.localPosition);
            if (widget.crosshairMode) {
              final lv = levelAt(d.localPosition, drag: false);
              if (lv != null && lv.tappable) {
                widget.onLevelTap?.call(lv);
              } else {
                setState(() => _cross = d.localPosition);
              }
              return;
            }
            handleSelectOrTrade(d.localPosition);
          },
          onScaleStart: (d) {
            _lastScale = 1.0;
            _stopMotion();
            _tapStoppedFling = false;
            _panning = false;
            _gestureZoomed = false;
            // The slop distance the finger covered before this callback fired - caught up in the first
            // few pan frames (see _chartGesture).
            _panCarryX = 0;
            _panCarryY = 0;
            _panCarryPending = _downPos != null && d.pointerCount == 1;
            _dragAnchorIndex = null;
            _dragAnchor = null;
            _axisDrag = null;
            _createAnchors = null;
            _moveAnchors = null;
            _moveId = null;
            // MT5-style creation: with a multi-point tool armed, ONE touch-drag-release draws it. The
            // gesture starts where the finger first touched; the drag is never a pan. One-point tools
            // (H-Line / V-Line) keep their tap, and a two-finger gesture still pinches / zooms.
            final armed = widget.activeTool;
            if (armed != null && d.pointerCount == 1 && armed.anchorCount >= 2 && widget.onCreateDrawing != null) {
              final from = _downPos ?? d.localFocalPoint;
              final a = _justClosedRadial ? null : anchorAtPx(from);
              if (a != null) {
                setState(() {
                  _createAnchors = [a, a];
                  _createFromPx = from;
                  _createToPx = from;
                });
              }
              return;
            }
            // Grab a draggable order level (SL / TP / pending) instead of panning.
            // This is checked FIRST and unconditionally, exactly as before — the new
            // axis-zoom strips below only ever apply when this found nothing to grab,
            // so a line sitting near an axis is still always grabbed, never zoomed.
            if (widget.activeTool == null && d.pointerCount == 1) {
              final lv = levelAt(d.localFocalPoint, drag: true);
              if (lv != null) {
                setState(() {
                  _dragLevelKey = _levelKey(lv);
                  _dragLevel = lv;
                  _dragLevelPrice = lv.price;
                });
                return;
              }
            }
            // Grab an anchor of the selected drawing to drag it (instead of panning).
            if (widget.activeTool == null) {
              final sel = selected();
              if (sel != null) {
                // From the true touch-down point (the focal point reported here is already past the slop).
                final gi = grabAnchor(sel, _downPos ?? d.localFocalPoint);
                if (gi != null) {
                  setState(() {
                    _dragAnchorIndex = gi;
                    _dragAnchor = sel.anchors[gi];
                  });
                  return;
                }
              }
            }
            // Grab an existing drawing by its body: select it and drag it as a whole (MT5: touch the
            // object, then drag). Order / SL / TP lines were checked above and win; a selected
            // drawing's own handles were checked just before this.
            if (widget.activeTool == null && d.pointerCount == 1) {
              final from = _downPos ?? d.localFocalPoint;
              DrawingObject? hit;
              final sel0 = selected();
              if (sel0 != null && hitDrawing(sel0, from)) {
                hit = sel0;
              } else {
                for (final dr in widget.drawings.reversed) {
                  if (hitDrawing(dr, from)) {
                    hit = dr;
                    break;
                  }
                }
              }
              if (hit != null && !_justClosedRadial) {
                final g = hit;
                setState(() {
                  _selectedDrawingId = g.id;
                  _moveId = g.id;
                  _moveAnchors = g.anchors;
                  _moveStartPx = from;
                  _moveOrigPx = [for (final a in g.anchors) Offset(pxForTime(a.t), pyForPrice(a.price))];
                });
                return;
              }
            }
            // A single finger starting ON the right-hand price ladder zooms the
            // price axis vertically (MT5-style "drag the axis to rescale"),
            // distinct from a body drag (which shifts, see onScaleUpdate).
            if (widget.activeTool == null &&
                d.pointerCount == 1 &&
                d.localFocalPoint.dx >= _chartW &&
                d.localFocalPoint.dy >= metrics.priceTop &&
                d.localFocalPoint.dy <= metrics.priceTop + metrics.priceH) {
              setState(() => _axisDrag = _AxisDrag.price);
              return;
            }
            // A single finger starting on the bottom time axis zooms time
            // horizontally, same idea, the other axis.
            if (widget.activeTool == null &&
                d.pointerCount == 1 &&
                d.localFocalPoint.dy >= c.maxHeight - _CandlePainter.timeAxisH) {
              setState(() => _axisDrag = _AxisDrag.time);
              return;
            }
          },
          onScaleUpdate: (d) {
            if (_createAnchors != null) {
              final a = anchorAtPx(d.localFocalPoint);
              if (a != null) {
                setState(() {
                  _createAnchors = [_createAnchors!.first, a];
                  _createToPx = d.localFocalPoint;
                });
              }
              return;
            }
            if (_moveAnchors != null && _moveId != null) {
              final sel = selected();
              final start = _moveStartPx, orig = _moveOrigPx;
              if (sel == null || start == null || orig == null) return;
              final delta = d.localFocalPoint - start;
              setState(() {
                _moveAnchors = [
                  for (var i = 0; i < orig.length; i++)
                    DrawingAnchor(
                      // A horizontal line slides only in price, a vertical line only in time.
                      sel.type == DrawingType.horizontalLine ? sel.anchors[i].t : timeAtXFree(orig[i].dx + delta.dx),
                      sel.type == DrawingType.verticalLine ? sel.anchors[i].price : priceAtYFree(orig[i].dy + delta.dy),
                    ),
                ];
              });
              return;
            }
            if (_dragLevelKey != null) {
              final py = priceAtY(d.localFocalPoint.dy);
              setState(() => _dragLevelPrice = py > 0 ? py : _dragLevelPrice);
              return;
            }
            // Dragging a drawing anchor: update the local copy only (smooth; the
            // provider is written once on release).
            if (_dragAnchorIndex != null) {
              final sel = selected();
              if (sel == null) return;
              final p = d.localFocalPoint;
              // A horizontal line slides only in price, a vertical line only in time.
              final t = sel.type == DrawingType.horizontalLine ? sel.anchors.first.t : timeAtX(p.dx);
              final pr = sel.type == DrawingType.verticalLine ? sel.anchors.first.price : priceAtY(p.dy);
              setState(() => _dragAnchor = DrawingAnchor(t, pr));
              return;
            }
            if (_axisDrag == _AxisDrag.price) {
              // Drag up = zoom in (compress the range); drag down = zoom out.
              setState(() {
                final factor = 1 + d.focalPointDelta.dy * 0.0045;
                _priceZoom = (_priceZoom * factor).clamp(0.3, 4.0);
              });
              return;
            }
            if (_axisDrag == _AxisDrag.time) {
              // Drag left = more candles visible (zoom out); drag right = zoom in.
              setState(() {
                final factor = 1 - d.focalPointDelta.dx * 0.006;
                _perScreen = (_perScreen * factor).clamp(minPer, total.toDouble());
                _rightOffset = _clampOffset(_rightOffset);
              });
              return;
            }
            // Crosshair tool: one finger moves the crosshair rather than the chart.
            if (widget.crosshairMode && d.pointerCount == 1) {
              setState(() => _cross = d.localFocalPoint);
              return;
            }
            setState(() {
              final s = d.scale / _lastScale;
              _lastScale = d.scale;
              if ((s - 1).abs() > 0.001) {
                _perScreen = (_perScreen / s).clamp(minPer, total.toDouble());
                _gestureZoomed = true;
              }
              _panning = true;
              _lastPointerCount = d.pointerCount;
              var dx = d.focalPointDelta.dx, dy = d.focalPointDelta.dy;
              if (_panCarryPending) {
                // Flutter reports only the recognising event's own delta; everything the finger covered
                // since touch-down before that event is the distance to catch up on.
                _panCarryPending = false;
                final down = _downPos;
                if (down != null && d.pointerCount == 1) {
                  _panCarryX = (d.localFocalPoint.dx - down.dx) - dx;
                  _panCarryY = (d.localFocalPoint.dy - down.dy) - dy;
                }
              }
              if (_panCarryX.abs() > 0.5) {
                final step = _panCarryX * 0.4;
                dx += step;
                _panCarryX -= step;
              } else {
                dx += _panCarryX;
                _panCarryX = 0;
              }
              if (_panCarryY.abs() > 0.5) {
                final step = _panCarryY * 0.4;
                dy += step;
                _panCarryY -= step;
              } else {
                dy += _panCarryY;
                _panCarryY = 0;
              }
              // 1:1 with the finger, in whole pixels (fractional bars); no rounding anywhere.
              _rightOffset = _clampOffset(_rightOffset + dx / _slotPx);
              // Free vertical movement too (single-finger drag), bounded so the
              // candles can never be pushed completely out of view.
              if (d.pointerCount == 1 && metrics.priceH > 0) {
                _vShift = (_vShift + dy / metrics.priceH).clamp(-1.5, 1.5);
              }
              if (_cross != null) _cross = _cross!.translate(d.focalPointDelta.dx, d.focalPointDelta.dy);
            });
          },
          onScaleEnd: (e) {
            final wasPan = _panning;
            final zoomed = _gestureZoomed;
            _panning = false;
            _gestureZoomed = false;
            if (wasPan && !zoomed && _lastPointerCount == 1) _startFling(e.velocity.pixelsPerSecond.dx);
            _settleSoon();
            if (_createAnchors != null) {
              final pts = _createAnchors!;
              final tool = widget.activeTool;
              final from = _createFromPx, to = _createToPx;
              setState(() {
                _createAnchors = null;
                _createFromPx = null;
                _createToPx = null;
              });
              // A drag that went (almost) nowhere is not a drawing: keep the tool armed.
              final dragged = from != null && to != null && (to - from).distance >= 6;
              if (tool != null && dragged && (pts.first.t != pts.last.t || pts.first.price != pts.last.price)) {
                widget.onCreateDrawing?.call(tool, pts);
              }
              return;
            }
            if (_moveAnchors != null && _moveId != null) {
              final id = _moveId!, pts = _moveAnchors!;
              setState(() {
                _moveId = null;
                _moveAnchors = null;
                _moveStartPx = null;
                _moveOrigPx = null;
              });
              widget.onMoveDrawing?.call(id, pts);
              return;
            }
            if (_axisDrag != null) {
              setState(() => _axisDrag = null);
              return;
            }
            if (_dragLevelKey != null) {
              final lv = _dragLevel, pr = _dragLevelPrice;
              setState(() {
                _dragLevelKey = null;
                _dragLevel = null;
                _dragLevelPrice = null;
              });
              if (lv != null && pr != null) widget.onLevelDragEnd?.call(lv, pr);
              return;
            }
            if (_dragAnchorIndex != null && _dragAnchor != null) {
              widget.onMoveAnchor?.call(_selectedDrawingId!, _dragAnchorIndex!, _dragAnchor!);
            }
            if (_dragAnchorIndex != null) {
              setState(() {
                _dragAnchorIndex = null;
                _dragAnchor = null;
              });
            }
          },
          onLongPressStart: (d) => setState(() => _cross = d.localPosition),
          onLongPressMoveUpdate: (d) => setState(() => _cross = d.localPosition),
          onLongPressEnd: (_) {
            if (!widget.crosshairMode) setState(() => _cross = null);
          },
          onDoubleTap: _resetView,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              _downPos = e.localPosition;
              // A touch while the chart is coasting stops it (and is not a tap).
              _tapStoppedFling = _motion.isAnimating && _flinging;
              _stopMotion();
            },
            onPointerUp: (_) => _settleSoon(),
            child: CustomPaint(
            size: Size.infinite,
            painter: _CandlePainter(
              candles: window,
              winStart: start,
              trailingGap: trailingGap,
              slotW: slotPx,
              xShift: xShift,
              totalBars: total,
              futureSlots: futureSlots,
              digits: widget.digits,
              tf: widget.tf,
              livePrice: widget.livePrice,
              askPrice: widget.askPrice,
              type: widget.type,
              levels: widget.levels,
              overlays: widget.overlays,
              oscillators: oscs,
              oscFraction: _oscFraction,
              drawings: widget.drawings,
              pendingAnchors: _createAnchors ?? widget.pendingAnchors,
              previewType: widget.activeTool,
              moveAnchors: _moveAnchors,
              selectedId: _selectedDrawingId,
              dragIndex: _dragAnchorIndex,
              dragAnchor: _dragAnchor,
              cross: _cross,
              vShift: _vShift,
              priceZoom: _priceZoom,
              dragLevelKey: _dragLevelKey,
              dragLevelPrice: _dragLevelPrice,
              up: tc.up,
              down: tc.down,
              bid: tc.sell,
              ask: tc.buy,
              grid: Theme.of(context).dividerColor,
              text: Theme.of(context).hintColor,
              line: Theme.of(context).colorScheme.primary,
              surface: Theme.of(context).colorScheme.surface,
              onSurface: Theme.of(context).colorScheme.onSurface,
              axisW: axisW,
            ),
          )),
        )),
        // Trade lines on their OWN repaint layer: they only change with the levels or the price scale,
        // not with a horizontal pan, so a chart with dozens of trades no longer re-records and
        // re-rasterises hundreds of dashed lines and labels on every pan frame.
        if (window.isNotEmpty && widget.levels.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  isComplex: true,
                  willChange: false,
                  painter: _LevelsPainter(
                    levels: widget.levels,
                    contentKey: _levelsKey(widget.levels),
                    hi: _levelsRange(window, start, oscs).hi,
                    lo: _levelsRange(window, start, oscs).lo,
                    digits: widget.digits,
                    axisW: axisW,
                    oscCount: oscs.length,
                    oscFraction: _oscFraction,
                    dragLevelKey: _dragLevelKey,
                    dragLevelPrice: _dragLevelPrice,
                    surface: Theme.of(context).colorScheme.surface,
                  ),
                ),
              ),
            ),
          ),
        // MT5-style round chart menu: tap anywhere on the chart to open it (see
        // handleSelectOrTrade above), tap any wedge — or empty space — to close.
        // Centred on the price pane so it never clips against the axes.
        if (_radialOpen)
          Positioned.fill(
            child: Builder(builder: (_) {
              final menuCenter = Offset(_chartW / 2, metrics.priceTop + metrics.priceH / 2);
              final maxR = math.min(_chartW, metrics.priceH) / 2 * 0.85;
              final outerR = maxR.clamp(64.0, 165.0);
              final innerR = outerR * 0.42;
              return RadialChartMenu(
                center: menuCenter,
                outerRadius: outerR,
                innerRadius: innerR,
                activeTool: widget.activeTool,
                onSelectTool: (t) {
                  _closeRadial();
                  widget.onSelectTool?.call(t);
                },
                onDuplicate: () {
                  _closeRadial();
                  widget.onDuplicate?.call();
                },
                onObjects: () {
                  _closeRadial();
                  widget.onOpenObjects?.call();
                },
                onIndicators: () {
                  _closeRadial();
                  widget.onOpenIndicators?.call();
                },
                onDismiss: _closeRadial,
              );
            }),
          ),
        // Selected-drawing toolbar: drag a handle to move, or delete/deselect.
        if (widget.activeTool == null && selected() != null)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
                shape: StadiumBorder(side: BorderSide(color: Theme.of(context).dividerColor)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Drag a handle to move', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () {
                        final id = _selectedDrawingId;
                        setState(() => _selectedDrawingId = null);
                        if (id != null) widget.onDeleteDrawing?.call(id);
                      },
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline, size: 18, color: tc.loss),
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => _selectedDrawingId = null),
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close, size: 18, color: Theme.of(context).colorScheme.onSurface),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        // Draggable divider to resize the oscillator region + collapse toggle.
        if (widget.oscillators.isNotEmpty)
          Positioned(
            left: 0,
            right: axisW,
            top: metrics.priceTop + metrics.priceH - 8,
            height: 16,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: _oscCollapsed
                  ? null
                  : (d) => setState(() {
                        final avail = c.maxHeight - _CandlePainter.padV - _CandlePainter.timeAxisH;
                        _oscFraction = (_oscFraction - d.delta.dy / avail).clamp(0.15, 0.6);
                      }),
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(context).hintColor.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        if (widget.oscillators.isNotEmpty)
          Positioned(
            right: axisW + 2,
            top: metrics.priceTop + metrics.priceH - 11,
            child: _MiniIconButton(
              icon: _oscCollapsed ? Icons.unfold_more : Icons.unfold_less,
              onTap: () => setState(() => _oscCollapsed = !_oscCollapsed),
            ),
          ),
        // Older history loads silently in the background (like MT5): no indicator on the chart.
      ]);
    });
  }

  /// Split the canvas height into the price pane + N stacked oscillator panes.
  // Content fingerprint of the level list, so a rebuilt-but-identical list (every quote tick builds a
  // new one) does not repaint the level layer. Cached per list instance.
  List<ChartLevel>? _keyedLevels;
  int _keyedHash = 0;
  int _levelsKey(List<ChartLevel> lv) {
    if (identical(lv, _keyedLevels)) return _keyedHash;
    var h = lv.length;
    for (final l in lv) {
      h = Object.hash(h, l.price, l.color.toARGB32(), l.label, l.kind, l.boxed, l.draggable, l.dashed, l.plColor?.toARGB32(), l.id);
    }
    _keyedLevels = lv;
    return _keyedHash = h;
  }

  // The price range the candle painter itself uses (same inputs), so both layers share one scale.
  List<Candle>? _rangeWindow;
  ({double hi, double lo})? _rangeVal;
  double _rangeV = 0, _rangeZ = 1;
  List<ChartLevel>? _rangeLevels;
  ({double hi, double lo}) _levelsRange(List<Candle> window, int start, List<dynamic> oscs) {
    final cached = _rangeVal;
    if (cached != null && identical(window, _rangeWindow) && identical(widget.levels, _rangeLevels) && _rangeV == _vShift && _rangeZ == _priceZoom) return cached;
    _rangeWindow = window;
    _rangeLevels = widget.levels;
    _rangeV = _vShift;
    _rangeZ = _priceZoom;
    return _rangeVal = chartRange(window, widget.levels, extra: overlayValuesInWindow(widget.overlays, start, start + window.length), vShift: _vShift, priceZoom: _priceZoom);
  }

  _PaneMetrics _paneMetrics(double h, int nOsc) => _computePaneMetrics(
        h,
        nOsc,
        _oscFraction,
        _CandlePainter.padV,
        _CandlePainter.timeAxisH,
      );
}

/// Vertical layout of the price pane and stacked oscillator panes. Pure so the
/// widget and the painter compute identical geometry.
class _PaneMetrics {
  final double priceTop;
  final double priceH;
  final double oscTop; // top of the first oscillator pane
  final double paneH; // height of a single oscillator pane
  const _PaneMetrics(this.priceTop, this.priceH, this.oscTop, this.paneH);
}

const double _oscGap = 10;

_PaneMetrics _computePaneMetrics(double h, int nOsc, double oscFraction, double padV, double timeAxisH) {
  final avail = h - padV - timeAxisH;
  if (nOsc <= 0) return _PaneMetrics(padV, avail, padV + avail, 0);
  final oscTotal = (avail * oscFraction).clamp(60.0, math.max(60.0, avail - 90.0));
  final priceH = avail - oscTotal - _oscGap;
  final paneH = (oscTotal - _oscGap * (nOsc - 1)) / nOsc;
  return _PaneMetrics(padV, priceH, padV + priceH + _oscGap, paneH);
}

/// Entry / SL / TP / pending lines, their axis tags and inline labels. Own layer (see the overlay in
/// [_CandleChartState.build]); repaints only when the levels, the price scale or a drag change.
///
/// Cost is kept flat however many trades are open:
///  * a dashed line is ONE rectangle filled with a repeating dash gradient (not ~50 separate segments);
///  * a label / axis tag that would land on top of another is skipped for that paint (the LINE is
///    always drawn). Which one wins is decided by priority - a line being edited, then an entry (its
///    P/L), then SL, then TP - and everything is measured in pixels each paint, so a hidden label
///    comes back by itself as soon as there is room (zoom, scale change, a neighbouring trade closing).
class _LevelsPainter extends CustomPainter {
  _LevelsPainter({
    required this.levels,
    required this.contentKey,
    required this.hi,
    required this.lo,
    required this.digits,
    required this.axisW,
    required this.oscCount,
    required this.oscFraction,
    required this.dragLevelKey,
    required this.dragLevelPrice,
    required this.surface,
  });
  final List<ChartLevel> levels;
  final int contentKey;
  final double hi, lo;
  final int digits;
  final double axisW;
  final int oscCount;
  final double oscFraction;
  final String? dragLevelKey;
  final double? dragLevelPrice;
  final Color surface;

  /// Lower paints first and wins an overlap.
  static int _priority(ChartLevel l, bool dragging) {
    if (dragging || l.draggable) return 0;
    return switch (l.kind) {
      LevelKind.draft => 0,
      LevelKind.entry || LevelKind.pending || LevelKind.limit => 1,
      LevelKind.sl => 2,
      LevelKind.tp => 3,
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - axisW;
    final m = _computePaneMetrics(size.height, oscCount, oscFraction, _CandlePainter.padV, _CandlePainter.timeAxisH);
    final priceTop = m.priceTop, chartH = m.priceH;
    final range = (hi - lo) == 0 ? 1 : (hi - lo);
    double y(double p) => priceTop + (hi - p) / range * chartH;

    final shown = <(ChartLevel, double, double, bool)>[];
    for (final lv in levels) {
      if (lv.price <= 0) continue;
      final dragging = dragLevelKey != null && '${lv.kind.name}:${lv.id ?? lv.label}' == dragLevelKey && dragLevelPrice != null;
      final price = dragging ? dragLevelPrice! : lv.price;
      final yy = y(price);
      if (yy < priceTop - 1 || yy > priceTop + chartH + 1) continue; // off-screen line
      shown.add((lv, price, yy, dragging));
    }
    if (shown.isEmpty) return;

    // The dashed lines: 3 px on / 4 px off from x = 0, stopping short of the price axis, as before -
    // one gradient-filled rectangle per line.
    final end = chartW - 3;
    final shaders = <int, Paint>{};
    for (final (lv, _, yy, dragging) in shown) {
      final color = lv.color.withValues(alpha: dragging ? 0.95 : 0.7);
      final width = dragging ? 1.0 : kLevelStroke;
      final paint = shaders.putIfAbsent(
          Object.hash(color.toARGB32(), width),
          () => Paint()
            ..shader = ui.Gradient.linear(
              Offset.zero,
              const Offset(7, 0),
              [color, color, color.withValues(alpha: 0), color.withValues(alpha: 0)],
              const [0, 3 / 7, 3 / 7, 1],
              TileMode.repeated,
            ));
      canvas.drawRect(Rect.fromLTRB(0, yy - width / 2, end, yy + width / 2), paint);
    }

    // Axis tags and inline labels, in priority order; one that would overlap an already placed one
    // of its own kind is skipped.
    final order = [for (var i = 0; i < shown.length; i++) i]
      ..sort((a, b) {
        final c = _priority(shown[a].$1, shown[a].$4).compareTo(_priority(shown[b].$1, shown[b].$4));
        return c != 0 ? c : a.compareTo(b);
      });
    final labelH = _TextCache.get('Ag', 11, Colors.black, FontWeight.w600).height;
    final tags = _Occupied(), labels = _Occupied();
    for (final i in order) {
      final (lv, price, yy, _) = shown[i];
      if (tags.tryTake(yy - 8, yy + 8)) _tag(canvas, chartW, yy, price.toStringAsFixed(digits), lv.color);
      final labelText = lv.labelFor?.call(price) ?? lv.label;
      if (lv.boxed) {
        if (labels.tryTake(yy - 8, yy + 8)) {
          final lt = _TextCache.rich('b|$labelText', () => TextSpan(text: ' $labelText ', style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700)));
          final rr = Rect.fromLTWH(2, yy - 8, lt.width, 16);
          canvas.drawRRect(RRect.fromRectAndRadius(rr, const Radius.circular(3)), Paint()..color = lv.color);
          lt.paint(canvas, Offset(2, yy - 6));
        }
      } else if (labels.tryTake(yy - labelH - 1, yy)) {
        // Inline MT5 label: coloured text sitting just above its own line, no box. A soft halo in the
        // chart background keeps the text readable over candles.
        final labelStyle = TextStyle(color: lv.color, fontSize: 11, fontWeight: FontWeight.w600, shadows: [Shadow(color: surface, blurRadius: 3), Shadow(color: surface, blurRadius: 3)]);
        final split = lv.plColor == null ? -1 : labelText.lastIndexOf(', ');
        final it = _TextCache.rich(
          'i|${lv.color.toARGB32()}|${surface.toARGB32()}|${lv.plColor?.toARGB32()}|$split|$labelText',
          () => split < 0
              ? TextSpan(text: labelText, style: labelStyle)
              : TextSpan(style: labelStyle, children: [
                  TextSpan(text: labelText.substring(0, split + 2)),
                  TextSpan(text: labelText.substring(split + 2), style: labelStyle.copyWith(color: lv.plColor)),
                ]),
          maxWidth: math.max(10, chartW - 8),
        );
        it.paint(canvas, Offset(3, yy - it.height - 1));
      }
      if (lv.draggable) {
        // Grab handle at the right end — shows the line can be moved.
        final hc = Offset(chartW - 16, yy);
        canvas.drawCircle(hc, 8, Paint()..color = lv.color);
        canvas.drawCircle(hc, 8, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1);
        for (final dy in const [-2.0, 2.0]) {
          canvas.drawLine(Offset(hc.dx - 3.5, hc.dy + dy), Offset(hc.dx + 3.5, hc.dy + dy), Paint()..color = Colors.white..strokeWidth = 1.2);
        }
      }
    }
  }

  void _tag(Canvas c, double chartW, double yy, String txt, Color color) {
    final t = _TextCache.get(txt, 9.5, Colors.white, FontWeight.w700);
    final rect = Rect.fromLTWH(chartW + 1, yy - 8, axisW - 2, 16);
    c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = color);
    t.paint(c, Offset(chartW + 5, yy - 6));
  }

  @override
  bool shouldRepaint(covariant _LevelsPainter old) =>
      old.contentKey != contentKey ||
      old.hi != hi ||
      old.lo != lo ||
      old.digits != digits ||
      old.axisW != axisW ||
      old.oscCount != oscCount ||
      old.oscFraction != oscFraction ||
      old.dragLevelKey != dragLevelKey ||
      old.dragLevelPrice != dragLevelPrice ||
      old.surface != surface;
}

/// Vertical spans already taken by labels (or tags) of one paint.
class _Occupied {
  final List<double> _from = [], _to = [];

  /// Reserves [from, to) unless it overlaps a span already taken; returns whether it was free.
  bool tryTake(double from, double to) {
    for (var i = 0; i < _from.length; i++) {
      if (from < _to[i] && to > _from[i]) return false;
    }
    _from.add(from);
    _to.add(to);
    return true;
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.candles,
    required this.winStart,
    required this.trailingGap,
    required this.slotW,
    required this.xShift,
    required this.totalBars,
    required this.futureSlots,
    required this.digits,
    required this.tf,
    required this.livePrice,
    required this.askPrice,
    required this.type,
    required this.levels,
    required this.overlays,
    required this.oscillators,
    required this.oscFraction,
    required this.drawings,
    required this.pendingAnchors,
    required this.previewType,
    required this.moveAnchors,
    required this.selectedId,
    required this.dragIndex,
    required this.dragAnchor,
    required this.cross,
    required this.vShift,
    required this.priceZoom,
    required this.dragLevelKey,
    required this.dragLevelPrice,
    required this.up,
    required this.down,
    required this.bid,
    required this.ask,
    required this.grid,
    required this.text,
    required this.line,
    required this.surface,
    required this.onSurface,
    required this.axisW,
  });

  final List<Candle> candles;
  final int winStart; // index in the full series of candles[0]
  final double slotW; // candle slot width in px (fractional; same for every bar)
  final double xShift; // px offset of candles[0]'s slot from the left edge
  final int totalBars; // length of the full series (labels are anchored to the global bar index)
  final int trailingGap; // empty candle-slots reserved on the right edge
  final int futureSlots; // extra right-side slots for Ichimoku's forward cloud
  final int digits;
  final Timeframe tf;
  final double? livePrice;
  final double? askPrice;
  final ChartType type;
  final List<ChartLevel> levels;
  final List<ComputedIndicator> overlays;
  final List<ComputedIndicator> oscillators;
  final double oscFraction;
  final List<DrawingObject> drawings;
  final List<DrawingAnchor> pendingAnchors;

  /// The tool being placed (draws the live preview in its own shape) and, while a whole drawing is
  /// being dragged, its live anchors.
  final DrawingType? previewType;
  final List<DrawingAnchor>? moveAnchors;
  final String? selectedId;
  final int? dragIndex;
  final DrawingAnchor? dragAnchor;
  final Offset? cross;
  final double vShift;
  final double priceZoom;
  final String? dragLevelKey;
  final double? dragLevelPrice;
  final Color up, down, grid, text, line, surface, onSurface;
  final Color bid, ask;

  /// Right price-ladder width — measured from the actual label text each
  /// build (see [_CandleChartState._computeAxisWidth]) so a symbol with fewer
  /// price digits doesn't carry the same fixed margin as one with more.
  final double axisW;
  static const double padV = 2; // top padding (reduced empty space above candles)
  static const double timeAxisH = 18; // bottom time-axis height
  static const int priceRows = 8; // price-ladder rows

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final chartW = size.width - axisW;
    final m = _computePaneMetrics(size.height, oscillators.length, oscFraction, padV, timeAxisH);
    final priceTop = m.priceTop, chartH = m.priceH;

    final r = chartRange(candles, levels, extra: overlayValuesInWindow(overlays, winStart, winStart + candles.length), vShift: vShift, priceZoom: priceZoom);
    final hi = r.hi, lo = r.lo;
    final range = (hi - lo) == 0 ? 1 : (hi - lo);
    double y(double p) => priceTop + (hi - p) / range * chartH;
    // Divide the width across the visible candles PLUS the reserved right-margin
    // slots and any Ichimoku future-projection slots, so the newest bar sits
    // `trailingGap` slots left of the price axis and the cloud has room ahead.
    final slot = slotW;

    // ── Price scale: separator line + tick marks + price labels (MT5 look). ──
    // MT5 frames the plot: a line along the top, one down the price scale and one
    // above the time scale, clearly stronger than the grid.
    final framePaint = Paint()
      ..color = text.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final plotBottom = size.height - timeAxisH;
    canvas.drawLine(const Offset(0, 0.5), Offset(size.width, 0.5), framePaint);
    canvas.drawLine(Offset(chartW, 0), Offset(chartW, plotBottom), framePaint);
    // Ends at the price-axis line (┘), it does not run on under the price numbers.
    canvas.drawLine(Offset(0, plotBottom), Offset(chartW, plotBottom), framePaint);
    final tickPaint = Paint()
      ..color = text
      ..strokeWidth = 0.8;
    for (var i = 0; i <= priceRows; i++) {
      final p = hi - range * i / priceRows;
      final yy = y(p);
      // No tick where the price lands on the frame's top / bottom edge — it would poke out
      // past the corner (the frame line itself already marks that position).
      if (yy > 2 && yy < plotBottom - 2) canvas.drawLine(Offset(chartW, yy), Offset(chartW + 4, yy), tickPaint);
      // Keep the first / last ladder price fully inside the frame instead of letting the
      // top / bottom rule strike through it.
      _TextCache.get(p.toStringAsFixed(digits), 9, text).paint(canvas, Offset(chartW + 8, (yy - 5).clamp(3.0, plotBottom - 13.0)));
    }

    // ── Time scale: labels along the bottom (no vertical gridlines). ──
    final labelEvery = math.max(1, (70 / slot).ceil()); // ~70px between labels
    final axisY = size.height - timeAxisH + 3;
    for (var i = candles.length - 1; i >= 0; i--) {
      // Anchored to the global bar index (counted from the newest), so a label stays glued to its bar
      // while the chart pans instead of hopping to a neighbour.
      if ((totalBars - 1 - (winStart + i)) % labelEvery != 0) continue;
      final cx = xShift + slot * i + slot / 2;
      if (cx < 14) break;
      if (cx > chartW - 14) continue;
      final lbl = _TextCache.get(_timeLabel(candles[i], tf), 9, text);
      lbl.paint(canvas, Offset(cx - lbl.width / 2, axisY));
    }

    // ── Price series (candles / line). Clipped to the price pane. ──
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, chartW, priceTop + chartH));
    canvas.translate(xShift, 0);
    if (type == ChartType.line) {
      final path = Path();
      for (var i = 0; i < candles.length; i++) {
        final cx = slot * i + slot / 2;
        final yy = y(candles[i].c);
        i == 0 ? path.moveTo(cx, yy) : path.lineTo(cx, yy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = line
            ..strokeWidth = 1.6
            ..style = PaintingStyle.stroke);
    } else {
      final bodyW = (slot * 0.7).clamp(1.0, 11.0);
      final wickPaint = Paint()..strokeWidth = kWickStroke;
      final bodyPaint = Paint()..style = PaintingStyle.fill;
      for (var i = 0; i < candles.length; i++) {
        final k = candles[i];
        final cx = slot * i + slot / 2;
        final isUp = k.c >= k.o;
        final color = isUp ? up : down;
        // Wick (high–low shadow): thinner and cleaner. Bodies are untouched.
        canvas.drawLine(Offset(cx, y(k.h)), Offset(cx, y(k.l)), wickPaint..color = color);
        // Body.
        final top = y(isUp ? k.c : k.o);
        final bot = y(isUp ? k.o : k.c);
        final rect = Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, bot == top ? top + 1 : bot);
        canvas.drawRect(rect, bodyPaint..color = color);
      }
    }

    // ── Indicator overlays (moving averages, Bollinger, Ichimoku). ──
    for (final ind in overlays) {
      // Ichimoku Kumo: fill between Senkou A (lines[2]) and Senkou B (lines[3])
      // under the lines.
      if (ind.ichimokuCloud && ind.lines.length >= 4) {
        _paintCloud(canvas, ind.lines[2], ind.lines[3], slot, y);
      }
      for (final ln in ind.lines) {
        _paintSeriesLine(canvas, ln, slot, y);
      }
    }
    canvas.restore();

    // ── Live Bid / Ask price lines (MT5-style) ──
    // Pinned to their TRUE position on the price scale, so they travel with the
    // candles when panned (leaving the view when their price does) instead of
    // being clamped to the edge. Bid keeps the candle-price line's historical
    // role (server bars are bid-based, so it stays continuous with the
    // candles); Ask is the same live quote's ask leg. Colour-coded like the
    // SELL / BUY panels so the two read apart at a glance, with the gap
    // between them tracking the real spread live.
    final bidPx = livePrice ?? candles.last.c;
    final bidY = y(bidPx);
    if (bidY >= priceTop && bidY <= priceTop + chartH) {
      _hline(canvas, bidY, chartW, bid, dashed: true);
      _tag(canvas, chartW, bidY, bidPx.toStringAsFixed(digits), bid, bold: true);
    }
    final askPx = askPrice;
    if (askPx != null) {
      final askY = y(askPx);
      if (askY >= priceTop && askY <= priceTop + chartH) {
        _hline(canvas, askY, chartW, ask, dashed: true);
        _tag(canvas, chartW, askY, askPx.toStringAsFixed(digits), ask, bold: true);
      }
    }

    // Order lines (entry / SL / TP / pending / draft) are painted by [_LevelsPainter], on their own
    // layer above this one, so panning the candles does not repaint every trade line each frame.

    // ── User drawings (horizontal line / trendline / Fibonacci). ──
    _paintDrawings(canvas, chartW, priceTop, chartH, slot, y);

    // ── Oscillator sub-panes (stacked below the price pane). ──
    for (var pi = 0; pi < oscillators.length; pi++) {
      final paneTop = m.oscTop + pi * (m.paneH + _oscGap);
      _paintOscPane(canvas, oscillators[pi], paneTop, m.paneH, chartW, slot);
    }

    // Crosshair.
    if (cross != null) {
      final cx = cross!.dx.clamp(0, chartW).toDouble();
      final ch = Paint()
        ..color = onSurface.withValues(alpha: 0.5)
        ..strokeWidth = 0.7;
      // Vertical line spans every pane; horizontal + readout stay in the price pane.
      _dash(canvas, Offset(cx, padV), Offset(cx, size.height - timeAxisH), ch);
      final cy = cross!.dy.clamp(priceTop, priceTop + chartH).toDouble();
      _dash(canvas, Offset(0, cy), Offset(chartW, cy), ch);
      final idx = ((cx - xShift) / slot).floor().clamp(0, candles.length - 1);
      final k = candles[idx];
      final priceAt = hi - (cy - priceTop) / chartH * range;
      _tag(canvas, chartW, cy, priceAt.toStringAsFixed(digits), onSurface);
      final info = 'O ${k.o.toStringAsFixed(digits)}  H ${k.h.toStringAsFixed(digits)}\n'
          'L ${k.l.toStringAsFixed(digits)}  C ${k.c.toStringAsFixed(digits)}\n'
          '${_timeLabel(k, tf)}';
      final ip = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(text: info, style: TextStyle(color: onSurface, fontSize: 10, height: 1.3)),
      )..layout();
      // Below the symbol caption (top-left), so the two never overlap.
      final box = Rect.fromLTWH(6, 66, ip.width + 12, ip.height + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()..color = surface.withValues(alpha: 0.92));
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)),
          Paint()
            ..color = grid
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5);
      ip.paint(canvas, const Offset(12, 70));
    }
  }

  /// Draw one indicator line over the visible window, mapping through [toY] and
  /// breaking the path across null (warm-up) gaps. Dot-style lines (e.g. PSAR)
  /// are drawn as discrete points rather than a connected path.
  void _paintSeriesLine(Canvas canvas, ComputedLine ln, double slot, double Function(double) toY) {
    if (ln.dots) {
      final dot = Paint()
        ..color = Color(ln.colorArgb)
        ..style = PaintingStyle.fill;
      final r = (ln.width * 0.7).clamp(1.0, 2.6);
      for (var i = 0; i < candles.length; i++) {
        final v = ln.values[winStart + i];
        if (v == null) continue;
        canvas.drawCircle(Offset(slot * (i + ln.shift) + slot / 2, toY(v)), r, dot);
      }
      return;
    }
    final paint = Paint()
      ..color = Color(ln.colorArgb)
      ..strokeWidth = ln.width
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    var pen = false;
    for (var i = 0; i < candles.length; i++) {
      final v = ln.values[winStart + i];
      if (v == null) {
        pen = false;
        continue;
      }
      final cx = slot * (i + ln.shift) + slot / 2;
      final yy = toY(v);
      if (!pen) {
        path.moveTo(cx, yy);
        pen = true;
      } else {
        path.lineTo(cx, yy);
      }
    }
    canvas.drawPath(path, paint);
  }

  /// Fill the Ichimoku Kumo between two spans (same shift), per segment, tinted
  /// green where Senkou A ≥ B (bullish) and red where A < B (bearish).
  void _paintCloud(Canvas canvas, ComputedLine a, ComputedLine b, double slot, double Function(double) toY) {
    final shift = a.shift;
    for (var i = 0; i < candles.length - 1; i++) {
      final a0 = a.values[winStart + i], a1 = a.values[winStart + i + 1];
      final b0 = b.values[winStart + i], b1 = b.values[winStart + i + 1];
      if (a0 == null || a1 == null || b0 == null || b1 == null) continue;
      final x0 = slot * (i + shift) + slot / 2;
      final x1 = slot * (i + 1 + shift) + slot / 2;
      final path = Path()
        ..moveTo(x0, toY(a0))
        ..lineTo(x1, toY(a1))
        ..lineTo(x1, toY(b1))
        ..lineTo(x0, toY(b0))
        ..close();
      final bullish = (a0 + a1) >= (b0 + b1);
      canvas.drawPath(path, Paint()..color = (bullish ? up : down).withValues(alpha: 0.16));
    }
  }

  double _xForTime(int t, double slot) => xForTimeInWindow(candles, t, slot) + xShift;

  void _paintDrawings(Canvas canvas, double chartW, double priceTop, double chartH, double slot, double Function(double) y) {
    if (drawings.isEmpty && pendingAnchors.isEmpty) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, priceTop, chartW, priceTop + chartH));
    for (final d in drawings) {
      // Apply the live drag override to the selected drawing while it's moving.
      var anchors = d.anchors;
      if (d.id == selectedId && dragIndex != null && dragAnchor != null) {
        anchors = d.withAnchor(dragIndex!, dragAnchor!).anchors;
      }
      if (d.id == selectedId && moveAnchors != null) anchors = moveAnchors!;
      _paintOneDrawing(canvas, d.type, anchors, Color(d.colorArgb), chartW, slot, y);
      // Selection handles.
      if (d.id == selectedId) {
        final fill = Paint()..color = Color(d.colorArgb);
        final ring = Paint()
          ..color = surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        for (final a in anchors) {
          final o = Offset(_xForTime(a.t, slot), y(a.price));
          canvas.drawCircle(o, 5, fill);
          canvas.drawCircle(o, 5, ring);
        }
      }
    }
    // Placement preview: the anchors tapped so far as small rings.
    if (pendingAnchors.isNotEmpty) {
      final c = Color(previewType?.defaultColor ?? (pendingAnchors.length < 2 ? 0xFFFFB74D : 0xFF42A5F5));
      _paintOneDrawing(canvas, previewType ?? DrawingType.trendline, pendingAnchors, c, chartW, slot, y);
      for (final a in pendingAnchors) {
        canvas.drawCircle(Offset(_xForTime(a.t, slot), y(a.price)), 4,
            Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }
    canvas.restore();
  }

  void _paintOneDrawing(Canvas canvas, DrawingType type, List<DrawingAnchor> anchors, Color color, double chartW, double slot, double Function(double) y) {
    if (anchors.isEmpty) return;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    switch (type) {
      case DrawingType.horizontalLine:
        final yy = y(anchors.first.price);
        canvas.drawLine(Offset(0, yy), Offset(chartW, yy), stroke);
        _drawTag(canvas, chartW, yy, anchors.first.price.toStringAsFixed(digits), color);
        break;
      case DrawingType.verticalLine:
        final xv = _xForTime(anchors.first.t, slot);
        canvas.drawLine(Offset(xv, 0), Offset(xv, 4000), stroke);
        break;
      case DrawingType.trendline:
        if (anchors.length < 2) break;
        canvas.drawLine(
          Offset(_xForTime(anchors[0].t, slot), y(anchors[0].price)),
          Offset(_xForTime(anchors[1].t, slot), y(anchors[1].price)),
          stroke,
        );
        break;
      case DrawingType.ray:
        if (anchors.length < 2) break;
        final ra = Offset(_xForTime(anchors[0].t, slot), y(anchors[0].price));
        final rb = Offset(_xForTime(anchors[1].t, slot), y(anchors[1].price));
        final rd = rb - ra;
        // Runs from the first point through the second, off the edge of the plot.
        canvas.drawLine(ra, rd.distance == 0 ? rb : ra + rd / rd.distance * 4000, stroke);
        break;
      case DrawingType.arrow:
        if (anchors.length < 2) break;
        final aa = Offset(_xForTime(anchors[0].t, slot), y(anchors[0].price));
        final ab = Offset(_xForTime(anchors[1].t, slot), y(anchors[1].price));
        canvas.drawLine(aa, ab, stroke);
        final ad = ab - aa;
        if (ad.distance > 0) {
          final u = ad / ad.distance;
          final n = Offset(-u.dy, u.dx);
          final head = Path()
            ..moveTo(ab.dx, ab.dy)
            ..lineTo((ab - u * 11 + n * 5).dx, (ab - u * 11 + n * 5).dy)
            ..lineTo((ab - u * 11 - n * 5).dx, (ab - u * 11 - n * 5).dy)
            ..close();
          canvas.drawPath(head, Paint()..color = color);
        }
        break;
      case DrawingType.rectangle:
      case DrawingType.ellipse:
        if (anchors.length < 2) break;
        final box = Rect.fromPoints(
          Offset(_xForTime(anchors[0].t, slot), y(anchors[0].price)),
          Offset(_xForTime(anchors[1].t, slot), y(anchors[1].price)),
        );
        final fill = Paint()..color = color.withValues(alpha: 0.14);
        if (type == DrawingType.rectangle) {
          canvas.drawRect(box, fill);
          canvas.drawRect(box, stroke);
        } else {
          canvas.drawOval(box, fill);
          canvas.drawOval(box, stroke);
        }
        break;
      case DrawingType.fibRetracement:
        if (anchors.length < 2) break;
        final a = anchors[0], b = anchors[1];
        final xa = _xForTime(a.t, slot), xb = _xForTime(b.t, slot);
        final left = math.min(xa, xb);
        final tpF = TextPainter(textDirection: TextDirection.ltr);
        for (final lv in kFibLevels) {
          final p = a.price + lv * (b.price - a.price);
          final yy = y(p);
          canvas.drawLine(Offset(left, yy), Offset(chartW, yy),
              Paint()..color = color.withValues(alpha: lv == 0 || lv == 1 ? 0.9 : 0.55)..strokeWidth = 1);
          tpF.text = TextSpan(
            text: '${(lv * 100).toStringAsFixed(1)}  ${p.toStringAsFixed(digits)}',
            style: TextStyle(color: color, fontSize: 8.5),
          );
          tpF.layout();
          tpF.paint(canvas, Offset(left + 2, yy - 10));
        }
        // Trend leg connecting the two anchors.
        canvas.drawLine(Offset(xa, y(a.price)), Offset(xb, y(b.price)),
            Paint()..color = color.withValues(alpha: 0.5)..strokeWidth = 1);
        break;
    }
  }

  /// Right-axis price tag for a drawing (mirrors the position-level tag).
  void _drawTag(Canvas canvas, double chartW, double yy, String txt, Color color) =>
      _tag(canvas, chartW, yy, txt, color);

  void _paintOscPane(Canvas canvas, ComputedIndicator ind, double top, double h, double chartW, double slot) {
    // Top separator across the pane.
    canvas.drawLine(Offset(0, top), Offset(chartW, top), Paint()
      ..color = grid
      ..strokeWidth = 1);

    // Pane vertical range.
    double lo, hi;
    if (ind.fixedRange != null) {
      lo = ind.fixedRange!.lo;
      hi = ind.fixedRange!.hi;
    } else {
      double mn = double.infinity, mx = double.negativeInfinity;
      for (var i = winStart; i < winStart + candles.length; i++) {
        for (final ln in ind.lines) {
          final v = ln.values[i];
          if (v != null) {
            if (v < mn) mn = v;
            if (v > mx) mx = v;
          }
        }
        if (ind.histogram != null) {
          final v = ind.histogram!.values[i];
          if (v != null) {
            if (v < mn) mn = v;
            if (v > mx) mx = v;
          }
        }
      }
      if (mn == double.infinity) {
        mn = 0;
        mx = 1;
      }
      if (ind.zeroLine) {
        final a = math.max(mx.abs(), mn.abs());
        mn = -a;
        mx = a;
      }
      final pad = (mx - mn) * 0.12;
      lo = mn - pad;
      hi = mx + pad;
    }
    if (ind.volumeBars) lo = 0; // volume rises from a zero baseline
    final range = (hi - lo) == 0 ? 1 : (hi - lo);
    double yy(double v) => top + (hi - v.clamp(lo, hi)) / range * h;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, chartW, top + h));

    // Guide levels (RSI 30/70, Stoch 20/80).
    for (final g in ind.guides) {
      if (g < lo || g > hi) continue;
      final gy = yy(g);
      _hlineFaint(canvas, gy, chartW, text);
      final gt = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(text: g.toStringAsFixed(0), style: TextStyle(color: text, fontSize: 8)),
      )..layout();
      gt.paint(canvas, Offset(chartW + 2, gy - 5));
    }
    // Zero baseline (MACD).
    if (ind.zeroLine && 0 >= lo && 0 <= hi) {
      canvas.drawLine(Offset(0, yy(0)), Offset(chartW, yy(0)), Paint()
        ..color = text.withValues(alpha: 0.5)
        ..strokeWidth = 0.8);
    }

    canvas.translate(xShift, 0); // bars / lines below move with the chart; guides above span the pane
    // Histogram bars (MACD), sign-colored with the theme up/down.
    final hist = ind.histogram;
    if (hist != null) {
      final zeroY = (0 >= lo && 0 <= hi) ? yy(0) : top + h;
      final bw = (slot * 0.6).clamp(1.0, 9.0);
      for (var i = 0; i < candles.length; i++) {
        final v = hist.values[winStart + i];
        if (v == null) continue;
        final cx = slot * i + slot / 2;
        final vy = yy(v);
        final rect = Rect.fromLTRB(cx - bw / 2, math.min(vy, zeroY), cx + bw / 2, math.max(vy, zeroY));
        canvas.drawRect(rect, Paint()..color = (v >= 0 ? up : down).withValues(alpha: 0.55));
      }
    }

    // Volume bars (rising from zero, colored by each candle's direction), or
    // the regular oscillator lines.
    if (ind.volumeBars && ind.lines.isNotEmpty) {
      final vals = ind.lines.first.values;
      final zeroY = yy(0);
      final bw = (slot * 0.6).clamp(1.0, 9.0);
      for (var i = 0; i < candles.length; i++) {
        final v = vals[winStart + i];
        if (v == null) continue;
        final cx = slot * i + slot / 2;
        final c = candles[i].c >= candles[i].o ? up : down;
        canvas.drawRect(Rect.fromLTRB(cx - bw / 2, yy(v), cx + bw / 2, zeroY),
            Paint()..color = c.withValues(alpha: 0.5));
      }
    } else {
      for (final ln in ind.lines) {
        _paintSeriesLine(canvas, ln, slot, yy);
      }
    }
    canvas.restore();

    // Pane header label.
    final ht = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(text: ind.label.isEmpty ? ind.type.shortName : ind.label, style: TextStyle(color: text, fontSize: 9.5, fontWeight: FontWeight.w600)),
    )..layout();
    ht.paint(canvas, Offset(4, top + 2));

    // Right-axis: hi / lo (fixed-range panes also show the midpoint).
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void axisLabel(double v, double atY) {
      tp.text = TextSpan(text: _oscNum(v), style: TextStyle(color: text, fontSize: 8));
      tp.layout();
      tp.paint(canvas, Offset(chartW + 4, atY - 4));
    }
    axisLabel(hi, top + 4);
    axisLabel(lo, top + h - 8);
  }

  String _oscNum(double v) {
    final a = v.abs();
    if (a >= 100) return v.toStringAsFixed(0);
    if (a >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  /// HH:MM for intraday timeframes, D/M for daily/weekly, M/YY for monthly —
  /// from the bar's open time.
  String _timeLabel(Candle k, Timeframe tf) {
    final d = k.date.toLocal();
    if (tf == Timeframe.mn1) return '${d.month}/${(d.year % 100).toString().padLeft(2, '0')}';
    if (tf == Timeframe.d1 || tf == Timeframe.w1) return '${d.day}/${d.month}';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  void _hline(Canvas c, double yy, double w, Color color, {bool dashed = false, double width = 1, double dash = 4, double gap = 3}) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width;
    if (dashed) {
      // MT5 dash: short dashes with small gaps, stopping a few px short of the price
      // axis so the line never runs into the axis rule or the price tag.
      final end = w - 3;
      for (double x = 0; x < end; x += dash + gap) {
        c.drawLine(Offset(x, yy), Offset(math.min(x + dash, end), yy), p);
      }
    } else {
      c.drawLine(Offset(0, yy), Offset(w, yy), p);
    }
  }

  void _hlineFaint(Canvas c, double yy, double w, Color color) {
    final p = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 0.7;
    for (double x = 0; x < w; x += 8) {
      c.drawLine(Offset(x, yy), Offset(x + 4, yy), p);
    }
  }

  void _dash(Canvas c, Offset a, Offset b, Paint p) {
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    for (double d = 0; d < total; d += 6) {
      c.drawLine(a + dir * d, a + dir * (d + 3), p);
    }
  }

  void _tag(Canvas c, double chartW, double yy, String txt, Color color, {bool bold = false}) {
    final t = _TextCache.get(txt, 9.5, Colors.white, bold ? FontWeight.w800 : FontWeight.w700);
    final rect = Rect.fromLTWH(chartW + 1, yy - 8, axisW - 2, 16);
    c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = color);
    t.paint(c, Offset(chartW + 5, yy - 6));
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) =>
      old.candles != candles ||
      old.winStart != winStart ||
      old.slotW != slotW ||
      old.xShift != xShift ||
      old.totalBars != totalBars ||
      old.trailingGap != trailingGap ||
      old.futureSlots != futureSlots ||
      old.cross != cross ||
      old.type != type ||
      old.levels != levels ||
      old.overlays != overlays ||
      old.oscillators != oscillators ||
      old.oscFraction != oscFraction ||
      old.drawings != drawings ||
      old.pendingAnchors != pendingAnchors ||
      old.previewType != previewType ||
      old.moveAnchors != moveAnchors ||
      old.selectedId != selectedId ||
      old.dragIndex != dragIndex ||
      old.dragAnchor != dragAnchor ||
      old.livePrice != livePrice ||
      old.askPrice != askPrice ||
      old.vShift != vShift ||
      old.priceZoom != priceZoom ||
      old.dragLevelKey != dragLevelKey ||
      old.dragLevelPrice != dragLevelPrice;
}

/// Small circular zoom button overlaid on the chart.
class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      shape: CircleBorder(side: BorderSide(color: Theme.of(context).dividerColor)),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }
}

/// Tiny square icon button used for the oscillator collapse toggle.
class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(5),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }
}
