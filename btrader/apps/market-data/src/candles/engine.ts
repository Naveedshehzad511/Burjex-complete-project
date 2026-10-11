/**
 * Canonical candle engine.
 *
 * ONE engine builds every chart bar B-Trader shows, from ONE normalized tick
 * stream, regardless of which provider produced the tick. It contains no
 * provider-specific logic: MT5, FIX, an LP or a custom bridge all normalize to
 * `CanonicalTick` in their adapter, and everything downstream is identical.
 *
 * Why this exists: chart history used to come from MT5 ChartRequest while the
 * forming bar was aggregated client-side from tick bid. Those are two different
 * price definitions, so the live bar could sit at a different level than the
 * bars beside it and only "corrected" when it closed and MT5's bar replaced it.
 *
 * Design rules, all enforced by tests in engine.test.ts:
 *   - M1 is the canonical base resolution. Higher timeframes are folded from M1
 *     state, never aggregated independently from raw ticks.
 *   - Open is written once and never changes. High only rises, low only falls,
 *     close tracks the latest valid price.
 *   - Buckets come from the MARKET timestamp, never arrival or device time.
 *   - Strictly older ticks are rejected; equal timestamps are accepted.
 *   - Applying the same tick twice changes nothing (idempotent), so reconnect
 *     replay cannot corrupt state.
 */

/** Normalized tick. Every provider adapter must produce this shape. */
export interface CanonicalTick {
  symbol: string;
  /** Epoch milliseconds, from the market data — not arrival time. */
  timestamp: number;
  bid: number;
  ask: number;
  last?: number;
  volume?: number;
  /** Provider sequence number when available; preferred over timestamp for ordering. */
  sequence?: number;
  source?: string;
}

/**
 * Which side of the book the chart is drawn from.
 *
 * B-Trader's product specification is BID. This is the single place that
 * decision is expressed — no component may pick its own.
 */
export type ChartPriceMode = 'bid' | 'ask' | 'mid' | 'last';

export const DEFAULT_CHART_PRICE: ChartPriceMode = 'bid';

/** One canonical bar. `t` is the bucket open time in epoch SECONDS. */
export interface CanonicalCandle {
  symbol: string;
  tf: string;
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  /** Summed provider volume. 0 when the provider supplies none — never invented. */
  v: number;
  closed: boolean;
}

export const TF_SECONDS: Readonly<Record<string, number>> = {
  '1m': 60,
  '2m': 120,
  '3m': 180,
  '5m': 300,
  '10m': 600,
  '15m': 900,
  '30m': 1800,
  '1h': 3600,
  '4h': 14400,
  '1d': 86400,
  '1w': 604800,
  '1mn': 2629800, // nominal only; real boundaries are calendar-based below
};

export const BASE_TF = '1m';

/**
 * Extract the chart price from a tick.
 *
 * Returns null when the tick cannot produce a usable price, so callers drop it
 * rather than poisoning a bar with 0 or NaN. `last` is optional in the contract
 * and many FX providers omit it entirely.
 */
export function getCanonicalChartPrice(
  tick: CanonicalTick,
  mode: ChartPriceMode = DEFAULT_CHART_PRICE,
): number | null {
  let p: number | undefined;
  switch (mode) {
    case 'bid':
      p = tick.bid;
      break;
    case 'ask':
      p = tick.ask;
      break;
    case 'mid':
      p =
        Number.isFinite(tick.bid) && Number.isFinite(tick.ask)
          ? (tick.bid + tick.ask) / 2
          : undefined;
      break;
    case 'last':
      p = tick.last;
      break;
  }
  if (p === undefined || !Number.isFinite(p) || p <= 0) return null;
  return p;
}

/**
 * How far a new M1 bar's first tick may sit from the previous close and still count as one continuous
 * price path. The limit is measured in the instrument's OWN movement, not a universal percentage:
 * a pip, a dollar and an index point are different sizes, and a gap that is routine for one
 * instrument is a real gap for another.
 *
 * What is being repaired is only the price movement nobody received ticks for - at most about one
 * minute of the instrument's normal movement. So the limit is a few multiples of the typical
 * minute-to-minute change of the close for THAT symbol (an exponential average, so it follows the
 * instrument's current volatility). A genuine gap (news, a session open, a stalled feed) is many
 * times that, and is kept.
 *
 *   limit = JOIN_SCALE_MULT x average |close(n) - close(n-1)|        once enough minutes are seen
 *   never more than JOIN_BACKSTOP_FRAC of the price (a runaway average cannot widen it)
 *   JOIN_WARMUP_FRAC of the price until JOIN_WARMUP_N consecutive minutes have been observed
 */
