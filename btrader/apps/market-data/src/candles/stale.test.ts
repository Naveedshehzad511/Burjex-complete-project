import { CandleEngine } from './engine';

const T0 = Date.UTC(2026, 0, 5, 12, 0, 0); // Monday noon UTC
const MIN = 60_000;

function tick(price: number, ts: number) {
  return { symbol: 'XAUUSD', bid: price, ask: price + 0.05, timestamp: ts, volume: 1 };
}

describe('stale feed does not manufacture bars', () => {
  it('keeps forming bars while the price moves', () => {
    const e = new CandleEngine({ timeframes: ['1m'] });
    e.applyTick(tick(4376.66, T0));
    // A real move in each of the next three minutes.
    for (let i = 1; i <= 3; i++) e.applyTick(tick(4376.66 + i, T0 + i * MIN));
    const bars = new Set<number>();
    for (let i = 0; i <= 3; i++) {
      for (const u of e.applyTick(tick(4380 + i, T0 + (10 + i) * MIN))) bars.add(u.candle.t);
    }
    expect(bars.size).toBeGreaterThan(1);
  });

  it('stops creating bars once the price is static past the window', () => {
    const e = new CandleEngine({ timeframes: ['1m'], staleMs: 3 * MIN });
    e.applyTick(tick(4376.66, T0));
    // Market closes: same price republished every minute for two hours.
    let created = 0;
    for (let i = 1; i <= 120; i++) {
      for (const u of e.applyTick(tick(4376.66, T0 + i * MIN))) {
        if (!u.closed) created++;
      }
    }
    // Only the ticks inside the staleness window may extend/roll a bar.
    expect(created).toBeLessThanOrEqual(4);
  });

  it('resumes immediately when the market reopens', () => {
    const e = new CandleEngine({ timeframes: ['1m'], staleMs: 3 * MIN });
    e.applyTick(tick(4376.66, T0));
    for (let i = 1; i <= 120; i++) e.applyTick(tick(4376.66, T0 + i * MIN)); // weekend
    const out = e.applyTick(tick(4380.12, T0 + 121 * MIN)); // reopen, price moves
    expect(out.length).toBeGreaterThan(0);
    expect(out.some((u) => u.candle.c === 4380.12)).toBe(true);
  });

  it('a genuinely quiet but live minute still forms its bar', () => {
    const e = new CandleEngine({ timeframes: ['1m'], staleMs: 3 * MIN });
    e.applyTick(tick(4376.66, T0));
    // Same price 1 minute later — inside the window, so still a real bar.
    const out = e.applyTick(tick(4376.66, T0 + MIN));
    expect(out.some((u) => u.candle.t === Math.floor((T0 + MIN) / 1000))).toBe(true);
  });
});
