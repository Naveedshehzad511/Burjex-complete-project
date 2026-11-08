import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/state/trade_history.dart';
import 'package:burjex_portal/widgets/candle_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<Candle> _bars(int n) {
  const end = 1700000000 ~/ 300 * 300;
  final rnd = math.Random(11);
  var p = 1.1;
  return [
    for (var i = n - 1; i >= 0; i--)
      () {
        final o = p;
        p += (rnd.nextDouble() - 0.5) * 0.0008;
        return Candle(
            t: end - i * 300,
            o: o,
            h: math.max(o, p) + rnd.nextDouble() * 0.0003,
            l: math.min(o, p) - rnd.nextDouble() * 0.0003,
            c: p,
            v: 1 + rnd.nextDouble() * 100);
      }(),
  ];
}

void main() {
  testWidgets('bar chart renders without errors and differs from candles', (t) async {
    final key = GlobalKey();
    Widget host(ChartType type) => MaterialApp(
          theme: AppTheme.dark(Branding.fallback),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: SizedBox(width: 412, height: 700, child: CandleChart(candles: _bars(120), digits: 5, tf: Timeframe.m5, viewKey: 'bar', type: type)),
            ),
          ),
        );

    Future<List<int>> shot() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return (await t.runAsync(() async {
        final img = await b.toImage();
        final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        final out = Platform.environment['BAR_PNG'];
        if (out != null && png != null) await File(out).writeAsBytes(png.buffer.asUint8List());
        return d!.buffer.asUint8List().toList();
      }))!;
    }

    await t.pumpWidget(host(ChartType.candles));
    await t.pump();
    final candles = await shot();
    await t.pumpWidget(host(ChartType.bar));
    await t.pump();
    expect(t.takeException(), isNull);
    final bars = await shot();
    expect(bars, isNot(equals(candles)));
  });

  testWidgets('period separators draw only when enabled (M30, spans several days)', (t) async {
    final key = GlobalKey();
    final cs = [
      for (var i = 0; i < 400; i++)
        Candle(t: 1700000000 ~/ 1800 * 1800 - (399 - i) * 1800, o: 1.1 + (i % 7) * 0.0002, h: 1.1005 + (i % 7) * 0.0002, l: 1.0995 + (i % 7) * 0.0002, c: 1.1 + ((i + 3) % 7) * 0.0002, v: 1)
    ];
    Widget host(bool on) => MaterialApp(
          theme: AppTheme.dark(Branding.fallback),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: SizedBox(width: 412, height: 700, child: CandleChart(candles: cs, digits: 5, tf: Timeframe.m30, viewKey: 'sep', periodSeparators: on)),
            ),
          ),
        );
    Future<List<int>> shot(String? png) async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return (await t.runAsync(() async {
        final img = await b.toImage();
        final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final p = await img.toByteData(format: ui.ImageByteFormat.png);
        if (png != null && p != null) await File(png).writeAsBytes(p.buffer.asUint8List());
        return d!.buffer.asUint8List().toList();
      }))!;
    }

    await t.pumpWidget(host(false));
    await t.pump();
    final off = await shot(null);
    await t.pumpWidget(host(true));
    await t.pump();
    expect(t.takeException(), isNull);
    final on = await shot(Platform.environment['SEP_PNG']);
    expect(on, isNot(equals(off)));
    await t.pumpWidget(host(false));
    await t.pump();
    expect(await shot(null), equals(off), reason: 'turning it off restores the exact previous pixels');
  });

  testWidgets('closed frame: the top line stops at the price axis', (t) async {
    final key = GlobalKey();
    Widget host(bool closed) => MaterialApp(
          theme: AppTheme.dark(Branding.fallback),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: SizedBox(width: 412, height: 700, child: CandleChart(candles: _bars(120), digits: 5, tf: Timeframe.m5, viewKey: 'frame', closedFrame: closed)),
            ),
          ),
        );
    Future<(List<int>, List<int>)> topRightPixels() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return (await t.runAsync(() async {
        final img = await b.toImage();
        final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        List<int> px(int x, int y) => d.sublist((y * img.width + x) * 4, (y * img.width + x) * 4 + 4).toList();
        return (px(408, 0), px(408, 2)); // on the top frame row, and just below it — both beyond the axis
      }))!;
    }

    await t.pumpWidget(host(false));
    await t.pump();
    final open = await topRightPixels();
    expect(open.$1, isNot(equals(open.$2)), reason: 'default: the top line runs on across the price labels');
    await t.pumpWidget(host(true));
    await t.pump();
    final closed = await topRightPixels();
    expect(closed.$1, equals(closed.$2), reason: 'closed box: nothing is drawn past the axis on the top row');
  });

  group('trade history markers', () {
    ChartTrade trade(List<Candle> c, {int open = 70, int close = 100, String id = 't1', String pos = 'p1', bool buy = true}) => ChartTrade(
          id: id,
          positionId: pos,
          symbol: 'EURUSD',
          side: buy ? 'BUY' : 'SELL',
          volume: 0.5,
          openPrice: c[open].o,
          openTime: c[open].t + 30,
          closePrice: c[close].c,
          closeTime: c[close].t + 30,
          profit: 10,
          digits: 5,
        );

    testWidgets('arrows are drawn only when there are trades, can be tapped, and give back the exact pixels when removed', (t) async {
      final key = GlobalKey();
      final cs = _bars(120);
      final tapped = <(String, bool)>[];
      Widget host(List<ChartTrade> trades) => MaterialApp(
            theme: AppTheme.dark(Branding.fallback),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 412,
                  height: 700,
                  child: CandleChart(
                    candles: cs,
                    digits: 5,
                    tf: Timeframe.m5,
                    viewKey: 'mk',
                    trades: trades,
                    onTradeTap: (tr, exit) => tapped.add((tr.id, exit)),
                  ),
                ),
              ),
            ),
          );
      Future<Uint8List> shot() async {
        final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        return (await t.runAsync(() async {
          final img = await b.toImage();
          return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        }))!;
      }

      await t.pumpWidget(host(const []));
      await t.pump();
      final none = await shot();
      await t.pumpWidget(host([trade(cs)]));
      await t.pump();
      expect(t.takeException(), isNull);
      final withTrade = await shot();
      expect(withTrade, isNot(equals(none)));

      // Where the arrows are: the pixels that changed, dense columns = an arrow (the dashed line adds ~1 per column).
      const w = 412;
      final cols = List<int>.filled(w, 0);
      final colY = List<int>.filled(w, 0);
      for (var i = 0; i < none.length; i += 4) {
        if (none[i] != withTrade[i] || none[i + 1] != withTrade[i + 1] || none[i + 2] != withTrade[i + 2]) {
          final px = i ~/ 4, x = px % w, y = px ~/ w;
          cols[x]++;
          colY[x] += y;
        }
      }
      final dense = [for (var x = 0; x < w; x++) if (cols[x] >= 6) x];
      expect(dense, isNotEmpty, reason: 'both arrows are drawn');
      final split = [for (var i = 1; i < dense.length; i++) if (dense[i] - dense[i - 1] > 6) i];
      expect(split, hasLength(1), reason: 'exactly two arrows: the entry and the exit');
      List<int> run(int a, int b) => dense.sublist(a, b);
      Offset centre(List<int> xs) {
        var n = 0, sy = 0, sx = 0;
        for (final x in xs) {
          n += cols[x];
          sy += colY[x];
          sx += x * cols[x];
        }
        return Offset(sx / n, sy / n);
      }

      final entry = centre(run(0, split.single)), exit = centre(run(split.single, dense.length));
      expect(entry.dx, lessThan(exit.dx), reason: 'the entry is earlier on the time axis');
      final origin = t.getTopLeft(find.byType(CandleChart));
      await t.tapAt(origin + entry);
      await t.pump(const Duration(milliseconds: 400));
      await t.tapAt(origin + exit);
      await t.pump(const Duration(milliseconds: 400));
      expect(tapped, [('t1', false), ('t1', true)]);

      // A partly closed position draws its entry once: a second trade sharing the position adds only an exit.
      final both = [trade(cs), trade(cs, close: 110, id: 't2')];
      await t.pumpWidget(host(both));
      await t.pump();
      final entriesOnce = await shot();
      await t.pumpWidget(host([trade(cs), trade(cs, close: 110, id: 't2', pos: 'p2')]));
      await t.pump();
      final entriesTwice = await shot();
      expect(entriesOnce, isNot(equals(entriesTwice)), reason: 'a different position does draw its own entry');

      // Removing the trades gives back exactly the original pixels.
      await t.pumpWidget(host(const []));
      await t.pump();
      expect(await shot(), equals(none));
    });

    testWidgets('a trade far older than the loaded candles costs nothing and draws no arrow', (t) async {
      final cs = _bars(120);
      final old = ChartTrade(
        id: 'old',
        positionId: 'po',
        symbol: 'EURUSD',
        side: 'SELL',
        volume: 1,
        openPrice: 1.1,
        openTime: cs.first.t - 400 * 86400,
        closePrice: 1.1,
        closeTime: cs.first.t - 399 * 86400,
        profit: 1,
        digits: 5,
      );
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark(Branding.fallback),
        home: Scaffold(body: SizedBox(width: 412, height: 700, child: CandleChart(candles: cs, digits: 5, tf: Timeframe.m5, viewKey: 'old', trades: [old]))),
      ));
      final sw = Stopwatch()..start();
      await t.pump();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(t.takeException(), isNull);
    });

    test('marker x sits on the bar the time falls in, and continues past the loaded bars', () {
      final cs = _bars(10);
      const slot = 10.0;
      expect(xForTradeTime(cs, cs[3].t + 100, slot), 3 * slot + slot / 2, reason: 'inside bar 3');
      expect(xForTradeTime(cs, cs[3].t, slot), 3 * slot + slot / 2);
      expect(xForTradeTime(cs, cs.first.t - 3000, slot), lessThan(0), reason: 'before the first bar: to its left');
      expect(xForTradeTime(cs, cs.last.t + 3000, slot), greaterThan(9 * slot + slot / 2));
    });
  });
}
