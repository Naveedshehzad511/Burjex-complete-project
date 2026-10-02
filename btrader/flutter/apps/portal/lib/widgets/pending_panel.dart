import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';

/// What the chart's edit panel is working on.
enum EditKind { draft, order, position }

/// The order modes offered by the chart's order-mode control (MT5's order tabs).
/// Stop Limit is one engine type (`STOP_LIMIT`) with an explicit side, so buy and
/// sell are separate modes here.
enum OrderMode { market, buyLimit, sellLimit, buyStop, sellStop, buyStopLimit, sellStopLimit }

extension OrderModeX on OrderMode {
  OrderType get type => switch (this) {
        OrderMode.market => OrderType.market,
        OrderMode.buyLimit => OrderType.buyLimit,
        OrderMode.sellLimit => OrderType.sellLimit,
        OrderMode.buyStop => OrderType.buyStop,
        OrderMode.sellStop => OrderType.sellStop,
        OrderMode.buyStopLimit || OrderMode.sellStopLimit => OrderType.stopLimit,
      };

  /// BUY | SELL. Market has no fixed side (the SELL / BUY buttons decide).
  String get side => switch (this) {
        OrderMode.buyLimit || OrderMode.buyStop || OrderMode.buyStopLimit => 'BUY',
        OrderMode.market => 'BUY',
        _ => 'SELL',
      };

  bool get isMarket => this == OrderMode.market;
  bool get isStopLimit => this == OrderMode.buyStopLimit || this == OrderMode.sellStopLimit;

  /// Distinct id per mode, e.g. `SELL_STOP`, `BUY_STOP_LIMIT`, `MARKET`.
  String get api => isStopLimit ? '${side}_STOP_LIMIT' : type.api;

  String get label => switch (this) {
        OrderMode.market => 'Market Execution',
        OrderMode.buyStopLimit => 'Buy Stop Limit',
        OrderMode.sellStopLimit => 'Sell Stop Limit',
        _ => type.label,
      };

  static OrderMode fromDraft(OrderType t, String side) => switch (t) {
        OrderType.buyLimit => OrderMode.buyLimit,
        OrderType.sellLimit => OrderMode.sellLimit,
        OrderType.buyStop => OrderMode.buyStop,
        OrderType.sellStop => OrderMode.sellStop,
        OrderType.stopLimit => side == 'BUY' ? OrderMode.buyStopLimit : OrderMode.sellStopLimit,
        _ => OrderMode.market,
      };
}

/// One in-progress edit made on the chart: a NEW pending order (draft), a resting
/// pending order, or the SL / TP of an open position. The chart draws its lines
/// from this and the panel edits it, so a dragged line and a typed value are the
/// same thing. Nothing reaches the server until Apply.
class ChartEdit {
  /// A new order. For [OrderType.stopLimit] pass [side] and the [limit] price
  /// ([entry] is then the stop trigger). A market draft only carries SL / TP /
  /// volume — the SELL / BUY button supplies the side.
  ChartEdit.draft({required OrderType type, required this.volume, this.entry, String? side, this.limit})
      : kind = EditKind.draft,
        id = null,
        draftType = type,
        side = side ?? (_isBuy(type.api) ? 'BUY' : 'SELL'),
        timeInForce = 'GTC';
  ChartEdit.order({required String this.id, required this.orderType, required this.side, required this.entry, this.sl, this.tp, required this.volume, this.hasStopField = false, this.limit})
      : kind = EditKind.order,
        draftType = null,
        originalVolume = volume;
  ChartEdit.position({required String this.id, required this.side, required this.entry, this.sl, this.tp})
      : kind = EditKind.position,
        draftType = null,
        orderType = null,
        volume = null;

  final EditKind kind;
  OrderType? draftType; // draft only (changes when the user picks another type)
  final String? id;
  String? orderType; // existing order: BUY_LIMIT | SELL_STOP | ...
  String side; // BUY | SELL
  double? entry;

  /// STOP_LIMIT only: the limit (fill) price; [entry] is the stop trigger.
  double? limit;
  double? sl;
  double? tp;
  double? volume;
  double? originalVolume;
  bool hasStopField = false;

