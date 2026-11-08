import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A colour picker dialog: saturation / brightness box, hue slider, hex field and a preview of the old and the new
/// colour. Returns the chosen opaque colour, or null on Cancel. No external package.
Future<Color?> showChartColorPicker(BuildContext context, {required String title, required Color initial}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(title: title, initial: initial),
  );
}

String colorToHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// '#RRGGBB' / 'RRGGBB' (any case) to an opaque colour; null when it is not exactly six hex digits.
Color? colorFromHex(String s) {
  final t = s.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(t)) return null;
  return Color(0xFF000000 | int.parse(t, radix: 16));
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.title, required this.initial});
  final String title;
  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex = TextEditingController(text: colorToHex(widget.initial));
  final _hexFocus = FocusNode();

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _set(HSVColor v, {bool fromHex = false}) {
    setState(() => _hsv = v);
    if (!fromHex) _hex.text = colorToHex(_color);
  }

  @override
  Widget build(BuildContext context) {
    const boxH = 160.0;
    return AlertDialog(
      key: const ValueKey('color-picker'),
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 280,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Saturation (left to right) and brightness (top to bottom) of the current hue.
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              void at(Offset p) {
                final s = (p.dx / w).clamp(0.0, 1.0), v = 1 - (p.dy / boxH).clamp(0.0, 1.0);
                _set(_hsv.withSaturation(s).withValue(v));
              }

              return GestureDetector(
                key: const ValueKey('picker-sv'),
                onPanDown: (d) => at(d.localPosition),
                onPanUpdate: (d) => at(d.localPosition),
                child: SizedBox(
                  width: w,
                  height: boxH,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          gradient: LinearGradient(colors: [Colors.white, HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor()]),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black]),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _hsv.saturation * w - 9,
                      top: (1 - _hsv.value) * boxH - 9,
                      child: IgnorePointer(
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: _color, border: Border.all(color: Colors.white, width: 2), boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black54)]),
                        ),
                      ),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 14),
            // Hue.
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              void at(Offset p) => _set(_hsv.withHue((p.dx / w).clamp(0.0, 1.0) * 359.999));
              return GestureDetector(
                key: const ValueKey('picker-hue'),
                onPanDown: (d) => at(d.localPosition),
                onPanUpdate: (d) => at(d.localPosition),
                child: SizedBox(
                  width: w,
                  height: 26,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(7),
                            gradient: LinearGradient(colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble() % 360, 1, 1).toColor()]),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (_hsv.hue / 360) * w - 10,
                      top: 3,
                      child: IgnorePointer(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(), border: Border.all(color: Colors.white, width: 2), boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black54)]),
                        ),
                      ),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 14),
            // Preview (old on the left, new on the right) and the hex value.
            Row(children: [
              _Swatch(key: const ValueKey('picker-old'), color: widget.initial, label: 'Current'),
              const SizedBox(width: 8),
              _Swatch(key: const ValueKey('picker-new'), color: _color, label: 'New'),
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  key: const ValueKey('picker-hex'),
                  controller: _hex,
                  focusNode: _hexFocus,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
                  decoration: const InputDecoration(labelText: 'Hex', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) {
                    final c = colorFromHex(v);
                    if (c != null) _set(HSVColor.fromColor(c), fromHex: true);
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
          ]),
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('picker-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('picker-select'), onPressed: () => Navigator.pop(context, _color), child: const Text('Select')),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: hint.withValues(alpha: 0.6))),
      ),
      const SizedBox(height: 3),
      Text(label, style: TextStyle(fontSize: 10, color: hint)),
    ]);
  }
}
