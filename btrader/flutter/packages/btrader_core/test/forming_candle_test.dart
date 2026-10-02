import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const req = ChartReq('XAUUSD', Timeframe.m1);
  final bucket = Timeframe.m1.bucketStart(DateTime.now().millisecondsSinceEpoch ~/ 1000);

  ProviderContainer make() {
    final c = ProviderContainer(overrides: [
      candlesProvider.overrideWith((ref, r) async => <Candle>[]),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 60));

  Tick tick(double bid, {double? ask}) => Tick(symbol: 'XAUUSD', bid: bid, ask: ask ?? bid + 0.2, ts: bucket + 5);

  test('a lone spike tick does not stretch the forming candle\'s wick', () async {
    final c = make();
    final quotes = c.read(quotesProvider.notifier);
    c.listen(formingCandleProvider(req), (_, __) {});
    quotes.set(tick(2375.00));
    await flush();
    quotes.set(tick(2360.00)); // bad tick, ~0.6 % away
    await flush();
    quotes.set(tick(2375.20)); // price is back — the spike was never real
    await flush();
    final f = c.read(formingCandleProvider(req))!;
    expect(f.l, greaterThan(2374));
    expect(f.c, closeTo(2375.20, 1e-9));
  });

  test('a real jump confirmed by a second nearby tick is drawn', () async {
    final c = make();
    final quotes = c.read(quotesProvider.notifier);
    c.listen(formingCandleProvider(req), (_, __) {});
    quotes.set(tick(2375.00));
    await flush();
    quotes.set(tick(2360.00));
    await flush();
    quotes.set(tick(2360.10)); // second tick agrees: a genuine move
    await flush();
    final f = c.read(formingCandleProvider(req))!;
    expect(f.l, lessThan(2361));
    expect(f.c, closeTo(2360.10, 1e-9));
  });

  test('a tick with an absurd bid / ask spread is ignored', () async {
    final c = make();
    final quotes = c.read(quotesProvider.notifier);
    c.listen(formingCandleProvider(req), (_, __) {});
    quotes.set(tick(2375.00));
    await flush();
    quotes.set(tick(2360.00, ask: 2375.30)); // crossed-quality quote: 0.6 % spread
    await flush();
    final f = c.read(formingCandleProvider(req))!;
    expect(f.l, greaterThan(2374));
  });
}
