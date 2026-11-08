import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/chart_colors_screen.dart';
import 'package:burjex_portal/state/chart_colors.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:burjex_portal/widgets/color_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<Candle> _bars(int n) {
  const end = 1700000000 ~/ 300 * 300;
  final rnd = math.Random(11);
  var p = 1.1;
  return [
    for (var i = n - 1; i >= 0; i--)
      () {
        final o = p;
        p += (rnd.nextDouble() - 0.5) * 0.0008;
        return Candle(t: end - i * 300, o: o, h: math.max(o, p) + rnd.nextDouble() * 0.0003, l: math.min(o, p) - rnd.nextDouble() * 0.0003, c: p, v: 1 + rnd.nextDouble() * 100);
      }(),
  ];
}

Widget _screen(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(Branding.fallback), home: const ChartColorsScreen()),
    );

Color _swatch(WidgetTester t, ChartColorKey k) =>
    ((t.widget<Container>(find.byKey(ValueKey('cc-swatch-${k.name}')))).decoration as BoxDecoration).color!;

Future<void> _pickHex(WidgetTester t, ChartColorKey k, String hex) async {
  final row = find.byKey(ValueKey('cc-row-${k.name}'));
  await _reveal(t, row);
  await t.tap(row);
  await t.pumpAndSettle();
  expect(find.byKey(const ValueKey('color-picker')), findsOneWidget);
  await t.enterText(find.byKey(const ValueKey('picker-hex')), hex);
  await t.pump();
  await t.tap(find.byKey(const ValueKey('picker-select')));
  await t.pumpAndSettle();
}

bool _hasColor(Uint8List rgba, Color c, {int tol = 0}) {
  final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
  for (var i = 0; i < rgba.length; i += 4) {
    if ((rgba[i] - r).abs() <= tol && (rgba[i + 1] - g).abs() <= tol && (rgba[i + 2] - b).abs() <= tol) return true;
  }
  return false;
}