export const JOIN_SCALE_MULT = 3;
export const JOIN_BACKSTOP_FRAC = 0.0005;
export const JOIN_WARMUP_FRAC = 0.0002;
export const JOIN_WARMUP_N = 8;
const JOIN_EWMA_ALPHA = 0.1;

/** Typical minute-to-minute move of one symbol's M1 close. */
export class MoveScale {
  private ewma = 0;
  private n = 0;
  private lastClose?: number;
  private lastT?: number;

  /** Feed each FINISHED M1 bar once, oldest first. Only two consecutive minutes make a sample. */
  observe(t: number, close: number): void {
    if (this.lastT !== undefined && this.lastClose !== undefined && t - this.lastT === 60) {
      let sample = Math.abs(close - this.lastClose);
      // One genuine gap must not inflate the average that decides what counts as a gap.
      if (this.n >= JOIN_WARMUP_N && this.ewma > 0) sample = Math.min(sample, JOIN_SCALE_MULT * this.ewma);
      this.ewma = this.n === 0 ? sample : this.ewma + JOIN_EWMA_ALPHA * (sample - this.ewma);
      this.n++;
    }
    this.lastClose = close;
    this.lastT = t;
  }

  /** Largest distance from [prevClose] still treated as the same price path. */
  limit(prevClose: number): number {
    if (this.n < JOIN_WARMUP_N) return prevClose * JOIN_WARMUP_FRAC;
    return Math.min(prevClose * JOIN_BACKSTOP_FRAC, JOIN_SCALE_MULT * this.ewma);
  }
}

/**
 * Where a new M1 bar opens.
 *
 * Bars used to open at their first tick. On a sparse feed the price has already moved by then, so
 * consecutive candles floated apart (a gap that is only the ticks nobody received) while MT5 shows
 * them connected. A new bar now opens at the previous bar's close - the last price actually seen -
 * and its high / low are widened to include that open, so open / high / low / close stay consistent.
 *
 * The join happens only for a consecutive trading minute:
 *   1. the previous bar is exactly the minute before (a tick arrived in both minutes, so there is no
 *      missing minute, weekend or closure between them), and
 *   2. the first tick is within [maxGap] of that close (a larger jump is a real gap; see [MoveScale]).
 * Otherwise the bar opens at its first tick as before. No price is invented: the open is a real
 * earlier close, never an interpolation.
 */
export function joinedOpen(
  prev: { t: number; c: number } | undefined,
  bucket: number,
  stepSec: number,
  firstPrice: number,
  maxGap: number,
): number {
  if (!prev || bucket - prev.t !== stepSec) return firstPrice;
  if (!(prev.c > 0) || Math.abs(firstPrice - prev.c) > maxGap) return firstPrice;
  return prev.c;
}

/**
 * Bucket open time (epoch seconds) for a timestamp.
 *
 * Intraday and daily align to a fixed UTC grid. Weekly aligns to Monday 00:00
 * UTC and monthly to the 1st at 00:00 UTC — calendar months are not a fixed
 * number of seconds, so a plain floor would drift. These semantics match the
 * Flutter client's `bucketStart()` exactly; the two must agree or the client's
 * bars will not line up with the server's.
 */
export function bucketStart(tsSec: number, tf: string, brokerOffsetSec = 0): number {
  if (tf === '1w') {
    const d = new Date(tsSec * 1000);
    const dow = d.getUTCDay(); // 0=Sun
    const daysFromMonday = (dow + 6) % 7;
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - daysFromMonday) / 1000;
  }
  if (tf === '1mn') {
    const d = new Date(tsSec * 1000);
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) / 1000;
  }
  const sec = TF_SECONDS[tf];
  if (!sec) throw new Error(`unknown timeframe: ${tf}`);
  // H4 and D1 follow the BROKER's clock (its session day / 4-hour grid), exactly like the
  // history rollup (gateway `tfBucketStart`) and the MT5 bridge's `aggregate()`. A live bar on
  // the plain UTC grid would sit on different boundaries from the history behind it whenever the
  // broker offset is not a multiple of the timeframe (e.g. +3h and H4), so the two would overlap
  // and the forming bar's high/low would never line up with the bar it becomes.
  if (sec >= 14400 && brokerOffsetSec !== 0) {
    return Math.floor((tsSec + brokerOffsetSec) / sec) * sec - brokerOffsetSec;
  }
  return Math.floor(tsSec / sec) * sec;
}

