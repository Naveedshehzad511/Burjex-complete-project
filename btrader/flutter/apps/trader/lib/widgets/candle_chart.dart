import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:btrader_core/btrader_core.dart';

enum ChartType { candles, line }

/// A horizontal price level to draw on the chart (entry / SL / TP / current).
class ChartLevel {
  final double price;
  final Color color;
  final String label;
  final bool dashed;
  const ChartLevel(this.price, this.color, this.label, {this.dashed = true});
}

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
({double hi, double lo}) chartRange(List<Candle> cs, List<ChartLevel> levels,
    {List<double> extra = const []}) {
  var hi = cs.first.h, lo = cs.first.l;
  for (final k in cs) {
    if (k.h > hi) hi = k.h;
    if (k.l < lo) lo = k.l;
  }
  // Always fold open-position / SL / TP levels into the range so they're never
  // hidden (the chart auto-scales to keep your trade in view, MT5-style).
  for (final lv in levels) {
    if (lv.price <= 0) continue;
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
  return (hi: hi + pad, lo: lo - pad);
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
    this.type = ChartType.candles,
    this.levels = const [],
    this.overlays = const [],
    this.oscillators = const [],
    this.drawings = const [],
    this.activeTool,
    this.pendingAnchors = const [],
    this.onAnchor,
    this.onMoveAnchor,
    this.onDeleteDrawing,
    this.onPriceTap,
  });
  final List<Candle> candles;
  final int digits;
  final Timeframe tf;

  /// The current dealable price — the dashed price line locks to this and stays
  /// put while you scroll back, instead of following the last visible candle.
  final double? livePrice;
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

  /// Fired when the on-chart delete button is tapped for the selected drawing.
  final void Function(String id)? onDeleteDrawing;

  /// Called with the price the user tapped on the right price ladder (MT5-style
  /// trade-from-chart).
  final void Function(double price)? onPriceTap;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

/// How far the newest bar can be pushed off the price axis: dragging the chart
/// forward reveals up to this many empty candle-slots of headroom on the right.
/// The default view rests flush (newest bar at the axis, no gap); the margin is
/// only scroll headroom, not a resting offset — so the live forming bar never
/// looks detached from the edge.
const double _kRightPad = 5;

class _CandleChartState extends State<CandleChart> {
  double _perScreen = 80; // visible candle count (zoom)
  // Candles scrolled back from the latest. 0 = newest bar flush at the axis
  // (default); negative = dragged forward into the right-margin headroom.
  double _rightOffset = 0;
  double _lastScale = 1.0;
  double _chartW = 1;

  double _oscFraction = 0.32; // share of chart height taken by the osc region
  bool _oscCollapsed = false;

  // Drawing selection + drag. During a drag the moved anchor is held locally
  // (_dragAnchor) so only this widget repaints; the provider is updated once on
  // release, avoiding a full screen rebuild (indicator recompute) per frame.
  String? _selectedDrawingId;
  int? _dragAnchorIndex;
  DrawingAnchor? _dragAnchor;

  Offset? _cross; // crosshair local position (null = off)

  void _resetView() => setState(() {
        _perScreen = 60;
        _rightOffset = 0;
        _cross = null;
      });

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final total = widget.candles.length;
    if (total == 0) return const SizedBox.shrink();

    final oscs = _oscCollapsed ? const <ComputedIndicator>[] : widget.oscillators;