  /// New-order-only fields (the backend does not support changing these when
  /// modifying a resting order — only price / stop / SL / TP / volume can change).
  /// GTC | DAY | GTD.
  String? timeInForce;
  DateTime? expiresAt;

  /// Time-in-force / expiration are only offered while placing a new
  /// order — the modify endpoint (`ModifyOrderDto`) has no fields for them.
  bool get hasTif => isDraft;

  static bool _isBuy(String t) => t.toUpperCase().startsWith('BUY');

  bool get isDraft => kind == EditKind.draft;
  bool get isOrder => kind == EditKind.order;
  bool get isPosition => kind == EditKind.position;
  bool get isMarket => isDraft && draftType == OrderType.market;
  bool get isStopLimit => typeApi.toUpperCase() == 'STOP_LIMIT';
  bool get hasEntry => !isPosition && !isMarket;
  OrderMode? get mode => isDraft ? OrderModeX.fromDraft(draftType!, side) : null;

  /// The price SL / TP are judged from: the limit for a Stop Limit (that is where it
  /// fills — same rule as the engine), otherwise the entry.
  double? get protectiveRef => isStopLimit ? limit : entry;
  bool get hasVolume => !isPosition;
  bool get isBuy => side == 'BUY';
  String get targetId => isDraft ? 'draft' : (id ?? '');

  /// e.g. `BUY_LIMIT` for both a draft and an existing order.
  String get typeApi => isDraft ? draftType!.api : (orderType ?? '');

  String get typeLabel {
    if (isStopLimit) return isBuy ? 'Buy Stop Limit' : 'Sell Stop Limit';
    if (isMarket) return 'Market';
    if (isDraft) return draftType!.label;
    return switch (typeApi.toUpperCase()) {
      'BUY_LIMIT' => 'Buy Limit',
      'SELL_LIMIT' => 'Sell Limit',
      'BUY_STOP' => 'Buy Stop',
      'SELL_STOP' => 'Sell Stop',
      _ => typeApi,
    };
  }

  /// Field-level problems, keyed `entry` / `sl` / `tp` / `volume`. Empty = valid.
  /// Mirrors the server's rules (which stay authoritative): entry on the right side
  /// of the market for its type, SL / TP on the protective side of the entry, and
  /// volume inside the symbol's min / max / lot step.
  Map<String, String> errors(Tick? q, {required double minLot, required double maxLot, required double lotStep}) {
    final out = <String, String>{};
    if (hasEntry) {
      final en = entry;
      if (en == null || !(en > 0)) {
        out['entry'] = 'Enter an entry price';
      } else if (q != null) {
        switch (typeApi.toUpperCase()) {
          case 'BUY_LIMIT':
            if (!(en < q.ask)) out['entry'] = 'Must be below the Ask';
          case 'BUY_STOP':
            if (!(en > q.ask)) out['entry'] = 'Must be above the Ask';
          case 'SELL_LIMIT':
            if (!(en > q.bid)) out['entry'] = 'Must be above the Bid';
          case 'SELL_STOP':
            if (!(en < q.bid)) out['entry'] = 'Must be below the Bid';
          case 'STOP_LIMIT':
            if (isBuy && !(en > q.ask)) out['entry'] = 'Must be above the Ask';
            if (!isBuy && !(en < q.bid)) out['entry'] = 'Must be below the Bid';
        }
      }
    }
    if (isStopLimit) {
      final lm = limit, st = entry;
      if (lm == null || !(lm > 0)) {
        out['limit'] = 'Enter a limit price';
      } else if (st != null && st > 0) {
        if (isBuy && !(lm < st)) out['limit'] = 'Must be below the stop price';
        if (!isBuy && !(lm > st)) out['limit'] = 'Must be above the stop price';
      }
    }
    final ref = protectiveRef;
    if (ref != null && ref > 0) {
      if (sl != null) {
        if (!(sl! > 0)) {
          out['sl'] = 'Invalid price';
        } else if (isBuy ? sl! >= ref : sl! <= ref) {
          out['sl'] = '${isBuy ? 'Must be below' : 'Must be above'} the ${isStopLimit ? 'limit' : 'entry'}';
        }
      }
      if (tp != null) {
        if (!(tp! > 0)) {
          out['tp'] = 'Invalid price';
        } else if (isBuy ? tp! <= ref : tp! >= ref) {
          out['tp'] = '${isBuy ? 'Must be above' : 'Must be below'} the ${isStopLimit ? 'limit' : 'entry'}';
        }
      }
    }
    if (isDraft && timeInForce == 'GTD' && expiresAt == null) {
      out['expiresAt'] = 'Pick an expiration date/time';
    }
    if (hasVolume) {
      final v = volume;
      if (v == null || !(v > 0)) {
        out['volume'] = 'Enter a volume';
      } else if (v < minLot - 1e-9) {
        out['volume'] = 'Minimum is ${minLot.toStringAsFixed(2)}';
      } else if (v > maxLot + 1e-9) {
        out['volume'] = 'Maximum is ${maxLot.toStringAsFixed(2)}';
      } else {
        final steps = v / lotStep;
        if ((steps - steps.round()).abs() > 1e-6) out['volume'] = 'Lot step is ${lotStep.toStringAsFixed(2)}';
      }
    }
    return out;
  }
}

