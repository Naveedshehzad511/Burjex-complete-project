import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:btrader_core/btrader_core.dart';

import 'color_picker.dart';

/// MT5-style controls for ONE chart drawing: the bottom style bar on the chart, and the Properties screen.
/// Both work on the drawing's own colour / width / line style; nothing is shared between drawings.

/// A small sample of a line style (solid / dashed / dotted) for the style buttons.
class _LineSample extends CustomPainter {
  _LineSample(this.style, this.color);
  final DrawingLineStyle style;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = style == DrawingLineStyle.dotted ? StrokeCap.round : StrokeCap.butt;
    final y = size.height / 2;
    if (style == DrawingLineStyle.solid) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      return;
    }
    final on = style == DrawingLineStyle.dashed ? 7.0 : 0.1;
    final off = style == DrawingLineStyle.dashed ? 4.0 : 4.0;
    for (var x = 0.0; x < size.width; x += on + off) {
      canvas.drawLine(Offset(x, y), Offset((x + on).clamp(0, size.width), y), p);
    }
  }

  @override
  bool shouldRepaint(_LineSample old) => old.style != style || old.color != color;
}

/// Colour dot + width slider (1..5) + solid / dashed / dotted, as in MT5's object style row.
class DrawingStyleControls extends StatelessWidget {
  const DrawingStyleControls({super.key, required this.drawing, required this.onChanged});
  final DrawingObject drawing;
  final ValueChanged<DrawingObject> onChanged;

  Future<void> _pickColor(BuildContext context) async {
    final c = await showChartColorPicker(context, title: 'Color', initial: Color(drawing.colorArgb));
    if (c != null) onChanged(drawing.copyWith(colorArgb: c.toARGB32()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = Color(drawing.colorArgb);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        InkWell(
          key: const ValueKey('drawing-color'),
          customBorder: const CircleBorder(),
          onTap: () => _pickColor(context),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: cs.outlineVariant, width: 2)),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
              key: const ValueKey('drawing-width'),
              value: drawing.width.toDouble(),
              min: 1,
              max: 5,
              divisions: 4,
              label: '${drawing.width}',
              onChanged: (v) {
                if (v.round() != drawing.width) onChanged(drawing.copyWith(width: v.round()));
              },
            ),
          ),
        ),
      ]),
      Container(
        height: 34,
        decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.all(3),
        child: Row(children: [
          for (final st in DrawingLineStyle.values)
            Expanded(
              child: GestureDetector(
                key: ValueKey('drawing-style-${st.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (st != drawing.lineStyle) onChanged(drawing.copyWith(lineStyle: st));
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: st == drawing.lineStyle ? cs.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: st == drawing.lineStyle ? [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 3)] : null,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: CustomPaint(painter: _LineSample(st, cs.onSurface), size: const Size(double.infinity, 28)),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}

/// The compact bar shown at the bottom of the chart while a drawing is selected (MT5).
class DrawingStyleBar extends StatelessWidget {
  const DrawingStyleBar({super.key, required this.drawing, required this.onChanged});
  final DrawingObject drawing;
  final ValueChanged<DrawingObject> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: cs.surface.withValues(alpha: 0.96),
        elevation: 2,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: DrawingStyleControls(drawing: drawing, onChanged: onChanged),
        ),
      ),
    );
  }
}

/// MT5 object Properties: name, coordinates, fill, symbol, timeframes, style, draw as background.
/// Works on a copy; only the Save (check) button writes it back. Back / close discards the changes.
Future<DrawingObject?> showDrawingProperties(BuildContext context, DrawingObject d, {required int digits}) =>
    Navigator.of(context).push<DrawingObject>(MaterialPageRoute(builder: (_) => _DrawingPropertiesScreen(d, digits)));

class _DrawingPropertiesScreen extends StatefulWidget {
  const _DrawingPropertiesScreen(this.initial, this.digits);
  final DrawingObject initial;
  final int digits;

  @override
  State<_DrawingPropertiesScreen> createState() => _DrawingPropertiesScreenState();
}

class _DrawingPropertiesScreenState extends State<_DrawingPropertiesScreen> {
  late DrawingObject _d = widget.initial;
  late final _name = TextEditingController(text: widget.initial.displayName);
  late final List<TextEditingController> _prices = [
    for (final a in widget.initial.anchors) TextEditingController(text: a.price.toStringAsFixed(widget.digits)),
  ];

  @override
  void dispose() {
    _name.dispose();
    for (final c in _prices) {
      c.dispose();
    }
    super.dispose();
  }

  String _two(int n) => n.toString().padLeft(2, '0');
  String _when(int t) {
    final s = serverTime(DateTime.fromMillisecondsSinceEpoch(t * 1000));
    return '${s.year}.${_two(s.month)}.${_two(s.day)} ${_two(s.hour)}:${_two(s.minute)}';
  }