/** Candle identity — never an array index. */
export function candleKey(symbol: string, tf: string, t: number): string {
  return `${symbol}|${tf}|${t}`;
}

/**
 * How long a price may stay identical before the feed is treated as stale and
 * stops producing bars. Long enough that a genuinely quiet minute on a live
 * market still forms its candle; short enough that a closed session stops
 * manufacturing flat bars almost immediately.
 */
// A price that has not moved for this long is treated as a dead feed, and no
// further bars are created until it moves again — the last genuine candle
// stays on the chart instead of a run of flat ones.
//
// This is the only reliable signal available: an upstream that has lost its
// session keeps republishing its last price with a FRESH timestamp, so the
// usual staleness check on tick age cannot see it. Only the value repeating
// gives it away.
//
// Override with CANDLE_STALE_MS; 0 disables the gate entirely.
const DEFAULT_STALE_MS = Number(process.env.CANDLE_STALE_MS ?? 180_000);

interface SymbolState {
  /** Ordering watermark. */
  lastTs: number;
  lastSeq?: number;
  /** Active bar per timeframe. */
  active: Map<string, CanonicalCandle>;
  /**
   * Volume of M1 bars already folded into each higher-TF bucket. Kept separate
   * from the live M1's volume so repeatedly folding the same still-open M1
   * cannot double-count it.
   */
  foldedVolume: Map<string, number>;
  /** Bucket of the M1 last folded into each higher TF, to detect M1 rollover. */
  foldedM1: Map<string, number>;
  /** Last chart price seen, to tell a real move from a republished quote. */
  lastPrice?: number;
  /** Timestamp (ms) of the last tick that actually CHANGED the price. */
  lastChangeMs: number;
  /** Typical minute-to-minute close move, which sets how large a gap may still be joined. */
  scale: MoveScale;
}

export interface EngineOptions {
  /** Timeframes to maintain. Must include the base '1m'. */
  timeframes?: string[];
  chartPrice?: ChartPriceMode;
  /** Broker UTC offset in seconds (BROKER_UTC_OFFSET_SEC); aligns the H4 / D1 grid. Default 0. */
  brokerOffsetSec?: number;
  /**
   * Milliseconds a price may stay unchanged before the feed is treated as
   * stale and stops producing bars. See [DEFAULT_STALE_MS].
   */
  staleMs?: number;
}

/** A bar that changed as a result of applying a tick. */
export interface CandleUpdate {
  candle: CanonicalCandle;
  /** True on the update that finalized this bar. */
  closed: boolean;
}

export class CandleEngine {
  private readonly tfs: string[];
  private readonly higherTfs: string[];
  private readonly chartPrice: ChartPriceMode;
  private readonly brokerOffsetSec: number;
  private readonly state = new Map<string, SymbolState>();
  private readonly staleMs: number;

  constructor(opts: EngineOptions = {}) {
    const tfs = opts.timeframes ?? ['1m', '5m', '15m', '30m', '1h', '4h', '1d'];
    if (!tfs.includes(BASE_TF)) {
      throw new Error(`timeframes must include the canonical base '${BASE_TF}'`);
    }
    for (const tf of tfs) {
      if (!(tf in TF_SECONDS)) throw new Error(`unknown timeframe: ${tf}`);
    }
    this.tfs = tfs;
    this.higherTfs = tfs.filter((t) => t !== BASE_TF);
    this.chartPrice = opts.chartPrice ?? DEFAULT_CHART_PRICE;
    this.brokerOffsetSec = Number.isFinite(opts.brokerOffsetSec) ? Math.trunc(opts.brokerOffsetSec as number) : 0;
    this.staleMs = opts.staleMs ?? DEFAULT_STALE_MS;
  }

  /** Active (still forming) bar, or undefined. */
  getActive(symbol: string, tf: string): CanonicalCandle | undefined {
    return this.state.get(symbol)?.active.get(tf);
  }