    return LayoutBuilder(builder: (_, c) {
      _chartW = (c.maxWidth - _CandlePainter.axisW).clamp(1, double.infinity);
      // Guard the zoom bounds when there are very few candles (e.g. history is
      // still rebuilding): the lower bound must never exceed the upper bound.
      final minPer = math.min(12.0, total.toDouble());
      final per = _perScreen.clamp(minPer, total.toDouble());
      final perI = per.round();
      // Split the offset into a right-edge gap (empty slots after the newest
      // bar) and a history scroll-back. The gap only exists at the right edge;
      // once you pan past it, `back` scrolls into completed history. Clamp the
      // gap so at least one candle always shows on very short series.
      final back = _rightOffset > 0 ? _rightOffset.round() : 0;
      final trailingGap = math.min((-_rightOffset).round().clamp(0, _kRightPad.round()), perI - 1);
      final dataEnd = (total - back).clamp(1, total);
      final start = (dataEnd - (perI - trailingGap)).clamp(0, total);
      final window = widget.candles.sublist(start, dataEnd);
      final overlayExtra = overlayValuesInWindow(widget.overlays, start, dataEnd);
      // Ichimoku projects its cloud into the future — reserve that many empty
      // slots on the right so the projection is visible (0 when no Ichimoku).
      final futureSlots = widget.overlays.fold<int>(0, (m, o) => math.max(m, o.futureShift));

      // Vertical geometry: reserve the osc region from the bottom (above the
      // time axis). Kept in sync with the painter so the resize handle lands on
      // the boundary line.
      final metrics = _paneMetrics(c.maxHeight, oscs.length);

      void handlePriceTap(Offset pos) {
        if (widget.onPriceTap == null || pos.dx < _chartW) return; // axis region only
        // Only the price pane's axis trades; taps on an oscillator pane's axis
        // don't map to a tradeable price.
        if (pos.dy > metrics.priceTop + metrics.priceH) return;
        final r = chartRange(window, widget.levels, extra: overlayExtra);
        final price = r.hi - (pos.dy - metrics.priceTop) / metrics.priceH * (r.hi - r.lo);
        if (price > 0) widget.onPriceTap!(price);
      }

      // Placement mode: a tap on the price pane becomes a drawing anchor. The
      // time snaps to the nearest visible bar; the price is exact.
      void handlePlacementTap(Offset pos) {
        if (widget.onAnchor == null || window.isEmpty) return;
        if (pos.dx < 0 || pos.dx >= _chartW) return;
        if (pos.dy < metrics.priceTop || pos.dy > metrics.priceTop + metrics.priceH) return;
        final slotB = _chartW / (window.length + trailingGap + futureSlots);
        final idx = (pos.dx / slotB).floor().clamp(0, window.length - 1);
        final r = chartRange(window, widget.levels, extra: overlayExtra);
        final price = r.hi - (pos.dy - metrics.priceTop) / metrics.priceH * (r.hi - r.lo);
        widget.onAnchor!(DrawingAnchor(window[idx].t, price));
      }

      void zoom(double factor) => setState(() {
            _perScreen = (_perScreen * factor).clamp(minPer, total.toDouble());
            _rightOffset = _rightOffset.clamp(-_kRightPad, math.max(0, total - _perScreen));
          });

      // ── Chart-space ↔ pixel mapping for drawing hit-testing / dragging. ──
      final slotB = _chartW / (window.length + trailingGap + futureSlots);
      final r = chartRange(window, widget.levels, extra: overlayExtra);
      final priceSpan = (r.hi - r.lo) == 0 ? 1.0 : (r.hi - r.lo);
      double pyForPrice(double p) => metrics.priceTop + (r.hi - p) / priceSpan * metrics.priceH;
      double priceAtY(double dy) =>
          r.hi - (dy.clamp(metrics.priceTop, metrics.priceTop + metrics.priceH) - metrics.priceTop) / metrics.priceH * priceSpan;
      double pxForTime(int t) => xForTimeInWindow(window, t, slotB);
      int timeAtX(double dx) => window[(dx / slotB).floor().clamp(0, window.length - 1)].t;

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
          case DrawingType.trendline:
            return distToSeg(p, Offset(pxForTime(d.anchors[0].t), pyForPrice(d.anchors[0].price)),
                    Offset(pxForTime(d.anchors[1].t), pyForPrice(d.anchors[1].price))) <
                9;
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
        for (var i = 0; i < d.anchors.length; i++) {
          if ((p.dx - pxForTime(d.anchors[i].t)).abs() < 22 && (p.dy - pyForPrice(d.anchors[i].price)).abs() < 22) {
            return i;
          }
        }
        return null;
      }

      void handleSelectOrTrade(Offset pos) {
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
        if (hit != _selectedDrawingId) setState(() => _selectedDrawingId = hit);
      }

      return Stack(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => widget.activeTool != null
              ? handlePlacementTap(d.localPosition)
              : handleSelectOrTrade(d.localPosition),
          onScaleStart: (d) {
            _lastScale = 1.0;
            _dragAnchorIndex = null;
            _dragAnchor = null;
            // Grab an anchor of the selected drawing to drag it (instead of panning).
            if (widget.activeTool == null) {
              final sel = selected();
              if (sel != null) {
                final gi = grabAnchor(sel, d.localFocalPoint);
                if (gi != null) {
                  setState(() {
                    _dragAnchorIndex = gi;
                    _dragAnchor = sel.anchors[gi];
                  });
                }
              }
            }
          },
          onScaleUpdate: (d) {
            // Dragging a drawing anchor: update the local copy only (smooth; the
            // provider is written once on release).
            if (_dragAnchorIndex != null) {
              final sel = selected();
              if (sel == null) return;
              final p = d.localFocalPoint;
              final t = sel.type == DrawingType.horizontalLine ? sel.anchors.first.t : timeAtX(p.dx);
              setState(() => _dragAnchor = DrawingAnchor(t, priceAtY(p.dy)));
              return;
            }
            setState(() {
              final s = d.scale / _lastScale;
              _lastScale = d.scale;
              if ((s - 1).abs() > 0.001) {
                _perScreen = (_perScreen / s).clamp(minPer, total.toDouble());
              }
              final slot = _chartW / _perScreen;
              _rightOffset = (_rightOffset + d.focalPointDelta.dx / slot)
                  .clamp(-_kRightPad, math.max(0, total - _perScreen));
              if (_cross != null) _cross = _cross!.translate(d.focalPointDelta.dx, d.focalPointDelta.dy);
            });
          },
          onScaleEnd: (_) {
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
          onLongPressEnd: (_) => setState(() => _cross = null),
          onDoubleTap: _resetView,
          child: CustomPaint(
            size: Size.infinite,
            painter: _CandlePainter(
              candles: window,
              winStart: start,
              trailingGap: trailingGap,
              futureSlots: futureSlots,
              digits: widget.digits,
              tf: widget.tf,
              livePrice: widget.livePrice,
              type: widget.type,
              levels: widget.levels,
              overlays: widget.overlays,
              oscillators: oscs,
              oscFraction: _oscFraction,
              drawings: widget.drawings,
              pendingAnchors: widget.pendingAnchors,
              selectedId: _selectedDrawingId,
              dragIndex: _dragAnchorIndex,
              dragAnchor: _dragAnchor,
              cross: _cross,
              up: tc.up,
              down: tc.down,
              grid: Theme.of(context).dividerColor,
              text: Theme.of(context).hintColor,
              line: Theme.of(context).colorScheme.primary,
              surface: Theme.of(context).colorScheme.surface,
              onSurface: Theme.of(context).colorScheme.onSurface,
            ),
          ),
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
            right: _CandlePainter.axisW,
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
            right: _CandlePainter.axisW + 2,
            top: metrics.priceTop + metrics.priceH - 11,
            child: _MiniIconButton(
              icon: _oscCollapsed ? Icons.unfold_more : Icons.unfold_less,
              onTap: () => setState(() => _oscCollapsed = !_oscCollapsed),
            ),
          ),
        // Zoom controls (pinch still works too).
        Positioned(
          left: 8,
          bottom: _CandlePainter.timeAxisH + 8,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _ZoomButton(icon: Icons.add, onTap: () => zoom(0.7)),
            const SizedBox(height: 8),
            _ZoomButton(icon: Icons.remove, onTap: () => zoom(1.45)),
          ]),
        ),
      ]);
    });
  }

  /// Split the canvas height into the price pane + N stacked oscillator panes.
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

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.candles,
    required this.winStart,
    required this.trailingGap,
    required this.futureSlots,
    required this.digits,
    required this.tf,
    required this.livePrice,
    required this.type,
    required this.levels,
    required this.overlays,
    required this.oscillators,
    required this.oscFraction,
    required this.drawings,
    required this.pendingAnchors,
    required this.selectedId,
    required this.dragIndex,
    required this.dragAnchor,
    required this.cross,
    required this.up,
    required this.down,
    required this.grid,
    required this.text,
    required this.line,
    required this.surface,
    required this.onSurface,
  });

  final List<Candle> candles;
  final int winStart; // index in the full series of candles[0]
  final int trailingGap; // empty candle-slots reserved on the right edge
  final int futureSlots; // extra right-side slots for Ichimoku's forward cloud
  final int digits;
  final Timeframe tf;
  final double? livePrice;
  final ChartType type;
  final List<ChartLevel> levels;
  final List<ComputedIndicator> overlays;
  final List<ComputedIndicator> oscillators;
  final double oscFraction;
  final List<DrawingObject> drawings;
  final List<DrawingAnchor> pendingAnchors;
  final String? selectedId;
  final int? dragIndex;
  final DrawingAnchor? dragAnchor;
  final Offset? cross;
  final Color up, down, grid, text, line, surface, onSurface;

  static const double axisW = 62; // right price-ladder width
  static const double padV = 12; // top padding
  static const double timeAxisH = 18; // bottom time-axis height
  static const int priceRows = 8; // price-ladder rows

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final chartW = size.width - axisW;
    final m = _computePaneMetrics(size.height, oscillators.length, oscFraction, padV, timeAxisH);
    final priceTop = m.priceTop, chartH = m.priceH;

    final r = chartRange(candles, levels, extra: overlayValuesInWindow(overlays, winStart, winStart + candles.length));
    final hi = r.hi, lo = r.lo;
    final range = (hi - lo) == 0 ? 1 : (hi - lo);
    double y(double p) => priceTop + (hi - p) / range * chartH;
    // Divide the width across the visible candles PLUS the reserved right-margin
    // slots and any Ichimoku future-projection slots, so the newest bar sits
    // `trailingGap` slots left of the price axis and the cloud has room ahead.
    final slot = chartW / (candles.length + trailingGap + futureSlots);

    // ── Price scale: separator line + tick marks + price labels (MT5 look). ──
    final axisPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(Offset(chartW, 0), Offset(chartW, size.height - timeAxisH), axisPaint);
    final tickPaint = Paint()
      ..color = text
      ..strokeWidth = 0.8;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= priceRows; i++) {
      final p = hi - range * i / priceRows;
      final yy = y(p);
      canvas.drawLine(Offset(chartW, yy), Offset(chartW + 4, yy), tickPaint);
      tp.text = TextSpan(text: p.toStringAsFixed(digits), style: TextStyle(color: text, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(chartW + 8, yy - 5));
    }

    // ── Time scale: labels along the bottom (no vertical gridlines). ──
    final labelEvery = math.max(1, (70 / slot).ceil()); // ~70px between labels
    final axisY = size.height - timeAxisH + 3;
    for (var i = candles.length - 1; i >= 0; i -= labelEvery) {
      final cx = slot * i + slot / 2;
      if (cx < 14) break;
      tp.text = TextSpan(text: _timeLabel(candles[i], tf), style: TextStyle(color: text, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, axisY));
    }

    // ── Price series (candles / line). Clipped to the price pane. ──
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, chartW, priceTop + chartH));
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
      for (var i = 0; i < candles.length; i++) {
        final k = candles[i];
        final cx = slot * i + slot / 2;
        final isUp = k.c >= k.o;
        final paint = Paint()
          ..color = isUp ? up : down
          ..strokeWidth = 1;
        // Wick (high–low shadow).
        canvas.drawLine(Offset(cx, y(k.h)), Offset(cx, y(k.l)), paint);
        // Body.
        final top = y(isUp ? k.c : k.o);
        final bot = y(isUp ? k.o : k.c);
        final rect = Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, bot == top ? top + 1 : bot);
        canvas.drawRect(rect, paint..style = PaintingStyle.fill);
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

    // ── Live price line — locked to the current dealable price. ──
    final lp = livePrice ?? candles.last.c;
    final lpY = y(lp.clamp(lo, hi));
    _hline(canvas, lpY, chartW, line, dashed: true);
    _tag(canvas, chartW, lpY, lp.toStringAsFixed(digits), line, bold: true);

    // MT5-style position levels (entry / SL / TP).
    for (final lv in levels) {
      if (lv.price <= 0) continue;
      final yy = y(lv.price);
      if (yy < priceTop - 1 || yy > priceTop + chartH + 1) continue;
      _hline(canvas, yy, chartW, lv.color, dashed: lv.dashed);
      _tag(canvas, chartW, yy, lv.price.toStringAsFixed(digits), lv.color);
      final lt = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(text: ' ${lv.label} ', style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700)),
      )..layout();
      final rr = Rect.fromLTWH(2, yy - 8, lt.width, 16);
      canvas.drawRRect(RRect.fromRectAndRadius(rr, const Radius.circular(3)), Paint()..color = lv.color);
      lt.paint(canvas, Offset(2, yy - 6));
    }

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
      final idx = (cx / slot).floor().clamp(0, candles.length - 1);
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
      final box = Rect.fromLTWH(6, 6, ip.width + 12, ip.height + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()..color = surface.withValues(alpha: 0.92));
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)),
          Paint()
            ..color = grid
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5);
      ip.paint(canvas, const Offset(12, 10));
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

  double _xForTime(int t, double slot) => xForTimeInWindow(candles, t, slot);

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
      final c = Color(pendingAnchors.length < 2 ? 0xFFFFB74D : 0xFF42A5F5);
      _paintOneDrawing(canvas, DrawingType.trendline, pendingAnchors, c, chartW, slot, y);
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
      case DrawingType.trendline:
        if (anchors.length < 2) break;
        canvas.drawLine(
          Offset(_xForTime(anchors[0].t, slot), y(anchors[0].price)),
          Offset(_xForTime(anchors[1].t, slot), y(anchors[1].price)),
          stroke,
        );
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

  void _hline(Canvas c, double yy, double w, Color color, {bool dashed = false}) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    if (dashed) {
      for (double x = 0; x < w; x += 8) {
        c.drawLine(Offset(x, yy), Offset(x + 4, yy), p);
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
    final t = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(text: txt, style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w700)),
    )..layout();
    final rect = Rect.fromLTWH(chartW + 1, yy - 8, axisW - 2, 16);
    c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = color);
    t.paint(c, Offset(chartW + 5, yy - 6));
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) =>
      old.candles != candles ||
      old.winStart != winStart ||
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
      old.selectedId != selectedId ||
      old.dragIndex != dragIndex ||
      old.dragAnchor != dragAnchor ||
      old.livePrice != livePrice;
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
