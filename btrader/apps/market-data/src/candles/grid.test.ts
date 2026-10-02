import { CandleEngine, bucketStart } from './engine';

const H = 3600;
const OFF = 10800; // broker UTC+3 (BROKER_UTC_OFFSET_SEC=10800)
const at = (y: number, mo: number, d: number, h: number, mi = 0, s = 0) => Date.UTC(y, mo, d, h, mi, s) / 1000;

describe('bucketStart follows the broker clock for H4 and D1 only', () => {
  it('offset 0 is the plain UTC grid', () => {
    const t = at(2026, 9, 2, 10, 30);
    expect(bucketStart(t, '4h')).toBe(at(2026, 9, 2, 8, 0));
    expect(bucketStart(t, '1d')).toBe(at(2026, 9, 2, 0, 0));
  });

  it('H4 / D1 align to the broker grid (UTC+3): D1 opens at 21:00 UTC, H4 at 21, 01, 05 ... UTC', () => {
    const t = at(2026, 9, 2, 10, 30); // 13:30 broker time
    expect(bucketStart(t, '1d', OFF)).toBe(at(2026, 9, 1, 21, 0));
    expect(bucketStart(t, '4h', OFF)).toBe(at(2026, 9, 2, 9, 0)); // broker 12:00
    expect(bucketStart(at(2026, 9, 2, 8, 59, 59), '4h', OFF)).toBe(at(2026, 9, 2, 5, 0));
  });

  it('intraday timeframes are unaffected by the offset', () => {
    const t = at(2026, 9, 2, 10, 37, 21);
    for (const tf of ['1m', '5m', '15m', '30m', '1h']) {
      expect(bucketStart(t, tf, OFF)).toBe(bucketStart(t, tf, 0));
    }
    expect(bucketStart(t, '1h', OFF) % H).toBe(0);
  });

  it('the live engine and the history rollup agree on every H4 / D1 boundary', () => {
    // Same formula as the gateway tfBucketStart and the bridge aggregate().
    const history = (t: number, sec: number) => Math.floor((t + OFF) / sec) * sec - OFF;
    for (let t = at(2026, 9, 1, 0, 0); t < at(2026, 9, 4, 0, 0); t += 977) {
      expect(bucketStart(t, '4h', OFF)).toBe(history(t, 14400));
      expect(bucketStart(t, '1d', OFF)).toBe(history(t, 86400));
    }
  });

  it('the engine keeps one daily bar across the broker-day boundary, not the UTC one', () => {
    const e = new CandleEngine({ timeframes: ['1m', '1d'], brokerOffsetSec: OFF });
    // 22:00 UTC, 23:50 UTC and 00:05 UTC next day are the same broker day (opens 21:00 UTC).
    e.applyTick({ symbol: 'XAUUSD', bid: 2440, ask: 2440.1, timestamp: Date.UTC(2026, 9, 1, 22, 0) });
    e.applyTick({ symbol: 'XAUUSD', bid: 2450, ask: 2450.1, timestamp: Date.UTC(2026, 9, 1, 23, 50) });
    e.applyTick({ symbol: 'XAUUSD', bid: 2441, ask: 2441.1, timestamp: Date.UTC(2026, 9, 2, 0, 5) });
    const d1 = e.getActive('XAUUSD', '1d')!;
    expect(d1.t).toBe(at(2026, 9, 1, 21, 0));
    expect([d1.o, d1.h, d1.l, d1.c]).toEqual([2440, 2450, 2440, 2441]);
  });
});