  /**
   * Fold a tick into every maintained timeframe.
   *
   * Returns the bars that changed — including any that just closed — so the
   * caller can publish incremental updates instead of resending history.
   * Returns empty when the tick is rejected (stale, out of order, unusable
   * price), which makes replay safe.
   */
  applyTick(tick: CanonicalTick): CandleUpdate[] {
    const price = getCanonicalChartPrice(tick, this.chartPrice);
    if (price === null) return [];
    if (!Number.isFinite(tick.timestamp) || tick.timestamp <= 0) return [];

    let st = this.state.get(tick.symbol);
    if (!st) {
      st = {
        lastTs: -1,
        active: new Map(),
        foldedVolume: new Map(),
        foldedM1: new Map(),
        lastChangeMs: tick.timestamp,
        scale: new MoveScale(),
      };
      this.state.set(tick.symbol, st);
    }

    // Ordering. Sequence wins when the provider supplies one, because two ticks
    // can share a millisecond. Equal timestamps are accepted: feeds legitimately
    // emit several updates inside one millisecond and dropping them would
    // discard real price movement.
    if (tick.sequence !== undefined && st.lastSeq !== undefined) {
      if (tick.sequence < st.lastSeq) return [];
    } else if (tick.timestamp < st.lastTs) {
      return [];
    }
    st.lastTs = Math.max(st.lastTs, tick.timestamp);
    if (tick.sequence !== undefined) {
      st.lastSeq = st.lastSeq === undefined ? tick.sequence : Math.max(st.lastSeq, tick.sequence);
    }

    // ── Stale feed: no bar without a genuine tick ────────────────────────────
    //
    // When a market closes the bridge keeps republishing the last quote. The
    // engine used to treat each of those as a live tick and open a fresh bucket
    // on every rollover, so a closed weekend produced thousands of identical
    // flat bars and the chart became a single horizontal line at the last
    // price.
    //
    // MT5's rule is simply: no ticks, no bar. Approximated here by price
    // movement, since a republished quote is indistinguishable from a real one
    // except that the price never changes. Once the price has been static for
    // longer than the staleness window the tick is ignored for candle purposes,
    // which leaves the last genuine bar standing until the market reopens.
    //
    // Quotes, spread and execution still use every tick — this only governs
    // whether a BAR is created.
    const moved = st.lastPrice === undefined || price !== st.lastPrice;
    if (moved) st.lastChangeMs = tick.timestamp;
    st.lastPrice = price;
    // TEMPORARILY DISABLED while diagnosing a frozen feed (2026-08-17).
    // Re-enable by setting staleMs > 0; 0 means "never treat as stale".
    if (this.staleMs > 0 && !moved && tick.timestamp - st.lastChangeMs > this.staleMs) return [];

    const tsSec = Math.floor(tick.timestamp / 1000);
    const volume = Number.isFinite(tick.volume) ? (tick.volume as number) : 0;
    const out: CandleUpdate[] = [];

    // ── Base M1 ──────────────────────────────────────────────────────────────
    const m1Bucket = bucketStart(tsSec, BASE_TF, this.brokerOffsetSec);
    const prevM1 = st.active.get(BASE_TF);
    let m1: CanonicalCandle;

    if (!prevM1 || m1Bucket > prevM1.t) {
      if (prevM1) {
        prevM1.closed = true;
        out.push({ candle: { ...prevM1 }, closed: true });
        st.scale.observe(prevM1.t, prevM1.c);
      }
      const open = joinedOpen(prevM1, m1Bucket, TF_SECONDS[BASE_TF]!, price, prevM1 ? st.scale.limit(prevM1.c) : 0);
      m1 = {
        symbol: tick.symbol,
        tf: BASE_TF,
        t: m1Bucket,
        o: open,
        h: Math.max(open, price),
        l: Math.min(open, price),
        c: price,
        v: volume,
        closed: false,
      };
      st.active.set(BASE_TF, m1);
    } else if (m1Bucket === prevM1.t) {
      // Open is never rewritten. High only rises, low only falls.
      if (price > prevM1.h) prevM1.h = price;
      if (price < prevM1.l) prevM1.l = price;
      prevM1.c = price;
      prevM1.v += volume;
      m1 = prevM1;
    } else {
      // Older bucket than the active M1 — the ordering guard normally catches
      // this; belt and braces so a stale tick can never rewrite a closed bar.
      return out;
    }
    out.push({ candle: { ...m1 }, closed: false });

    // ── Higher timeframes, folded from M1 state ──────────────────────────────
    for (const tf of this.higherTfs) {
      const bucket = bucketStart(tsSec, tf, this.brokerOffsetSec);
      const prev = st.active.get(tf);
      const foldKey = tf;

      if (!prev || bucket > prev.t) {
        if (prev) {
          prev.closed = true;
          out.push({ candle: { ...prev }, closed: true });
        }
        const created: CanonicalCandle = {
          symbol: tick.symbol,
          tf,
          t: bucket,
          o: m1.o,
          h: m1.h,
          l: m1.l,
          c: m1.c,
          v: m1.v,
          closed: false,
        };
        st.active.set(tf, created);
        st.foldedVolume.set(foldKey, 0);
        st.foldedM1.set(foldKey, m1.t);
        out.push({ candle: { ...created }, closed: false });
        continue;
      }

      if (bucket < prev.t) continue;

      // Same bucket. M1 high is monotonically rising and low monotonically
      // falling within its own bucket, so max/min folding is safe to repeat —
      // this is what makes the engine idempotent.
      if (m1.h > prev.h) prev.h = m1.h;
      if (m1.l < prev.l) prev.l = m1.l;
      prev.c = m1.c;

      // Volume: everything from previously completed M1s, plus the live M1's
      // running total. Adding m1.v each tick would count it many times over.
      const lastFoldedM1 = st.foldedM1.get(foldKey);
      if (lastFoldedM1 !== undefined && lastFoldedM1 !== m1.t) {
        const carried = st.foldedVolume.get(foldKey) ?? 0;
        st.foldedVolume.set(foldKey, carried + (prev.v - carried));
        st.foldedM1.set(foldKey, m1.t);
      }
      prev.v = (st.foldedVolume.get(foldKey) ?? 0) + m1.v;

      out.push({ candle: { ...prev }, closed: false });
    }

    return out;
  }