  /// Pick a new date + time for anchor [i], in server time like the chart's time axis.
  Future<void> _pickTime(int i) async {
    final cur = serverTime(DateTime.fromMillisecondsSinceEpoch(_d.anchors[i].t * 1000));
    final date = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(cur.year - 20),
      lastDate: DateTime(cur.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute));
    if (time == null || !mounted) return;
    final utc = DateTime.utc(date.year, date.month, date.day, time.hour, time.minute).subtract(Duration(seconds: serverUtcOffsetSec));
    final list = [..._d.anchors];
    list[i] = DrawingAnchor(utc.millisecondsSinceEpoch ~/ 1000, list[i].price);
    setState(() => _d = _d.copyWith(anchors: list));
  }

  void _save() {
    final anchors = [
      for (var i = 0; i < _d.anchors.length; i++)
        DrawingAnchor(_d.anchors[i].t, double.tryParse(_prices[i].text.trim()) ?? _d.anchors[i].price),
    ];
    final n = _name.text.trim();
    final out = _d.copyWith(anchors: anchors, name: n == widget.initial.displayName && widget.initial.name == null ? null : n);
    Navigator.of(context).pop(n.isEmpty ? DrawingObject(
      id: out.id, symbol: out.symbol, type: out.type, anchors: out.anchors, colorArgb: out.colorArgb,
      lineStyle: out.lineStyle, width: out.width, fill: out.fill, background: out.background, timeframes: out.timeframes,
    ) : out);
  }

  Future<void> _pickTimeframes() async {
    final picked = await showDialog<Set<String>?>(
      context: context,
      builder: (_) => _TimeframesDialog(_d.timeframes),
    );
    if (picked == null) return;
    setState(() => _d = picked.length == Timeframe.values.length ? _d.copyWith(allTimeframes: true) : _d.copyWith(timeframes: picked));
  }

  String get _tfText {
    final t = _d.timeframes;
    if (t == null || t.length == Timeframe.values.length) return 'All timeframes';
    if (t.isEmpty) return 'None';
    return Timeframe.values.where((f) => t.contains(f.name)).map((f) => f.mt5Label).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: hint, letterSpacing: 0.4)),
        );
    Widget group(List<Widget> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Material(
          color: Color.alphaBlend(cs.onSurface.withValues(alpha: 0.04), cs.surface),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 16, color: cs.outlineVariant.withValues(alpha: 0.5)),
              children[i],
            ],
          ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Properties'),
        actions: [
          IconButton(key: const ValueKey('drawing-props-save'), tooltip: 'Save', icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          header('Parameters'),
          group([
            ListTile(
              title: const Text('Name'),
              trailing: SizedBox(
                width: 190,
                child: TextField(
                  key: const ValueKey('drawing-props-name'),
                  controller: _name,
                  textAlign: TextAlign.end,
                  decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                  style: TextStyle(color: cs.primary),
                ),
              ),
            ),
            if (_d.supportsFill)
              SwitchListTile(
                key: const ValueKey('drawing-props-fill'),
                title: const Text('Fill'),
                value: _d.fill,
                onChanged: (v) => setState(() => _d = _d.copyWith(fill: v)),
              ),
          ]),
          header('Coordinates'),
          group([
            for (var i = 0; i < _d.anchors.length; i++)
              ListTile(
                title: Row(children: [
                  if (_d.type != DrawingType.horizontalLine)
                    Flexible(
                      flex: 3,
                      child: TextButton(
                        key: ValueKey('drawing-props-time-$i'),
                        onPressed: () => _pickTime(i),
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text(_when(_d.anchors[i].t))),
                      ),
                    )
                  else
                    Text('Point ${i + 1}', style: TextStyle(color: hint)),
                  const SizedBox(width: 8),
                  if (_d.type != DrawingType.verticalLine)
                    Flexible(
                      flex: 2,
                      child: TextField(
                        key: ValueKey('drawing-props-price-$i'),
                        controller: _prices[i],
                        textAlign: TextAlign.end,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                        decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                        style: TextStyle(color: cs.primary),
                      ),
                    ),
                ]),
              ),
          ]),
          header('Visualization'),
          group([
            ListTile(title: const Text('Symbol'), trailing: Text(_d.symbol, style: TextStyle(color: hint))),
            ListTile(
              key: const ValueKey('drawing-props-timeframes'),
              title: const Text('Timeframe'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: Text(_tfText, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint)),
                ),
                Icon(Icons.chevron_right, color: hint),
              ]),
              onTap: _pickTimeframes,
            ),
          ]),
          header('Style'),
          group([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: DrawingStyleControls(drawing: _d, onChanged: (v) => setState(() => _d = v)),
            ),
            SwitchListTile(
              key: const ValueKey('drawing-props-background'),
              title: const Text('Draw as background'),
              value: _d.background,
              onChanged: (v) => setState(() => _d = _d.copyWith(background: v)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _TimeframesDialog extends StatefulWidget {
  const _TimeframesDialog(this.initial);
  final Set<String>? initial;

  @override
  State<_TimeframesDialog> createState() => _TimeframesDialogState();
}

class _TimeframesDialogState extends State<_TimeframesDialog> {
  late final Set<String> _on = {...(widget.initial ?? Timeframe.values.map((t) => t.name))};

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Timeframes'),
        contentPadding: const EdgeInsets.only(top: 8),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
              dense: true,
              title: const Text('All timeframes'),
              value: _on.length == Timeframe.values.length,
              onChanged: (v) => setState(() => v == true ? _on.addAll(Timeframe.values.map((t) => t.name)) : _on.clear()),
            ),
            for (final t in Timeframe.values)
              CheckboxListTile(
                dense: true,
                title: Text(t.mt5Label),
                value: _on.contains(t.name),
                onChanged: (v) => setState(() => v == true ? _on.add(t.name) : _on.remove(t.name)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, {..._on}), child: const Text('OK')),
        ],
      );
}