/// The bottom sheet for placing / editing pending orders, market orders and SL / TP,
/// shown under the chart (not over it) so the lines stay draggable while it is open.
///
/// MT5-style two-state panel:
///  * collapsed (the default on every fresh open) — symbol, SL/TP quick chips, the
///    order-type row and the Place/Apply button, so the chart stays mostly visible;
///  * expanded (drag the handle up, or tap the chevron) — adds Bid/Ask, the order-type
///    grid, Entry/Stop/Limit steppers, a volume slider, and — for a brand NEW order
///    only, since modifying a resting order does not support it — Expiration.
/// Either way this reads and writes the same [ChartEdit] the chart draws its lines
/// from: there is one source of truth, never a private copy.
class PendingPanel extends StatefulWidget {
  const PendingPanel({
    super.key,
    required this.edit,
    required this.symbolLabel,
    this.symbolDescription,
    required this.digits,
    required this.quote,
    required this.minLot,
    required this.maxLot,
    required this.lotStep,
    required this.busy,
    required this.serverError,
    required this.onChanged,
    required this.onPickType,
    required this.onAddSl,
    required this.onAddTp,
    required this.onRemoveSl,
    required this.onRemoveTp,
    required this.onApply,
    required this.onClose,
    required this.onCancelOrder,
    this.onMarket,
    this.marketEnabled = true,
    this.expanded = true,
    this.onExpandedChanged,
  });
  final ChartEdit edit;
  final String symbolLabel;

  /// The symbol's human description (e.g. "Euro vs US Dollar") — shown expanded
  /// only, exactly like MT5's order ticket. Omitted when the spec hasn't loaded.
  final String? symbolDescription;
  final int digits;
  final Tick? quote;
  final double minLot, maxLot, lotStep;
  final bool busy;
  final String? serverError;
  final VoidCallback onChanged;
  final void Function(OrderMode) onPickType;
  /// SL / TP are toggles: unset → [onAddSl] / [onAddTp] sets it, set → [onRemoveSl] /
  /// [onRemoveTp] removes it. The caller owns the edit model (and, for an existing order or
  /// position, the backend call and its rollback), so the panel never mutates SL / TP itself.
  final VoidCallback onAddSl, onAddTp, onRemoveSl, onRemoveTp, onApply, onClose, onCancelOrder;

  /// Market mode: "Sell by Market" / "Buy by Market" (side = SELL | BUY).
  final void Function(String side)? onMarket;

  /// Market is open, a price is live, the account can trade and no order is in flight.
  final bool marketEnabled;

  /// Collapsed (compact) vs expanded (full order ticket). The caller owns this —
  /// one flag, alongside [ChartEdit], so there is nowhere for the two to disagree.
  final bool expanded;
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<PendingPanel> createState() => _PendingPanelState();
}