  /**
   * Re-adopt a bar that was already forming before a restart.
   *
   * Without this, a service restart mid-bar loses the bar in progress: the next
   * tick finds no active bar and opens a fresh one with open = high = low =
   * close = the current price. The true open of that minute, and any high or
   * low already made, are gone — and because the engine has no memory of ticks
   * it never saw, nothing can reconstruct them afterwards.
   *
   * Feeding the persisted bar back in makes a restart continue the bar instead
   * of starting a new one. This is the engine repairing itself from its own
   * durable output; it needs no upstream provider and works identically
   * whichever feed is attached.
   *
   * Only pass bars for the CURRENT bucket — older ones are history and belong
   * in the store, not in the active set.
   *
   * Restore the base timeframe FIRST. A higher-TF bar's volume already contains
   * the live M1's volume, so the M1 must be known to subtract it; restoring out
   * of order double-counts that overlap.
   */
  restore(candle: CanonicalCandle): void {
    if (!this.tfs.includes(candle.tf)) return;
    let st = this.state.get(candle.symbol);
    if (!st) {
      // lastChangeMs starts at 0 so a restored series is never treated as
      // stale before its first live tick arrives.
      st = { lastTs: -1, active: new Map(), foldedVolume: new Map(), foldedM1: new Map(), lastChangeMs: 0, scale: new MoveScale() };
      this.state.set(candle.symbol, st);
    }
    st.active.set(candle.tf, { ...candle, closed: false });
    if (candle.tf !== BASE_TF) {
      // Split the restored volume into "completed M1s" and "the live M1", so
      // the next tick adds only the live M1's delta on top.
      const m1 = st.active.get(BASE_TF);
      st.foldedVolume.set(candle.tf, Math.max(0, candle.v - (m1?.v ?? 0)));
      st.foldedM1.set(candle.tf, m1?.t ?? -1);
    }
  }

  /** Restore a set of bars, base timeframe first so volumes reconcile. */
  restoreAll(candles: readonly CanonicalCandle[]): void {
    for (const c of candles) if (c.tf === BASE_TF) this.restore(c);
    for (const c of candles) if (c.tf !== BASE_TF) this.restore(c);
  }

  /** Drop all state for a symbol (e.g. unsubscribed). */
  reset(symbol?: string): void {
    if (symbol) this.state.delete(symbol);
    else this.state.clear();
  }
}
