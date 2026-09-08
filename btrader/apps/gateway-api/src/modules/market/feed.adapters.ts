import { prisma } from '@btrader/db';
import { Candle, CandleQuery, ChartFeedAdapter, Timeframe, TF_SECONDS } from './feed.types';

/**
 * Internal candle store — serves OHLC from B-Trader's market_candles table
 * (MT5 ChartRequest M1 pushed by the bridge).
 *
 * Spec: M1 is the only base. Higher TFs are pure M1 rollups (same OHLC rules
 * as MT5 Terminal / mt5_bridge.aggregate). Pre-baked TF rows are ignored when
 * M1 coverage exists so API and mobile never disagree.
 */
export class InternalAdapter implements ChartFeedAdapter {
  readonly name = 'internal';
  async fetchCandles(q: CandleQuery): Promise<Candle[]> {
    const symbol = q.symbol.toUpperCase();
    const brokerOff = brokerUtcOffsetSec();

    if (q.tf === '1m') {
      return loadSeries(symbol, '1m', q.limit);
    }

    // Prefer deep M1 → rollup (authoritative). Fall back to stored TF only if
    // M1 is empty (legacy / mid-seed).
    const m1Need = m1BarsNeeded(q.tf, q.limit);
    const m1 = await loadSeries(symbol, '1m', m1Need);
    if (m1.length > 0) {
      const rolled = aggregateFromM1(m1, q.tf, brokerOff);
      return rolled.slice(-q.limit);
    }

    // Legacy fallback: stored series / D1→W1/MN.
    if (q.tf === '1w' || q.tf === '1mn') {
      const d1 = await loadSeries(symbol, '1d', 5000);
      const bucket = q.tf === '1w' ? weekBucketUtc : monthBucketUtc;
      return aggregateCandles(d1, bucket).slice(-q.limit);
    }
    return loadSeries(symbol, q.tf, q.limit);
  }
}

function brokerUtcOffsetSec(): number {
  const raw = process.env.BROKER_UTC_OFFSET_SEC;
  if (raw == null || raw === '') return 0;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : 0;
}

async function loadSeries(symbol: string, tf: string, limit: number): Promise<Candle[]> {
  const take = Math.min(Math.max(limit, 1), 5000);
  const rows = await prisma.marketCandle.findMany({
    where: { symbol, tf },
    orderBy: { t: 'desc' },
    take,
    select: { t: true, o: true, h: true, l: true, c: true, v: true },
  });
  return rows.reverse().map((r) => ({ t: r.t, o: +r.o, h: +r.h, l: +r.l, c: +r.c, v: +r.v }));
}

function m1BarsNeeded(tf: Timeframe, tfBars: number): number {
  if (tf === '1m') return tfBars;
  if (tf === '1w') return Math.min(5000, tfBars * 5 * 1440);
  if (tf === '1mn') return Math.min(5000, tfBars * 22 * 1440);
  const sec = TF_SECONDS[tf];
  return Math.min(5000, Math.max(tfBars, tfBars * Math.floor(sec / 60)));
}

/** MT5-style rollup from ascending M1 bars (matches mt5_bridge.aggregate). */
export function aggregateFromM1(m1: Candle[], tf: Timeframe, brokerOffsetSec = 0): Candle[] {
  if (tf === '1m') return m1;
  if (tf === '1w' || tf === '1mn') {
    const d1 = aggregateFromM1(m1, '1d', brokerOffsetSec);
    const bucket = tf === '1w' ? weekBucketUtc : monthBucketUtc;
    return aggregateCandles(d1, bucket);
  }
  const sec = TF_SECONDS[tf];
  return aggregateCandles(m1, (t) => tfBucketStart(t, sec, brokerOffsetSec));
}

function tfBucketStart(t: number, tfSeconds: number, brokerOffsetSec: number): number {
  const off = brokerOffsetSec || 0;
  if (tfSeconds >= 14400 && off !== 0) {
    return Math.floor((t + off) / tfSeconds) * tfSeconds - off;
  }
  return Math.floor(t / tfSeconds) * tfSeconds;
}

