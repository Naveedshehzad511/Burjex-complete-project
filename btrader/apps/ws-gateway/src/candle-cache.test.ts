import type { CandleEvent } from '@btrader/shared';
import { LatestCandleCache } from './candle-cache';

const TFS = ['1m', '2m', '3m', '5m', '10m', '15m', '30m', '1h', '4h', '1d', '1w', '1mn'];

function ev(symbol: string, tf: string, t: number, c: number, kind: CandleEvent['kind'] = 'updated'): CandleEvent {
  return { kind, symbol, tf, t, o: c - 1, h: c + 1, l: c - 2, c, v: 0 };
}

describe('LatestCandleCache', () => {
  it('hands a subscriber the newest bar of every timeframe', () => {
    const cache = new LatestCandleCache();
    for (const tf of TFS) {
      cache.record('t1', ev('XAUUSD', tf, 1000, 10));
      cache.record('t1', ev('XAUUSD', tf, 1000, 11)); // same bucket, newer values
    }
    const snap = cache.snapshot('t1', 'XAUUSD');
    expect(snap.map((e) => e.tf).sort()).toEqual([...TFS].sort());
    for (const e of snap) expect(e.c).toBe(11);
  });

  it('a newer bucket replaces an older one, and an older bucket never replaces a newer one', () => {
    const cache = new LatestCandleCache();
    cache.record('t1', ev('XAUUSD', '1m', 1000, 10, 'closed'));
    cache.record('t1', ev('XAUUSD', '1m', 1060, 20, 'created'));
    cache.record('t1', ev('XAUUSD', '1m', 1000, 99)); // late replay of the previous bar
    const snap = cache.snapshot('t1', 'XAUUSD');
    expect(snap.length).toBe(1);
    expect(snap[0]!.t).toBe(1060);
    expect(snap[0]!.c).toBe(20);
  });

  it('stores the event exactly as published', () => {
    const cache = new LatestCandleCache();
    const e = ev('EURUSD', '5m', 300, 1.1);
    cache.record('t1', e);
    expect(cache.snapshot('t1', 'EURUSD')[0]).toBe(e);
  });

  it('is tenant scoped and symbol scoped', () => {
    const cache = new LatestCandleCache();
    cache.record('t1', ev('XAUUSD', '1m', 60, 10));
    expect(cache.snapshot('t2', 'XAUUSD')).toEqual([]);
    expect(cache.snapshot('t1', 'EURUSD')).toEqual([]);
  });

  it('ignores unusable events', () => {
    const cache = new LatestCandleCache();
    cache.record('t1', { ...ev('XAUUSD', '1m', 60, 10), h: NaN });
    cache.record('t1', { ...ev('XAUUSD', '1m', NaN, 10) });
    expect(cache.size).toBe(0);
  });

  it('stays bounded and keeps the symbol that was just written', () => {
    const cache = new LatestCandleCache(24);
    for (let i = 0; i < 100; i++) for (const tf of TFS) cache.record('t1', ev(`SYM${i}`, tf, 60, 10));
    expect(cache.size).toBeLessThanOrEqual(24);
    expect(cache.snapshot('t1', 'SYM99').length).toBe(TFS.length);
    expect(cache.snapshot('t1', 'SYM0')).toEqual([]);
  });
});
