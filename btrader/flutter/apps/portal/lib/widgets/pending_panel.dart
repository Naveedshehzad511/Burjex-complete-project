import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';

/// What the chart's edit panel is working on.
enum EditKind { draft, order, position }

/// One in-progress edit made on the chart: a NEW pending order (draft), a resting
/// pending order, or the SL / TP of an open position. The chart draws its lines
/// from this and the panel edits it, so a dragged line and a typed value are the
/// same thing. Nothing reaches the server until Apply.
class ChartEdit {
  ChartEdit.draft({required OrderType type, required this.volume, this.entry})
      : kind = EditKind.draft,
        id = null,
        draftType = type,
        side = _isBuy(type.api) ? 'BUY' : 'SELL';
  ChartEdit.order({required String this.id, required this.orderType, required this.side, required this.entry, this.sl, this.tp, required this.volume, this.hasStopField = false})
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
  double? sl;
  double? tp;
  double? volume;
  double? originalVolume;
  bool hasStopField = false;

  static bool _isBuy(String t) => t.toUpperCase().startsWith('BUY');

  bool get isDraft => kind == EditKind.draft;
  bool get isOrder => kind == EditKind.order;
  bool get isPosition => kind == EditKind.position;
  bool get hasEntry => !isPosition;
  bool get hasVolume => !isPosition;
  bool get isBuy => side == 'BUY';
  String get targetId => isDraft ? 'draft' : (id ?? '');

  /// e.g. `BUY_LIMIT` for both a draft and an existing order.
  String get typeApi => isDraft ? draftType!.api : (orderType ?? '');