/// Scrolls the Colors list (down first, then up) until [target] has been built, then makes it visible.
Future<void> _reveal(WidgetTester t, Finder target, {bool down = true}) async {
  final list = find.byKey(const ValueKey('chart-colors-list'));
  for (final dir in [down, !down]) {
    for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
      await t.drag(list, Offset(0, dir ? -200 : 300));
      await t.pump(const Duration(milliseconds: 50));
    }
  }
  expect(target, findsOneWidget);
  await t.ensureVisible(target);
  await t.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('colour model', () {
    test('Default changes nothing; the predefined schemes name every element', () {
      expect(const ChartColorsState().palette.isEmpty, isTrue);
      for (final s in [ChartScheme.colorOnWhite, ChartScheme.greenOnBlack, ChartScheme.blackOnWhite]) {
        for (final k in ChartColorKey.values) {
          expect(kSchemePalettes[s]![k], isNotNull, reason: '${s.label} lacks ${k.label}');
        }
      }
      expect(kSchemePalettes[ChartScheme.colorOnWhite]![ChartColorKey.background], const Color(0xFF000000), reason: 'MT5 Color on White: white foreground on a dark chart');
      expect(kSchemePalettes[ChartScheme.greenOnBlack]![ChartColorKey.background], const Color(0xFF000000));
      expect(kSchemePalettes[ChartScheme.blackOnWhite]![ChartColorKey.background], const Color(0xFFFFFFFF));
      expect(ChartScheme.values.map((e) => e.label), ['Default', 'Color on White', 'Green on Black', 'Black on White']);
    });

    test('a single edit sits on top of the scheme without touching the others', () {
      const red = Color(0xFFFF0000);
      final st = const ChartColorsState(scheme: ChartScheme.greenOnBlack).palette;
      final edited = ChartColorsState(scheme: ChartScheme.greenOnBlack, edits: {ChartColorKey.bullCandle: red});
      expect(edited.palette[ChartColorKey.bullCandle], red);
      for (final k in ChartColorKey.values.where((k) => k != ChartColorKey.bullCandle)) {
        expect(edited.palette[k], st[k], reason: k.label);
      }
      expect(edited.schemeLabel, 'Custom');
      expect(const ChartColorsState(scheme: ChartScheme.colorOnWhite).schemeLabel, 'Color on White');
      expect(const ChartColorsState(scheme: ChartScheme.greenOnBlack, custom: true).schemeLabel, 'Custom', reason: 'choosing Custom in the selector');
      expect(edited.palette == ChartColorsState(scheme: ChartScheme.greenOnBlack, edits: {ChartColorKey.bullCandle: red}).palette, isTrue, reason: 'value-equal: no needless repaints');
    });

    test('hex helpers', () {
      expect(colorToHex(const Color(0xFF26A69A)), '#26A69A');
      expect(colorFromHex('#26a69a'), const Color(0xFF26A69A));
      expect(colorFromHex('FF0000'), const Color(0xFFFF0000));
      expect(colorFromHex('#12345'), isNull);
      expect(colorFromHex('GGGGGG'), isNull);
    });

    test('saved colours and scheme survive a restart; selecting a scheme clears single edits', () async {
      final a = ProviderContainer();
      a.read(chartColorsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      a.read(chartColorsProvider.notifier).apply(ChartScheme.blackOnWhite, {ChartColorKey.slLine: const Color(0xFF123456)}, custom: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.dispose();

      final b = ProviderContainer();
      addTearDown(b.dispose);
      b.read(chartColorsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final s = b.read(chartColorsProvider);
      expect(s.scheme, ChartScheme.blackOnWhite);
      expect(s.custom, isTrue);
      expect(s.palette[ChartColorKey.slLine], const Color(0xFF123456));
      expect(s.palette[ChartColorKey.background], const Color(0xFFFFFFFF));

      b.read(chartColorsProvider.notifier).setScheme(ChartScheme.greenOnBlack);
      expect(b.read(chartColorsProvider).edits, isEmpty);
      expect(b.read(chartColorsProvider).palette[ChartColorKey.slLine], kSchemePalettes[ChartScheme.greenOnBlack]![ChartColorKey.slLine]);
    });
  });

  group('Colors screen', () {
    testWidgets('lists every element with a circle, a scheme selector and SAVE', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(_screen(c));
      await t.pump();
      expect(find.text('Colors'), findsOneWidget);
      expect(find.byKey(const ValueKey('cc-save')), findsOneWidget);
      expect(find.byKey(const ValueKey('cc-scheme')), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      for (final k in ChartColorKey.values) {
        final row = find.byKey(ValueKey('cc-row-${k.name}'));
        await _reveal(t, row);
        expect(row, findsOneWidget, reason: k.label);
        expect(find.descendant(of: row, matching: find.text(k.label)), findsOneWidget);
        expect(find.byKey(ValueKey('cc-swatch-${k.name}')), findsOneWidget);
      }
      expect(find.text('Last price line'), findsNothing, reason: 'the app has no Last line to colour');
    });

    testWidgets('picking a colour updates its circle at once, changes nothing else, and SAVE applies it', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(_screen(c));
      await t.pump();
      final bearBefore = _swatch(t, ChartColorKey.bearCandle);
      await _pickHex(t, ChartColorKey.bullCandle, '00FF00');
      expect(_swatch(t, ChartColorKey.bullCandle), const Color(0xFF00FF00), reason: 'the circle shows the new colour straight away');
      expect(_swatch(t, ChartColorKey.bearCandle), bearBefore, reason: 'nothing else moved');
      await _reveal(t, find.byKey(const ValueKey('cc-scheme')), down: false);
      expect(find.text('Custom'), findsOneWidget);
      expect(c.read(chartColorsProvider).palette.isEmpty, isTrue, reason: 'a draft until SAVE');

      await t.tap(find.byKey(const ValueKey('cc-save')));
      await t.pumpAndSettle();
      expect(c.read(chartColorsProvider).palette[ChartColorKey.bullCandle], const Color(0xFF00FF00));
      expect(c.read(chartColorsProvider).palette[ChartColorKey.bearCandle], isNull);
    });

    testWidgets('a scheme sets every colour; a later single edit keeps all the other scheme colours', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(_screen(c));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cc-scheme')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cc-scheme-colorOnWhite')));
      await t.pumpAndSettle();
      expect(find.text('Color on White'), findsOneWidget);
      final pal = kSchemePalettes[ChartScheme.colorOnWhite]!;
      // Change ONE colour on top of the scheme (the Grid row is on screen at the top of the list).
      await _pickHex(t, ChartColorKey.grid, '445566');
      await _reveal(t, find.byKey(const ValueKey('cc-scheme')), down: false);
      expect(find.text('Custom'), findsOneWidget);
      // Every other colour is still the scheme's; only the grid is the user's.
      for (final k in ChartColorKey.values) {
        await _reveal(t, find.byKey(ValueKey('cc-swatch-${k.name}')));
        expect(_swatch(t, k), k == ChartColorKey.grid ? const Color(0xFF445566) : pal[k], reason: k.label);
      }
      await t.tap(find.byKey(const ValueKey('cc-save')));
      await t.pumpAndSettle();
      final p = c.read(chartColorsProvider).palette;
      expect(p[ChartColorKey.grid], const Color(0xFF445566));
      expect(p[ChartColorKey.background], pal[ChartColorKey.background]);
      expect(p[ChartColorKey.buyLine], pal[ChartColorKey.buyLine]);
    });

    testWidgets('the Scheme selector lists MT5\'s schemes and Custom; Custom keeps the colours as they are', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(_screen(c));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cc-scheme')));
      await t.pumpAndSettle();
      for (final label in ['Default', 'Color on White', 'Green on Black', 'Black on White', 'Custom']) {
        expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)), findsOneWidget, reason: label);
      }
      await t.tap(find.byKey(const ValueKey('cc-scheme-greenOnBlack')));
      await t.pumpAndSettle();
      final before = _swatch(t, ChartColorKey.bullCandle);
      await t.tap(find.byKey(const ValueKey('cc-scheme')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cc-scheme-custom')));
      await t.pumpAndSettle();
      expect(find.text('Custom'), findsOneWidget);
      expect(_swatch(t, ChartColorKey.bullCandle), before, reason: 'choosing Custom changes no colour');
      await t.tap(find.byKey(const ValueKey('cc-save')));
      await t.pumpAndSettle();
      final st = c.read(chartColorsProvider);
      expect((st.scheme, st.custom, st.schemeLabel), (ChartScheme.greenOnBlack, true, 'Custom'));
      expect(st.palette[ChartColorKey.bullCandle], kSchemePalettes[ChartScheme.greenOnBlack]![ChartColorKey.bullCandle]);
    });

    testWidgets('leaving with unsaved changes asks; Discard keeps the old colours, Cancel stays', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(Branding.fallback),
          home: Builder(builder: (ctx) => Scaffold(body: Center(child: ElevatedButton(onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const ChartColorsScreen())), child: const Text('open'))))),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await _pickHex(t, ChartColorKey.chartLine, 'FF8800');
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('cc-discard')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cc-discard-cancel')));
      await t.pumpAndSettle();
      expect(find.text('Colors'), findsOneWidget, reason: 'still on the screen');
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cc-discard-drop')));
      await t.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(c.read(chartColorsProvider).palette.isEmpty, isTrue);
    });

    testWidgets('the picker is a real picker: drag the box and the hue, see a preview, cancel changes nothing', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.pumpWidget(_screen(c));
      await t.pump();
      final row = find.byKey(const ValueKey('cc-row-barUp'));
      await t.tap(row);
      await t.pumpAndSettle();
      final before = colorFromHex((t.widget<TextField>(find.byKey(const ValueKey('picker-hex'))).controller!.text))!;
      final box = find.byKey(const ValueKey('picker-sv'));
      await t.tapAt(t.getTopLeft(box) + const Offset(5, 5)); // top-left corner: white
      await t.pump();
      final nearWhite = colorFromHex(t.widget<TextField>(find.byKey(const ValueKey('picker-hex'))).controller!.text)!;
      expect([nearWhite.r, nearWhite.g, nearWhite.b].every((v) => v > 0.9), isTrue, reason: 'top-left of the box is (almost) white');
      await t.tapAt(t.getTopLeft(box) + Offset(t.getSize(box).width - 1, 1)); // top-right: the pure hue
      await t.pump();
      final hue = find.byKey(const ValueKey('picker-hue'));
      await t.tapAt(t.getTopLeft(hue) + Offset(t.getSize(hue).width * 0.34, 13)); // ~ green
      await t.pump();
      final hex = t.widget<TextField>(find.byKey(const ValueKey('picker-hex'))).controller!.text;
      final g = colorFromHex(hex)!;
      expect(g.g, greaterThan(g.r));
      final newSwatch = (t.widget<Container>(find.descendant(of: find.byKey(const ValueKey('picker-new')), matching: find.byType(Container)).first).decoration as BoxDecoration).color;
      expect(newSwatch, g, reason: 'the preview shows the colour being chosen');
      final oldSwatch = (t.widget<Container>(find.descendant(of: find.byKey(const ValueKey('picker-old')), matching: find.byType(Container)).first).decoration as BoxDecoration).color;
      expect(oldSwatch, before);
      await t.tap(find.byKey(const ValueKey('picker-cancel')));
      await t.pumpAndSettle();
      expect(_swatch(t, ChartColorKey.barUp), before);
    });
  });

  group('the chart paints the chosen colours', () {
    Future<(Uint8List, WidgetTester)> render(WidgetTester t, ChartPalette pal, {ChartType type = ChartType.candles, bool free = true, int n = 40}) async {
      final key = GlobalKey();
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark(Branding.fallback),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: SizedBox(width: 412, height: 700, child: CandleChart(candles: _bars(n), digits: 5, tf: Timeframe.m5, viewKey: 'c', type: type, palette: pal, freeMovement: free)),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final px = (await t.runAsync(() async => (await (await b.toImage()).toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List()))!;
      return (px, t);
    }

    const green = Color(0xFF00FF00), magenta = Color(0xFFFF00FF), yellow = Color(0xFFFFFF00), cyan = Color(0xFF00FFFF);

    testWidgets('bull / bear candles, bars, chart line and the background each take their own colour', (t) async {
      final plain = (await render(t, ChartPalette.empty)).$1;
      expect(_hasColor(plain, green), isFalse);

      final candles = (await render(t, const ChartPalette({ChartColorKey.bullCandle: green, ChartColorKey.bearCandle: magenta}))).$1;
      expect(_hasColor(candles, green), isTrue, reason: 'bull candles');
      expect(_hasColor(candles, magenta), isTrue, reason: 'bear candles');

      // Bars use Bar up / Bar down, not the candle colours.
      final bars = (await render(t, const ChartPalette({ChartColorKey.barUp: yellow, ChartColorKey.barDown: cyan, ChartColorKey.bullCandle: green, ChartColorKey.bearCandle: magenta}), type: ChartType.bar)).$1;
      expect(_hasColor(bars, yellow, tol: 40), isTrue, reason: 'bar up');
      expect(_hasColor(bars, cyan, tol: 40), isTrue, reason: 'bar down');
      expect(_hasColor(bars, green), isFalse, reason: 'candle colours are not used for bars');

      final line = (await render(t, const ChartPalette({ChartColorKey.chartLine: yellow}), type: ChartType.line)).$1;
      expect(_hasColor(line, yellow, tol: 60), isTrue, reason: 'chart line');

      // Background: the whole chart canvas, wherever nothing else is drawn.
      final bg = (await render(t, const ChartPalette({ChartColorKey.background: Color(0xFF102030)}))).$1;
      const w = 412;
      int at(int x, int y) => (y * w + x) * 4;
      expect([bg[at(1, 400)], bg[at(1, 400) + 1], bg[at(1, 400) + 2]], [0x10, 0x20, 0x30]);
      expect([plain[at(1, 400)], plain[at(1, 400) + 1], plain[at(1, 400) + 2]], isNot([0x10, 0x20, 0x30]));
    });

    testWidgets('grid lines appear only when a grid colour is set; Default draws none', (t) async {
      final none = (await render(t, ChartPalette.empty)).$1;
      final other = (await render(t, const ChartPalette({ChartColorKey.bullCandle: green}))).$1;
      final grid = (await render(t, const ChartPalette({ChartColorKey.grid: Color(0xFFFF0000)}))).$1;
      expect(grid, isNot(equals(none)));
      // A palette without a grid colour adds no grid: only the candles differ, so far fewer pixels change than with a grid.
      int diff(Uint8List a, Uint8List b) {
        var n = 0;
        for (var i = 0; i < a.length; i += 4) {
          if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) n++;
        }
        return n;
      }

      expect(diff(grid, none), greaterThan(300), reason: 'dashed horizontal + vertical lines');
      expect(diff(other, none), greaterThan(0));
    });

    testWidgets('the Default palette draws exactly what the chart drew before', (t) async {
      final a = (await render(t, ChartPalette.empty)).$1;
      final b = (await render(t, const ChartPalette({}))).$1;
      expect(a, equals(b));
    });
  });

  group('Free chart movement', () {
    Future<Uint8List> shot(WidgetTester t, GlobalKey key) async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return (await t.runAsync(() async => (await (await b.toImage()).toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List()))!;
    }

    Widget host(GlobalKey key, bool free) => MaterialApp(
          theme: AppTheme.dark(Branding.fallback),
          home: Scaffold(
            body: RepaintBoundary(key: key, child: SizedBox(width: 412, height: 700, child: CandleChart(candles: _bars(120), digits: 5, tf: Timeframe.m5, viewKey: 'fm', freeMovement: free))),
          ),
        );

    Future<void> dragDown(WidgetTester t) async {
      final g = await t.startGesture(const Offset(200, 300));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, 14));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump(const Duration(milliseconds: 400));
    }

    testWidgets('on: a vertical drag moves the chart; off (Auto-scale): it does not, and the scale keeps fitting the bars', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(host(key, true));
      await t.pump();
      final start = await shot(t, key);
      await dragDown(t);
      expect(await shot(t, key), isNot(equals(start)), reason: 'free: the chart moved vertically');

      await t.pumpWidget(host(GlobalKey(), true)); // fresh chart
      final key2 = GlobalKey();
      await t.pumpWidget(host(key2, false));
      await t.pump();
      final start2 = await shot(t, key2);
      await dragDown(t);
      expect(await shot(t, key2), equals(start2), reason: 'auto-scale: a vertical drag changes nothing');
      expect(t.takeException(), isNull);
    });

    testWidgets('switching Free movement off drops an existing vertical shift at once', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(host(key, true));
      await t.pump();
      final start = await shot(t, key);
      await dragDown(t);
      expect(await shot(t, key), isNot(equals(start)));
      await t.pumpWidget(host(key, false));
      await t.pump();
      expect(await shot(t, key), equals(start), reason: 'back to the auto-fitted scale');
    });

    testWidgets('horizontal movement still works in Auto-scale', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(host(key, false));
      await t.pump();
      final start = await shot(t, key);
      final g = await t.startGesture(const Offset(200, 300));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(14, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump(const Duration(milliseconds: 400));
      expect(await shot(t, key), isNot(equals(start)), reason: 'horizontal scrolling is untouched');
    });
  });
}