/** Start of the ISO week (Monday 00:00 UTC) containing epoch-seconds `t`. */
function weekBucketUtc(t: number): number {
  const d = new Date(t * 1000);
  const daysFromMon = (d.getUTCDay() + 6) % 7; // getUTCDay: 0=Sun..6=Sat
  return Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - daysFromMon) / 1000);
}

/** Start of the calendar month (1st, 00:00 UTC) containing epoch-seconds `t`. */
function monthBucketUtc(t: number): number {
  const d = new Date(t * 1000);
  return Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) / 1000);
}

/** Fold ascending candles into higher-timeframe OHLCV bars keyed by `bucketOf`. */
export function aggregateCandles(candles: Candle[], bucketOf: (t: number) => number): Candle[] {
  const out: Candle[] = [];
  let cur: Candle | null = null;
  for (const c of candles) {
    const b = bucketOf(c.t);
    if (!cur || cur.t !== b) {
      if (cur) out.push(cur);
      cur = { t: b, o: c.o, h: c.h, l: c.l, c: c.c, v: c.v };
    } else {
      cur.h = Math.max(cur.h, c.h);
      cur.l = Math.min(cur.l, c.l);
      cur.c = c.c;
      cur.v += c.v;
    }
  }
  if (cur) out.push(cur);
  // Truncated M1 windows often start mid-bucket — drop incomplete left bar
  // so OHLC never diverges from full MT5 ChartRequest history.
  if (out.length && candles.length) {
    const first = candles[0]!;
    if (first.t !== bucketOf(first.t)) out.shift();
  }
  return out;
}

/**
 * Twelve Data — forex, stocks, indices, crypto, ETFs. Good free tier, single
 * key covers all asset classes. https://twelvedata.com/docs#time-series
 * Symbol mapping: EURUSD → EUR/USD (forex), BTCUSD → BTC/USD (crypto), AAPL → AAPL.
 */
export class TwelveDataAdapter implements ChartFeedAdapter {
  readonly name = 'twelvedata';
  constructor(private readonly apiKey: string) {}

  private interval(tf: Timeframe): string {
    return { '1m': '1min', '5m': '5min', '15m': '15min', '30m': '30min', '1h': '1h', '4h': '4h', '1d': '1day', '1w': '1week', '1mn': '1month' }[tf];
  }
  private mapSymbol(s: string): string {
    if (/^[A-Z]{6}$/.test(s)) return `${s.slice(0, 3)}/${s.slice(3)}`; // EURUSD → EUR/USD
    if (/USD$/.test(s) && s.length > 6) return `${s.slice(0, -3)}/USD`; // BTCUSD → BTC/USD
    return s; // stocks/indices passthrough
  }

  async fetchCandles(q: CandleQuery): Promise<Candle[]> {
    const url = new URL('https://api.twelvedata.com/time_series');
    url.searchParams.set('symbol', this.mapSymbol(q.symbol));
    url.searchParams.set('interval', this.interval(q.tf));
    url.searchParams.set('outputsize', String(q.limit));
    url.searchParams.set('order', 'ASC');
    url.searchParams.set('apikey', this.apiKey);
    const res = await fetch(url);
    const data: any = await res.json();
    if (!data?.values) throw new Error(data?.message ?? 'twelvedata error');
    return (data.values as any[]).map((v) => ({
      t: Math.floor(new Date(v.datetime).getTime() / 1000),
      o: +v.open, h: +v.high, l: +v.low, c: +v.close, v: +(v.volume ?? 0),
    }));
  }
}

/**
 * Binance — crypto only, free, no key. Excellent candles + depth.
 * https://binance-docs.github.io/apidocs/spot/en/#kline-candlestick-data
 * Symbol mapping: BTCUSD → BTCUSDT.
 */