  String get typeLabel {
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
        }
      }
    }
    final ref = entry;
    if (ref != null && ref > 0) {
      if (sl != null) {
        if (!(sl! > 0)) {
          out['sl'] = 'Invalid price';
        } else if (isBuy ? sl! >= ref : sl! <= ref) {
          out['sl'] = isBuy ? 'Must be below the entry' : 'Must be above the entry';
        }
      }
      if (tp != null) {
        if (!(tp! > 0)) {
          out['tp'] = 'Invalid price';
        } else if (isBuy ? tp! <= ref : tp! >= ref) {
          out['tp'] = isBuy ? 'Must be above the entry' : 'Must be below the entry';
        }
      }
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

/// The bottom sheet for placing / editing pending orders and SL / TP, shown under
/// the chart (not over it) so the lines stay draggable while it is open.
class PendingPanel extends StatefulWidget {
  const PendingPanel({
    super.key,
    required this.edit,
    required this.symbolLabel,
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
    required this.onApply,
    required this.onClose,
    required this.onCancelOrder,
  });
  final ChartEdit edit;
  final String symbolLabel;
  final int digits;
  final Tick? quote;
  final double minLot, maxLot, lotStep;
  final bool busy;
  final String? serverError;
  final VoidCallback onChanged;
  final void Function(OrderType) onPickType;
  final VoidCallback onAddSl, onAddTp, onApply, onClose, onCancelOrder;

  @override
  State<PendingPanel> createState() => _PendingPanelState();
}

class _PendingPanelState extends State<PendingPanel> {
  final _entry = TextEditingController();
  final _sl = TextEditingController();
  final _tp = TextEditingController();
  final _vol = TextEditingController();
  final _fEntry = FocusNode();
  final _fSl = FocusNode();
  final _fTp = FocusNode();
  final _fVol = FocusNode();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PendingPanel old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    for (final c in [_entry, _sl, _tp, _vol]) {
      c.dispose();
    }
    for (final f in [_fEntry, _fSl, _fTp, _fVol]) {
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
    put(_sl, _fSl, e.sl, _fmt);
    put(_tp, _fTp, e.tp, _fmt);
    put(_vol, _fVol, e.volume, (v) => v.toStringAsFixed(2));
  }

  double? _parse(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  void _stepVolume(int dir) {
    final e = widget.edit;
    final base = e.volume ?? widget.minLot;
    final next = ((base / widget.lotStep).round() + dir) * widget.lotStep;
    e.volume = double.parse(next.clamp(widget.minLot, widget.maxLot).toStringAsFixed(2));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.edit;
    final tc = Theme.of(context).extension<TradeColors>()!;
    final cs = Theme.of(context).colorScheme;
    final errs = e.errors(widget.quote, minLot: widget.minLot, maxLot: widget.maxLot, lotStep: widget.lotStep);
    final accent = e.isBuy ? tc.buy : tc.sell;
    final q = widget.quote;

    Widget field(String label, TextEditingController c, FocusNode f, void Function(String) onCh, String? err,
        {Widget? suffix, bool required = false}) {
      return TextField(
        controller: c,
        focusNode: f,
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
          isDense: true,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: cs.outline)),
        ),
      );
    }

    Widget protective(String label, TextEditingController c, FocusNode f, double? value, void Function(double?) set, VoidCallback add, String? err) {
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
                onPressed: () {
                  set(null);
                  c.clear();
                  widget.onChanged();
                },
              ),
      );
    }

    final title = e.isDraft ? 'New pending order · ${widget.symbolLabel}' : (e.isOrder ? '${e.typeLabel} · ${widget.symbolLabel}' : 'Position · ${widget.symbolLabel}');
    final valid = errs.isEmpty;
    final placeLabel = e.isDraft
        ? 'Place ${e.typeLabel} ${(e.volume ?? 0).toStringAsFixed(2)}'
        : (e.isOrder ? 'Apply changes' : 'Apply');

    return Material(
      color: cs.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
              IconButton(tooltip: 'Close', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close), onPressed: widget.busy ? null : widget.onClose),
            ]),
            if (q != null)
              Center(
                child: Text('Bid ${_fmt(q.bid)}   Ask ${_fmt(q.ask)}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              ),
            const SizedBox(height: 10),
            if (e.isDraft)
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in const [OrderType.buyLimit, OrderType.sellLimit, OrderType.buyStop, OrderType.sellStop])
                  ChoiceChip(
                    label: Text(t.label),
                    selected: e.draftType == t,
                    showCheckmark: true,
                    onSelected: widget.busy ? null : (_) => widget.onPickType(t),
                  ),
              ]),
            if (e.hasEntry) ...[
              const SizedBox(height: 12),
              field('Entry price', _entry, _fEntry, (v) => e.entry = _parse(v), errs['entry']),
            ],
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: protective('Stop loss', _sl, _fSl, e.sl, (v) => e.sl = v, widget.onAddSl, errs['sl'])),
              const SizedBox(width: 10),
              Expanded(child: protective('Take profit', _tp, _fTp, e.tp, (v) => e.tp = v, widget.onAddTp, errs['tp'])),
            ]),
            if (e.hasVolume) ...[
              const SizedBox(height: 10),
              Row(children: [
                Text('Volume', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 15)),
                const Spacer(),
                IconButton.filledTonal(onPressed: widget.busy ? null : () => _stepVolume(-1), icon: const Icon(Icons.remove)),
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: _vol,
                    focusNode: _fVol,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    onChanged: (v) {
                      e.volume = _parse(v);
                      widget.onChanged();
                    },
                    decoration: const InputDecoration(isDense: true, filled: false, border: InputBorder.none),
                  ),
                ),
                IconButton.filledTonal(onPressed: widget.busy ? null : () => _stepVolume(1), icon: const Icon(Icons.add)),
              ]),
              if (errs['volume'] != null)
                Align(alignment: Alignment.centerRight, child: Text(errs['volume']!, style: TextStyle(color: cs.error, fontSize: 12))),
              Align(
                alignment: Alignment.centerRight,
                child: Text('min ${widget.minLot.toStringAsFixed(2)} · max ${widget.maxLot.toStringAsFixed(2)} · step ${widget.lotStep.toStringAsFixed(2)}',
                    style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
              ),
            ],
            if (widget.serverError != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
                child: Text(widget.serverError!, style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: (widget.busy || !valid) ? null : widget.onApply,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              child: Text(widget.busy ? 'Working…' : placeLabel),
            ),
            if (e.isOrder)
              TextButton(
                onPressed: widget.busy ? null : widget.onCancelOrder,
                child: Text('Cancel this order', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ),
    );
  }
}
