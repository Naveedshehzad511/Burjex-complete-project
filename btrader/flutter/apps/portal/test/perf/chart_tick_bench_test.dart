// What a live tick costs end to end on the real chart screen (providers -> ChartsScreen rebuild ->
// CandleChart). Not part of the normal suite:
//
//   CHART_BENCH=1 flutter test test/perf/chart_tick_bench_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:burjex_portal/screens/charts_screen.dart';

class _Api extends ApiClient {
  _Api(this.n) : super(AuthStore());
  final int n;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/market/candles') {
      final tf = '${query?['tf']}';
      final step = Timeframe.values.firstWhere((t) => t.api == tf).seconds;
      final end = (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ step * step - step;
      final rnd = math.Random(3);
      var p = 1.1;
      final limit = int.tryParse('${query?['limit']}') ?? n;
      return [
        for (var i = math.min(limit, n) - 1; i >= 0; i--)
          () {
            final o = p;
            p += (rnd.nextDouble() - 0.5) * 0.0006;
            return {'t': end - i * step, 'o': o, 'h': math.max(o, p) + 0.0002, 'l': math.min(o, p) - 0.0002, 'c': p, 'v': 1};
          }()
      ];
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async => <String, dynamic>{};
  @override
  Future<dynamic> patch(String path, [dynamic body]) async => <String, dynamic>{};
}

class Stat {
  Stat(List<double> ms) {
    final s = [...ms]..sort();
    mean = s.reduce((a, b) => a + b) / s.length;
    p50 = s[s.length ~/ 2];
    p95 = s[(s.length * 0.95).floor().clamp(0, s.length - 1)];
    max = s.last;
  }
  late final double mean, p50, p95, max;
  @override
  String toString() => 'mean ${mean.toStringAsFixed(2)}  p50 ${p50.toStringAsFixed(2)}  p95 ${p95.toStringAsFixed(2)}  max ${max.toStringAsFixed(2)} ms';
}

class CountingViewport extends ValueNotifier<({double offset, double slot})> {
  CountingViewport() : super((offset: 0, slot: 1));
  int builds = 0;
  @override
  set value(({double offset, double slot}) v) {
    builds++;
    super.value = v;
  }
}

void main() {
  final on = Platform.environment.containsKey('CHART_BENCH');

  testWidgets('a live tick, end to end', (t) async {
    t.view
      ..physicalSize = const Size(420, 800)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final out = StringBuffer('\n── live tick -> frame (ChartsScreen rebuild), ms ──\n');
    for (final n in [5000, 20000]) {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(_Api(n)),
        marketSocketProvider.overrideWith((_) => null),
        feedSubscriptionProvider.overrideWith((_) {}),
        accountsProvider.overrideWith((_) async => const <Account>[]),
        activeAccountIdProvider.overrideWith((_) => 'A1'),
        openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
        symbolsProvider.overrideWith((_) async => <TradeSymbol>[]),
      ]);
      c.read(quotesProvider.notifier).set(const Tick(symbol: 'EURUSD', bid: 1.10000, ask: 1.10020, ts: 0));
      await t.pumpWidget(UncontrolledProviderScope(
        key: UniqueKey(),
        container: c,
        child: MaterialApp(theme: AppTheme.dark(Branding.fallback), home: const ChartsScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      Stat stat(List<double> v) => Stat(v);
      final sw = Stopwatch();
      var bid = 1.1;
      Future<double> tick(int i) async {
        bid += (i.isEven ? 1 : -1) * 0.00002;
        c.read(quotesProvider.notifier).set(Tick(symbol: 'EURUSD', bid: bid, ask: bid + 0.0002, ts: DateTime.now().millisecondsSinceEpoch ~/ 1000));
        sw
          ..reset()
          ..start();
        await t.pump(const Duration(milliseconds: 16));
        sw.stop();
        return sw.elapsedMicroseconds / 1000;
      }

      // warm the JIT first: the first frames of a VM run are several times slower than steady state
      for (var i = 0; i < 100; i++) {
        await tick(i);
      }
      final ticks = <double>[for (var i = 0; i < 150; i++) await tick(i)];

      // a tick for a symbol this chart is NOT showing (the app streams every subscribed symbol)
      final other = <double>[];
      var ob = 1.3;
      for (var i = 0; i < 100; i++) {
        ob += (i.isEven ? 1 : -1) * 0.00002;
        c.read(quotesProvider.notifier).set(Tick(symbol: 'GBPUSD', bid: ob, ask: ob + 0.0002, ts: DateTime.now().millisecondsSinceEpoch ~/ 1000));
        sw
          ..reset()
          ..start();
        await t.pump(const Duration(milliseconds: 16));
        sw.stop();
        if (i >= 20) other.add(sw.elapsedMicroseconds / 1000);
      }
      final idle = <double>[];
      for (var i = 0; i < 150; i++) {
        sw
          ..reset()
          ..start();
        await t.pump(const Duration(milliseconds: 16));
        sw.stop();
        idle.add(sw.elapsedMicroseconds / 1000);
      }

      // What exactly does one tick rebuild / re-layout?
      final rebuilt = <String>[];
      final laid = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m == null) return;
        if (m.startsWith('Laying out')) {
          laid.add(m);
        } else {
          rebuilt.add(m);
        }
      };
      debugPrintRebuildDirtyWidgets = true;
      debugPrintLayouts = true;
      await tick(0);
      debugPrintRebuildDirtyWidgets = false;
      debugPrintLayouts = false;
      debugPrint = oldPrint;
      final byType = <String, int>{};
      for (final m in rebuilt) {
        final name = m.replaceAll(RegExp(r'^\s*Building\s+'), '').split(RegExp(r'[( \[]')).first;
        byType[name] = (byType[name] ?? 0) + 1;
      }
      final top = byType.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      out.writeln('   one tick rebuilds ${rebuilt.length} widgets, re-lays-out ${laid.length} render objects; most rebuilt:');
      out.writeln('     ${top.take(14).map((e) => '${e.key}x${e.value}').join('  ')}');

      // pan on the same screen: only the CandleChart's own state rebuilds
      final g = await t.startGesture(const Offset(210, 400));
      await g.moveBy(const Offset(40, 0));
      await t.pump(const Duration(milliseconds: 16));
      final pans = <double>[];
      var dir = 1.0;
      for (var i = 0; i < 170; i++) {
        if (i % 40 == 0) dir = -dir;
        sw
          ..reset()
          ..start();
        await g.moveBy(Offset(3 * dir, 0));
        await t.pump(const Duration(milliseconds: 16));
        sw.stop();
        if (i >= 20) pans.add(sw.elapsedMicroseconds / 1000);
      }
      await t.pump(const Duration(milliseconds: 200));
      await g.up();
      await t.pump(const Duration(seconds: 3));

      out.writeln('${n.toString().padLeft(6)} bars (steady state)');
      out.writeln('   idle frame (nothing changed) : ${stat(idle)}');
      out.writeln('   tick of ANOTHER symbol       : ${stat(other)}');
      out.writeln('   live tick frame              : ${stat(ticks)}');
      out.writeln('   pan frame (chart only)       : ${stat(pans)}');
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(seconds: 1));
    }
    // ignore: avoid_print
    print(out);
  }, skip: !on, timeout: const Timeout(Duration(minutes: 10)));
}
