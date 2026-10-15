import 'package:btrader_core/btrader_core.dart';
import 'package:flutter_test/flutter_test.dart';

Tick tk(String s, double bid, int ts) => Tick(symbol: s, bid: bid, ask: bid + 0.1, ts: ts);
Future<void> ms(int n) => Future<void>.delayed(Duration(milliseconds: n));

void main() {
  // The real grace is 15 s; the logic is the same at 600 ms, which keeps the test fast.
  late QuotesNotifier q;
  FeedLiveNotifier live(String sym) =>
      FeedLiveNotifier(q, sym, grace: const Duration(milliseconds: 600), poll: const Duration(milliseconds: 40));
  setUp(() => q = QuotesNotifier());
  tearDown(() => q.dispose());

  test('the real grace is 15 seconds', () {
    expect(kFeedGrace, const Duration(seconds: 15));
  });

  test('recreated after the symbol went silent: starts grey, never flashes enabled', () async {
    q.set(tk('XAUUSD', 4190, 1000));
    await ms(700); // silent past the grace, with no notifier watching (chart closed)
    final f = live('XAUUSD'); // chart reopened
    final seen = <bool>[];
    f.addListener(seen.add, fireImmediately: true);
    await ms(100);
    expect(seen, [false]);
    q.set(tk('XAUUSD', 4190.2, 2000));
    f.check();
    expect(f.state, true);
    f.dispose();
  });

  test('recreated while the symbol is live: starts enabled', () async {
    q.set(tk('XAUUSD', 4190, 1000));
    await ms(100);
    final f = live('XAUUSD');
    expect(f.state, true);
    f.dispose();
  });

  test('feed available: stays enabled while ticks keep arriving', () async {
    final f = live('XAUUSD');
    for (var i = 1; i <= 12; i++) {
      q.set(tk('XAUUSD', 4190 + i * 0.1, 1000 + i));
      await ms(100);
    }
    expect(f.state, true);
    f.dispose();
  });

  test('feed stops: still enabled inside the grace, disabled after it', () async {
    final f = live('XAUUSD');
    q.set(tk('XAUUSD', 4190, 1000));
    await ms(250);
    expect(f.state, true, reason: 'not disabled immediately');
    await ms(250);
    expect(f.state, true, reason: 'still inside the grace');
    await ms(300);
    expect(f.state, false, reason: 'silent past the grace');
    f.dispose();
  });

  test('feed resumes within the grace: never goes grey; the countdown restarts', () async {
    final f = live('XAUUSD');
    final seen = <bool>[];
    f.addListener(seen.add);
    q.set(tk('XAUUSD', 4190, 1000));
    await ms(450);
    q.set(tk('XAUUSD', 4190.5, 1100));
    await ms(450);
    q.set(tk('XAUUSD', 4191, 1200));
    await ms(450);
    expect(f.state, true);
    expect(seen.contains(false), false);
    f.dispose();
  });

  test('feed resumes after it was disabled: enabled again at once', () async {
    final f = live('XAUUSD');
    q.set(tk('XAUUSD', 4190, 1000));
    await ms(900);
    expect(f.state, false);
    q.set(tk('XAUUSD', 4190.3, 2000));
    f.check(); // what the per-tick listener does
    expect(f.state, true);
    f.dispose();
  });

  test('another symbol going quiet does not disable a healthy one', () async {
    final gold = live('XAUUSD');
    final eur = live('EURUSD');
    q.set(tk('XAUUSD', 4190, 1000));
    q.set(tk('EURUSD', 1.17, 1000));
    for (var i = 1; i <= 12; i++) {
      q.set(tk('EURUSD', 1.17 + i * 0.0001, 1000 + i));
      await ms(100);
    }
    expect(eur.state, true);
    expect(gold.state, false);
    gold.dispose();
    eur.dispose();
  });

  test('only real updates count: a republished identical quote does not keep it alive', () async {
    final f = live('XAUUSD');
    q.set(tk('XAUUSD', 4190, 1000));
    for (var i = 0; i < 9; i++) {
      await ms(100);
      q.set(tk('XAUUSD', 4190, 1000)); // same price, same stamp
    }
    expect(f.state, false);
    f.dispose();
  });

  test('a snapshot seed is not a live update; an out-of-order older tick is ignored', () async {
    final f = live('XAUUSD');
    q.seedAll([tk('XAUUSD', 4190, 1000)]);
    await ms(700);
    expect(f.state, false, reason: 'a seeded price is not a live feed');
    q.set(tk('XAUUSD', 4191, 2000));
    f.check();
    expect(f.state, true);
    await ms(700);
    expect(f.state, false);
    q.set(tk('XAUUSD', 4190, 1500)); // older than what is held: rejected
    f.check();
    expect(f.state, false);
    f.dispose();
  });

  test('a feed that never arrives is disabled after the grace too', () async {
    final f = live('NEWSYM');
    expect(f.state, true);
    await ms(700);
    expect(f.state, false);
    f.dispose();
  });
}