class _PendingPanelState extends State<PendingPanel> {
  final _entry = TextEditingController();
  final _limit = TextEditingController();
  final _sl = TextEditingController();
  final _tp = TextEditingController();
  final _vol = TextEditingController();
  final _fEntry = FocusNode();
  final _fLimit = FocusNode();
  final _fSl = FocusNode();
  final _fTp = FocusNode();
  final _fVol = FocusNode();

  /// Accumulated vertical drag on the handle, decided on release (see [_handle]).
  double _dragDy = 0;

  /// Whether the "Add Stop Levels" button has been tapped, so the SL / TP fields
  /// show even before either has a value. Reset whenever a NEW target is edited
  /// (a fresh draft, or a different order/position) — never mid-edit, so it
  /// doesn't hide fields the user is actively looking at.
  bool _stopLevelsOpen = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PendingPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.edit, widget.edit)) _stopLevelsOpen = false;
    _sync();
  }

  @override
  void dispose() {
    for (final c in [_entry, _limit, _sl, _tp, _vol]) {
      c.dispose();
    }
    for (final f in [_fEntry, _fLimit, _fSl, _fTp, _fVol]) {
      f.dispose();
    }
    super.dispose();
  }

  String _fmt(double v) => v.toStringAsFixed(widget.digits);

  /// Push the model into the fields (a line was dragged, a type was picked, an SL
  /// was added…) without fighting the user while they are typing in one.
  void _sync() {
    void put(TextEditingController c, FocusNode f, double? v, String Function(double) fmt) {
      if (f.hasFocus) return;
      final cur = double.tryParse(c.text.trim());
      if (v == null) {
        if (c.text.isNotEmpty) c.text = '';
      } else if (cur == null || (cur - v).abs() > 1e-9) {
        c.text = fmt(v);
      }
    }

    final e = widget.edit;
    put(_entry, _fEntry, e.entry, _fmt);
    put(_limit, _fLimit, e.limit, _fmt);
    put(_sl, _fSl, e.sl, _fmt);
    put(_tp, _fTp, e.tp, _fmt);
    put(_vol, _fVol, e.volume, (v) => v.toStringAsFixed(2));
  }

  double? _parse(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  double _snapVolume(double v) =>
      double.parse(((v / widget.lotStep).round() * widget.lotStep).clamp(widget.minLot, widget.maxLot).toStringAsFixed(2));

  void _stepVolume(int dir) {
    final e = widget.edit;
    final base = e.volume ?? widget.minLot;
    e.volume = _snapVolume(base + dir * widget.lotStep);
    widget.onChanged();
  }

  /// One tick (point) for this symbol, for the price steppers — e.g. 5 digits → 0.00001.
  double get _point => math.pow(10, -widget.digits).toDouble();

  void _stepPrice(void Function(double) setter, double? current, int dir) {
    final base = current ?? widget.quote?.bid ?? 0;
    setter(double.parse((base + dir * _point).toStringAsFixed(widget.digits)));
    widget.onChanged();
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final e = widget.edit;
    final initial = e.expiresAt ?? now.add(const Duration(days: 1));
    final date = await showDatePicker(context: context, initialDate: initial, firstDate: now, lastDate: now.add(const Duration(days: 365)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (!mounted) return;
    setState(() => e.expiresAt = DateTime(date.year, date.month, date.day, time?.hour ?? 23, time?.minute ?? 59));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.edit;
    final tc = Theme.of(context).extension<TradeColors>()!;
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final errs = e.errors(widget.quote, minLot: widget.minLot, maxLot: widget.maxLot, lotStep: widget.lotStep);
    final accent = e.isBuy ? tc.buy : tc.sell;
    final q = widget.quote;
    final expanded = widget.expanded;

    Widget field(String label, TextEditingController c, FocusNode f, void Function(String) onCh, String? err, {Widget? suffix, Widget? prefix, bool center = false}) {
      return TextField(
        controller: c,
        focusNode: f,
        textAlign: center ? TextAlign.center : TextAlign.start,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (v) {
          onCh(v);
          widget.onChanged();
        },
        decoration: InputDecoration(
          labelText: label,
          errorText: err,
          errorMaxLines: 2,
          suffixIcon: suffix,
          prefixIcon: prefix,
          isDense: true,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: cs.outline)),
        ),
      );
    }

    // Entry / Stop / Limit — a text field flanked by MT5-style +/- point steppers.
    Widget priceField(String label, TextEditingController c, FocusNode f, double? value, void Function(double) setter, String? err) {
      // One rounded outline; the −/+ steppers live inside it so the floating
      // label never collides with a second border.
      return field(
        label,
        c,
        f,
        (v) => setter(_parse(v) ?? 0),
        err,
        center: true,
        prefix: _StepIconButton(key: ValueKey('$label-minus'), icon: Icons.remove, onTap: widget.busy ? null : () => _stepPrice(setter, value, -1)),
        suffix: _StepIconButton(key: ValueKey('$label-plus'), icon: Icons.add, onTap: widget.busy ? null : () => _stepPrice(setter, value, 1)),
      );
    }

    Widget protective(String label, TextEditingController c, FocusNode f, double? value, void Function(double?) set, VoidCallback add, VoidCallback remove, String? err) {
      return field(
        label,
        c,
        f,
        (v) => set(v.trim().isEmpty ? null : _parse(v)),
        err,
        suffix: value == null
            ? IconButton(tooltip: 'Add $label line', icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: add)
            : IconButton(
                tooltip: 'Clear $label',
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.busy ? null : remove,
              ),
      );
    }

    // Drag handle — the primary MT5 affordance: drag it up/down, or tap it, to
    // expand/collapse. `onVerticalDragEnd` decides from the accumulated delta
    // (not velocity), so a test's `WidgetTester.drag()` is deterministic.
    Widget handle() => GestureDetector(
          key: const ValueKey('panel-handle'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onExpandedChanged?.call(!expanded),
          onVerticalDragStart: (_) => _dragDy = 0,
          onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
          onVerticalDragEnd: (_) {
            if (_dragDy.abs() > 10) widget.onExpandedChanged?.call(_dragDy < 0);
            _dragDy = 0;
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Container(width: 38, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2))),
            ),
          ),
        );

    // Collapsed header (MT5's minimised order bar): symbol, SL / TP circle
    // buttons and a "→" to expand — no Bid/Ask, no description, so the chart
    // keeps as much room as possible. Tapping SL / TP while unset drops that level
    // line onto the chart (via the same add-line handler as the expanded "+"), so it
    // can be dragged right away with the panel still compact. Once set, the button
    // is filled and tapping it again removes that level (a toggle). Exact values are typed
    // in the Stop Levels fields of the expanded ticket.
    Widget collapsedHeader() {
      return Row(children: [
        Text(widget.symbolLabel, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.primary)),
        Icon(Icons.unfold_more, size: 18, color: cs.primary),
        const Spacer(),
        _CircleIconButton(label: 'SL', color: tc.loss, filled: e.sl != null, onTap: widget.busy ? null : (e.sl == null ? widget.onAddSl : widget.onRemoveSl)),
        const SizedBox(width: 8),
        _CircleIconButton(label: 'TP', color: tc.profit, filled: e.tp != null, onTap: widget.busy ? null : (e.tp == null ? widget.onAddTp : widget.onRemoveTp)),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('panel-toggle'),
          tooltip: 'Expand order panel',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.arrow_forward, color: cs.primary),
          onPressed: () => widget.onExpandedChanged?.call(true),
        ),
      ]);
    }

    // Header: symbol, expand/collapse chevron, close, live Bid/Ask and the
    // symbol's description — shown while expanded (MT5's order-ticket header
    // never hides the price you're trading at once the ticket is open).
    Widget header() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(widget.symbolLabel, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.primary)),
            IconButton(
              key: const ValueKey('panel-toggle'),
              tooltip: expanded ? 'Collapse order panel' : 'Expand order panel',
              visualDensity: VisualDensity.compact,
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
              onPressed: () => widget.onExpandedChanged?.call(!expanded),
            ),
            if (q != null)
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_fmt(q.bid), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tc.sell)),
                    const SizedBox(width: 12),
                    Text(_fmt(q.ask), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tc.buy)),
                  ]),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 6),
            IconButton(tooltip: 'Close', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close), onPressed: widget.busy ? null : widget.onClose),
          ]),
          if ((widget.symbolDescription ?? '').trim().isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(widget.symbolDescription!, style: TextStyle(fontSize: 12.5, color: hint))),
          if (!e.isDraft) Text(e.isPosition ? 'Position' : e.typeLabel, style: TextStyle(fontSize: 12.5, color: hint)),
        ]);

    // Order-type selector: one horizontal, scrollable row — Market Execution →
    // Buy Limit → Sell Limit → Buy Stop → Sell Stop → Buy Stop Limit → Sell Stop
    // Limit — the same in both states (MT5 never switches this to a grid).
    Widget typeSelector() {
      if (!e.isDraft) return const SizedBox.shrink();
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final m in OrderMode.values)
            _ModeTab(
              label: m.label,
              selected: e.mode == m,
              color: m.isMarket ? cs.primary : (m.side == 'BUY' ? tc.buy : tc.sell),
              onTap: widget.busy ? null : () => widget.onPickType(m),
            ),
        ]),
      );
    }

    // Full-width Volume box (MT5: "Volume  0.04  Lots"). The "Lots" trailer is a
    // plain unit label — we only ever support lots, so there is no second unit to
    // pick and nothing here is invented.
    Widget volumeBox() => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: cs.outline)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('Volume', style: TextStyle(color: hint, fontSize: 13)),
              const Spacer(),
              IconButton(
                  key: const ValueKey('volume-minus'),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.busy ? null : () => _stepVolume(-1),
                  icon: const Icon(Icons.remove, size: 18)),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _vol,
                  focusNode: _fVol,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  onChanged: (v) {
                    e.volume = _parse(v);
                    widget.onChanged();
                  },
                  decoration: const InputDecoration(isDense: true, filled: false, border: InputBorder.none, isCollapsed: true),
                ),
              ),
              IconButton(
                  key: const ValueKey('volume-plus'),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.busy ? null : () => _stepVolume(1),
                  icon: const Icon(Icons.add, size: 18)),
              const SizedBox(width: 4),
              Text('Lots', style: TextStyle(color: hint, fontSize: 13)),
            ]),
            if (widget.maxLot > widget.minLot)
              Builder(builder: (_) {
                final steps = ((widget.maxLot - widget.minLot) / widget.lotStep).round();
                return SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8), overlayShape: const RoundSliderOverlayShape(overlayRadius: 14)),
                  child: Slider(
                    value: (e.volume ?? widget.minLot).clamp(widget.minLot, widget.maxLot),
                    min: widget.minLot,
                    max: widget.maxLot,
                    divisions: steps > 0 && steps <= 200 ? steps : null,
                    label: (e.volume ?? widget.minLot).toStringAsFixed(2),
                    onChanged: widget.busy
                        ? null
                        : (v) {
                            setState(() => e.volume = _snapVolume(v));
                            widget.onChanged();
                          },
                  ),
                );
              }),
            if (errs['volume'] != null)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(errs['volume']!, style: TextStyle(color: cs.error, fontSize: 12))),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('min ${widget.minLot.toStringAsFixed(2)} · max ${widget.maxLot.toStringAsFixed(2)} · step ${widget.lotStep.toStringAsFixed(2)}',
                  style: TextStyle(color: hint, fontSize: 11)),
            ),
          ]),
        );

    // Full-width Price box, one per relevant field. MT5 never shows a field that
    // doesn't apply to the current order type: Market has none, Buy/Sell Limit
    // show "Entry price", Buy/Sell Stop show "Stop price", and Stop Limit shows
    // both the stop (trigger) and the limit (fill) price.
    Widget priceBox(String label, TextEditingController c, FocusNode f, double? value, void Function(double) setter, String? err) =>
        priceField(label, c, f, value, setter, err);

    // "Add Stop Levels" — MT5 keeps SL / TP out of the way until asked for. Once
    // either has a real value (typed, or a line dragged on the chart) the fields
    // show themselves, exactly like the button had been tapped.
    Widget stopLevelsSection() {
      final open = _stopLevelsOpen || e.sl != null || e.tp != null;
      if (!open) {
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const ValueKey('add-stop-levels'),
            onPressed: widget.busy ? null : () => setState(() => _stopLevelsOpen = true),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10), side: BorderSide(color: cs.outline)),
            child: const Text('Add Stop Levels'),
          ),
        );
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: protective('Stop loss', _sl, _fSl, e.sl, (v) => e.sl = v, widget.onAddSl, widget.onRemoveSl, errs['sl'])),
        const SizedBox(width: 10),
        Expanded(child: protective('Take profit', _tp, _fTp, e.tp, (v) => e.tp = v, widget.onAddTp, widget.onRemoveTp, errs['tp'])),
      ]);
    }

    // The order-type-dependent price section: nothing for Market, one box for
    // Limit/Stop, two (stop + limit) for Stop Limit.
    Widget priceSection() {
      if (!e.hasEntry) return const SizedBox.shrink();
      final isStop = e.typeApi.toUpperCase().contains('STOP');
      final label = e.isStopLimit ? 'Stop price' : (isStop ? 'Stop price' : 'Entry price');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        priceBox(label, _entry, _fEntry, e.entry, (v) => e.entry = v, errs['entry']),
        if (e.isStopLimit) ...[
          const SizedBox(height: 10),
          priceBox('Limit price', _limit, _fLimit, e.limit, (v) => e.limit = v, errs['limit']),
        ],
      ]);
    }

    // Shared body — identical in both states: order types, volume, price(s),
    // Stop Levels. Only Expiration (new orders only) and the overall
    // scroll headroom differ between collapsed and expanded.
    Widget core() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (e.hasVolume) ...[volumeBox()],
          if (e.hasEntry) ...[const SizedBox(height: 8), priceSection()],
          const SizedBox(height: 8),
          stopLevelsSection(),
        ]);

    final title = e.isMarket
        ? 'Market order · ${widget.symbolLabel}'
        : e.isDraft
            ? 'New pending order · ${widget.symbolLabel}'
            : (e.isOrder ? '${e.typeLabel} · ${widget.symbolLabel}' : 'Position · ${widget.symbolLabel}');
    final valid = errs.isEmpty;
    final placeLabel = e.isDraft ? 'Place ${e.typeLabel} ${(e.volume ?? 0).toStringAsFixed(2)}' : (e.isOrder ? 'Apply changes' : 'Apply');

    // Place / Apply — or, in Market mode, the Sell-by-Market / Buy-by-Market pair.
    // Visible in BOTH states: placing an order never requires expanding first.
    Widget placeRow({required double height}) {
      if (e.isMarket) {
        return Row(children: [
          for (final side in const ['SELL', 'BUY']) ...[
            if (side == 'BUY') const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: (widget.busy || !valid || !widget.marketEnabled || widget.onMarket == null) ? null : () => widget.onMarket!(side),
                style: FilledButton.styleFrom(
                  backgroundColor: side == 'BUY' ? tc.buy : tc.sell,
                  foregroundColor: Colors.white,
                  minimumSize: Size.fromHeight(height),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(widget.busy ? 'Working…' : (side == 'BUY' ? 'Buy by Market' : 'Sell by Market'), maxLines: 1)),
              ),
            ),
          ],
        ]);
      }
      return FilledButton(
        onPressed: (widget.busy || !valid) ? null : widget.onApply,
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: Size.fromHeight(height),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        child: Text(widget.busy ? 'Working…' : placeLabel),
      );
    }

    // ── Collapsed content ────────────────────────────────────────────────────
    // MT5's minimised order bar: just the order-type row and Place — the chart
    // stays as visible as possible. The handle and collapsed header are pinned
    // outside the scrollable body (see the return statement below).
    Widget collapsed() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 4),
          placeRow(height: 44),
        ]);

    // ── Expanded content — the full MT5 order ticket ────────────────────────
    Widget expandedBody() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 8),
          core(),
          // Expiration: real backend fields (PlaceOrderDto.timeInForce /
          // expiresAt) — but only the placement endpoint accepts them, so
          // they only appear while creating a NEW order, never while modifying one.
          if (e.hasTif) ...[
            const SizedBox(height: 6),
            Row(children: [
              Text('Expiration', style: TextStyle(color: hint, fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              DropdownButton<String>(
                value: e.timeInForce ?? 'GTC',
                underline: const SizedBox.shrink(),
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 'GTC', child: Text('GTC')),
                  DropdownMenuItem(value: 'DAY', child: Text('Today')),
                  DropdownMenuItem(value: 'GTD', child: Text('GTD')),
                ],
                onChanged: widget.busy
                    ? null
                    : (v) {
                        setState(() {
                          e.timeInForce = v;
                          if (v != 'GTD') e.expiresAt = null;
                        });
                        widget.onChanged();
                      },
              ),
            ]),
            if (e.timeInForce == 'GTD') ...[
              const SizedBox(height: 6),
              InkWell(
                key: const ValueKey('pick-expiry'),
                onTap: widget.busy ? null : _pickExpiry,
                child: InputDecorator(
                  decoration: InputDecoration(
                    isDense: true,
                    errorText: errs['expiresAt'],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
                  ),
                  child: Text(e.expiresAt == null ? 'Pick a date and time' : '${e.expiresAt}'.substring(0, 16)),
                ),
              ),
            ],
          ],
          if (widget.serverError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
              child: Text(widget.serverError!, style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ],
          const SizedBox(height: 8),
          placeRow(height: 46),
          if (e.isOrder)
            TextButton(
              onPressed: widget.busy ? null : widget.onCancelOrder,
              child: Text('Cancel this order', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w700)),
            ),
        ]);

    // Collapsed content also shows the server error, if any, above Place.
    Widget collapsedWithError() => widget.serverError == null
        ? collapsed()
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
              child: Text(widget.serverError!, style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            const SizedBox(height: 10),
            placeRow(height: 44),
          ]);

    return Material(
      color: cs.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Semantics(
        label: title,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (MediaQuery.of(context).size.height - MediaQuery.of(context).viewInsets.bottom) * (expanded ? 0.72 : 0.34)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Pinned above the scrollable body — always reachable to collapse /
            // close, even once a long expanded ticket has been scrolled down.
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: handle()),
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: expanded ? header() : collapsedHeader()),
            // Order types stay pinned (never scrolled out of view by a focused field).
            if (e.isDraft) Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 6), child: typeSelector()),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.of(context).viewInsets.bottom),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded ? expandedBody() : collapsedWithError(),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One order-mode tab (collapsed row — MT5's "Execution · Buy Limit · Sell Limit · …").
/// The selected tab is coloured by its side and underlined.
class _ModeTab extends StatelessWidget {
  const _ModeTab({required this.label, required this.selected, required this.color, required this.onTap});
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // MT5: flat text tabs — no boxes. The selected tab is coloured by its side with
    // an underline; the rest are muted text.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? color : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? color : cs.onSurface.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }
}

/// Collapsed header's SL / TP button — an outlined circle, MT5-style.
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.label, required this.color, required this.onTap, this.filled = false});
  final String label;
  final Color color;

  /// The level is set: solid fill, like an active MT5 toggle.
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('circle-$label'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: filled ? color.withValues(alpha: 0.22) : null, border: Border.all(color: color, width: 1.4)),
          child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
        ),
      );
}

/// Small +/- stepper button beside a price field (Entry / Stop / Limit).
class _StepIconButton extends StatelessWidget {
  const _StepIconButton({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => IconButton(onPressed: onTap, visualDensity: VisualDensity.compact, icon: Icon(icon, size: 20));
}