export class BinanceAdapter implements ChartFeedAdapter {
  readonly name = 'binance';
  private interval(tf: Timeframe): string {
    return { '1m': '1m', '5m': '5m', '15m': '15m', '30m': '30m', '1h': '1h', '4h': '4h', '1d': '1d', '1w': '1w', '1mn': '1M' }[tf];
  }
  private mapSymbol(s: string): string {
    return s.endsWith('USD') ? `${s.slice(0, -3)}USDT` : s;
  }
  async fetchCandles(q: CandleQuery): Promise<Candle[]> {
    const url = new URL('https://api.binance.com/api/v3/klines');
    url.searchParams.set('symbol', this.mapSymbol(q.symbol));
    url.searchParams.set('interval', this.interval(q.tf));
    url.searchParams.set('limit', String(q.limit));
    const res = await fetch(url);
    const rows: any = await res.json();
    if (!Array.isArray(rows)) throw new Error('binance error');
    return rows.map((r) => ({ t: Math.floor(r[0] / 1000), o: +r[1], h: +r[2], l: +r[3], c: +r[4], v: +r[5] }));
  }
}

/**
 * Polygon.io — stocks, forex, crypto, options. Strong institutional data.
 * https://polygon.io/docs/stocks/get_v2_aggs_ticker
 */
export class PolygonAdapter implements ChartFeedAdapter {
  readonly name = 'polygon';
  constructor(private readonly apiKey: string) {}
  private mult(tf: Timeframe): [number, string] {
    return { '1m': [1, 'minute'], '5m': [5, 'minute'], '15m': [15, 'minute'], '30m': [30, 'minute'], '1h': [1, 'hour'], '4h': [4, 'hour'], '1d': [1, 'day'], '1w': [1, 'week'], '1mn': [1, 'month'] }[tf] as [number, string];
  }
  private ticker(s: string): string {
    if (/^[A-Z]{6}$/.test(s)) return `C:${s}`; // forex
    if (/USD$/.test(s) && s.length > 6) return `X:${s}`; // crypto
    return s; // stocks
  }
  async fetchCandles(q: CandleQuery): Promise<Candle[]> {
    const [mult, span] = this.mult(q.tf);
    const to = Date.now();
    const from = to - q.limit * TF_SECONDS[q.tf] * 1000;
    const url = `https://api.polygon.io/v2/aggs/ticker/${this.ticker(q.symbol)}/range/${mult}/${span}/${from}/${to}?adjusted=true&sort=asc&limit=${q.limit}&apiKey=${this.apiKey}`;
    const res = await fetch(url);
    const data: any = await res.json();
    if (!data?.results) throw new Error(data?.message ?? 'polygon error');
    return (data.results as any[]).map((r) => ({ t: Math.floor(r.t / 1000), o: r.o, h: r.h, l: r.l, c: r.c, v: r.v ?? 0 }));
  }
}

/**
 * Native mock generator — deterministic random walk seeded by symbol. Lets the
 * chart render in dev with no provider key (mirrors the mock LP bridge). In
 * production, point CHART_PROVIDER at a real feed or B-Trader's own candle store.
 */
export class NativeMockAdapter implements ChartFeedAdapter {
  readonly name = 'native';
  private seedBase(symbol: string): number {
    const seeds: Record<string, number> = { EURUSD: 1.1, GBPUSD: 1.27, XAUUSD: 2350, BTCUSD: 68000, USDJPY: 157 };
    return seeds[symbol] ?? 100;
  }
  async fetchCandles(q: CandleQuery): Promise<Candle[]> {
    const step = TF_SECONDS[q.tf];
    const now = Math.floor(Date.now() / 1000);
    const start = now - (q.limit - 1) * step;
    let price = this.seedBase(q.symbol);
    let rng = Array.from(q.symbol).reduce((a, c) => a + c.charCodeAt(0), 0);
    const rand = () => {
      rng = (rng * 1103515245 + 12345) & 0x7fffffff;
      return rng / 0x7fffffff;
    };
    const out: Candle[] = [];
    const vol = price * 0.0015;
    for (let i = 0; i < q.limit; i++) {
      const o = price;
      const c = o + (rand() - 0.5) * vol;
      const h = Math.max(o, c) + rand() * vol * 0.5;
      const l = Math.min(o, c) - rand() * vol * 0.5;
      out.push({ t: start + i * step, o, h, l, c, v: Math.round(rand() * 1000) });
      price = c;
    }
    return out;
  }
}
