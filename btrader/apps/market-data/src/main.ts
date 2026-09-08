// ============================================================================
//  Market Data service.
//  1. Connects to the configured LP bridge adapter (one upstream feed).
//  2. Loads each tenant's ENABLED symbols + group markups (admin-controlled).
//  3. On each raw tick: for every tenant that has the symbol enabled, applies
//     the tenant/group markup, then publishes the normalized tick to
//     Redis channel `bt:{tenantId}:ticks` (engine + WS gateway consume it).
//  Only admin-enabled symbols are ever distributed to clients.
// ============================================================================

import Redis from 'ioredis';
import { prisma, Prisma } from '@btrader/db';
import {
  Channels,
  RawTick,
  Tick,
  LpBridgeAdapter,
  latency,
  CandleEvent,
  CandleEventKind,
  counters,
} from '@btrader/shared';
import { MockAdapter } from './adapters/mock-adapter';
import { GenericWsAdapter } from './adapters/generic-ws-adapter';
import { Mt5IngestAdapter, FeedSource } from './adapters/mt5-ingest-adapter';
import { NullAdapter } from './adapters/null-adapter';
import { CandleEngine, CandleUpdate, DEFAULT_CHART_PRICE, bucketStart } from './candles/engine';
import { TransformEpochs, groupTenants, transformCandle } from './candles/pricing';

const REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6380';

interface TenantSymbolConfig {
  tenantId: string;
  enabled: boolean;
  markupBid: number; // price units to subtract from bid (worsen) — typically points
  markupAsk: number; // price units to add to ask
  digits: number;
}

// upstreamSymbol -> list of tenant configs that distribute it
type Routing = Map<string, TenantSymbolConfig[]>;

// ── Tick → candle aggregation ───────────────────────────────────────────────
// Candles are built from the tick stream (the dealable price), bucketed on the
// server's UTC clock so they line up with the client's forming bar. Keyed by
// `${symbol}|${tf}`. In-memory tips update every tick; DB persist is coalesced
// (closed bars ASAP, forming tips throttled) so ~458 symbols × all TFs cannot
// exhaust the Prisma pool with overlapping multi-thousand upsert transactions.
const TF_SECONDS: Record<string, number> = {
  '1m': 60,
  '5m': 300,
  '15m': 900,
  '30m': 1800,
  '1h': 3600,
  '4h': 14400,
  '1d': 86400,
};
const CANDLE_TFS = Object.keys(TF_SECONDS);
/** How often we scan for work (ms). Actual tip writes are further throttled. */
const CANDLE_FLUSH_SCAN_MS = Number(process.env.CANDLE_FLUSH_SCAN_MS ?? 5_000);
/** Min time between DB writes of the same forming tip (ms). Closed bars bypass this. */
const CANDLE_TIP_MIN_MS = Number(process.env.CANDLE_TIP_MIN_MS ?? 20_000);
/** Rows per INSERT … ON CONFLICT statement. */
const CANDLE_BATCH_SIZE = Number(process.env.CANDLE_BATCH_SIZE ?? 80);
/** Soft cap per flush cycle so a backlog drains across ticks without blocking ingest. */
const CANDLE_MAX_PER_FLUSH = Number(process.env.CANDLE_MAX_PER_FLUSH ?? 400);
/** Yield between consecutive flush cycles so HTTP tick ingest keeps the event loop. */
const CANDLE_FLUSH_YIELD_MS = Number(process.env.CANDLE_FLUSH_YIELD_MS ?? 40);

interface AggCandle {
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  /** Wall-clock ms of last successful DB persist for this tip (0 = never). */
  lastPersistAt: number;
}
interface PersistRow {
  symbol: string;
  tf: string;
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  /**
   * Bridge bar for a bucket inside the canonical era: insert it only if no bar
   * exists, never overwrite one. Lets MT5 history repair holes left by a
   * market-data restart without ever restating a bar the tick engine produced.
   */
  gapFill?: boolean;
}
const agg = new Map<string, AggCandle>();
/** Forming tips that changed since last successful persist. */
const dirty = new Set<string>();
/** Closed bars waiting for durable write (priority over tips). */
const pendingClosed: PersistRow[] = [];
/** Bridge/history bars queued for the same single-flight flusher (never concurrent upsert storms). */
const pendingHistory: PersistRow[] = [];
const HISTORY_QUEUE_CAP = Number(process.env.CANDLE_HISTORY_QUEUE_CAP ?? 80_000);
let candleFlushInFlight = false;
/**
 * Symbols that receive MT5 Manager ChartRequest history via /ingest/candles.
 * For these, ChartRequest is the OHLC source of truth — TickLast can sit on a
 * different price level than chart bars on some brokers, and must not overwrite
 * closed (or forming) MT5 candles.
 */
const mt5ChartSymbols = new Set<string>();
let mt5CandleIngestWired = false;

function enqueueHistory(rows: PersistRow[]): void {
  for (const r of rows) {
    if (pendingHistory.length >= HISTORY_QUEUE_CAP) pendingHistory.shift();
    pendingHistory.push(r);
  }
}

function normalizeEpochSec(t: number): number {
  if (!Number.isFinite(t) || t <= 0) return 0;
  // Auto-detect accidental milliseconds (year ~50000+ if left as ms).
  return t > 10_000_000_000 ? Math.floor(t / 1000) : Math.floor(t);
}

function logMissingMinutes(symbol: string, tf: string, times: number[]): void {
  if (tf !== '1m' || times.length < 2) return;
  const missing: number[] = [];
  for (let i = 1; i < times.length; i++) {
    const gap = times[i]! - times[i - 1]!;
    if (gap === 60) continue;
    for (let m = times[i - 1]! + 60; m < times[i]!; m += 60) missing.push(m);
  }
  if (missing.length === 0) return;
  const sample = missing
    .slice(0, 25)
    .map((t) => new Date(t * 1000).toISOString())
    .join(', ');
  console.warn(
    `[candle-hist] ${symbol} ${tf}: ${missing.length} missing minute(s) in ingested batch` +
      (sample ? ` e.g. ${sample}` : ''),
  );
}

/**
 * Reject a market timestamp this far from server wall clock (ms) and fall back
 * to arrival time. Guards a feed that omits `ts`, sends seconds instead of
 * milliseconds, or has a badly skewed clock — any of which would otherwise
 * scatter bars across the time axis or create bars in the future.
 */
const MAX_TICK_SKEW_MS = Number(process.env.MAX_TICK_SKEW_MS ?? 300_000);

/**
 * Bucket seconds for a tick, from the MARKET timestamp rather than arrival.
 *
 * Arrival time is wrong the moment anything delays a tick — reconnect backlog,
 * a batched bridge flush, network latency, or event-loop pressure. A tick that
 * happened at 10:31:59 but lands at 10:32:01 belongs in the 10:31 bar.
 */
function tickBucketSeconds(tsMs: number): number {
  const nowMs = Date.now();
  if (!Number.isFinite(tsMs) || tsMs <= 0) return Math.floor(nowMs / 1000);
  if (Math.abs(nowMs - tsMs) > MAX_TICK_SKEW_MS) return Math.floor(nowMs / 1000);
  return Math.floor(tsMs / 1000);
}

/**
 * The one canonical candle engine. Provider-agnostic by construction: it only
 * ever sees `CanonicalTick`, so MT5, FIX, an LP or a custom bridge all yield
 * identical bars from identical normalized input.
 */
const candleEngine = new CandleEngine({
  timeframes: CANDLE_TFS,
  chartPrice: DEFAULT_CHART_PRICE, // BID — the B-Trader product specification
});

/**
 * First bucket (epoch seconds) the canonical engine produced for a symbol.
 *
 * This is the historical→live handoff boundary. Bars at or after it belong to
 * the canonical engine; bridge/ChartRequest history may only fill strictly
 * before it. Without this, MT5 backfill and canonical live bars would overwrite
 * each other on every refresh and the chart would flicker between two price
 * definitions — the very bug this architecture removes.
 */
const canonicalSince = new Map<string, number>();

/** Transform in force when each bar opened (see pricing.ts). */
const transformEpochs = new TransformEpochs();

/**
 * Reload the bars that were still forming when this process last stopped.
 *
 * The engine keeps its working set in memory, so a restart would otherwise
 * abandon every bar in progress: the next tick finds nothing active and opens a
 * fresh bar at the current price, discarding that bucket's true open and any
 * high or low already made. Ticks that arrived while the process was down are
 * gone for good, but the bar itself survives in our own store — so the engine
 * repairs itself from its own durable output.
 *
 * Deliberately depends on nothing upstream: no MT5, no bridge, no provider. It
 * behaves identically whichever feed is attached, which is the point.
 */
async function resumeCandleEngine(): Promise<void> {
  const nowSec = Math.floor(Date.now() / 1000);
  // Only the CURRENT bucket per timeframe is still forming; anything older is
  // finished history and belongs in the store, not the active set.
  const wanted = CANDLE_TFS.map((tf) => ({ tf, t: bucketStart(nowSec, tf) }));
  let restored = 0;
  try {
    for (const { tf, t } of wanted) {
      const rows = await prisma.marketCandle.findMany({
        where: { tf, t },
        select: { symbol: true, tf: true, t: true, o: true, h: true, l: true, c: true, v: true },
      });
      if (rows.length === 0) continue;
      candleEngine.restoreAll(
        rows.map((r) => ({
          symbol: r.symbol,
          tf: r.tf,
          t: Number(r.t),
          o: Number(r.o),
          h: Number(r.h),
          l: Number(r.l),
          c: Number(r.c),
          v: Number(r.v ?? 0),
          closed: false,
        })),
      );
      restored += rows.length;
      // Bars we just re-adopted are ours; keep bridge history strictly before them.
      for (const r of rows) {
        const prev = canonicalSince.get(r.symbol);
        const t0 = Number(r.t);
        if (prev === undefined || t0 < prev) canonicalSince.set(r.symbol, t0);
      }
    }
    console.log(`[market-data] resumed ${restored} forming candle(s) after restart`);
  } catch (e) {
    // A cold database or a first-ever boot is not fatal: the engine simply
    // starts fresh, exactly as it did before this existed.
    console.warn('[market-data] candle resume skipped:', (e as Error).message);
  }
}

/** Market timestamp in ms, falling back to arrival only when unusable. */
function validTickMs(tsMs: number): number {
  const nowMs = Date.now();
  if (!Number.isFinite(tsMs) || tsMs <= 0) return nowMs;
  if (Math.abs(nowMs - tsMs) > MAX_TICK_SKEW_MS) return nowMs;
  return tsMs;
}

function aggregateTick(symbol: string, bid: number, tsMs: number): CandleUpdate[] {
  // `ask` is not used for chart price (BID mode) but is part of the canonical
  // contract; passing bid keeps the tick well-formed without inventing a spread.
  const updates = candleEngine.applyTick({
    symbol,
    timestamp: validTickMs(tsMs),
    bid,
    ask: bid,
  });

  for (const u of updates) {
    const c = u.candle;
    const key = `${symbol}|${c.tf}`;
    if (!canonicalSince.has(symbol)) canonicalSince.set(symbol, c.t);

    if (u.closed) {
      pendingClosed.push({ symbol, tf: c.tf, t: c.t, o: c.o, h: c.h, l: c.l, c: c.c });
      continue;
    }

    const prev = agg.get(key);
    agg.set(key, {
      t: c.t,
      o: c.o,
      h: c.h,
      l: c.l,
      c: c.c,
      // Keep the throttle clock across updates to the same bar; reset on a new one.
      lastPersistAt: prev && prev.t === c.t ? prev.lastPersistAt : 0,
    });
    dirty.add(key);
  }

  return updates;
}

/** Bars already seen per tenant group, so `created` vs `updated` is accurate. */
const publishedBars = new Set<string>();

/**
 * Fan canonical bars out to every tenant that trades the symbol, each in its
 * own visible price.
 *
 * Tenants sharing a transform are grouped, so the bar is transformed once per
 * distinct `markupBid:digits` rather than once per tenant. Only the bars that
 * actually changed are sent — never the series.
 */
function publishCandleUpdates(
  pub: Redis,
  routing: Routing,
  updates: CandleUpdate[],
  newsMap: Map<string, number>,
): void {
  if (updates.length === 0) return;
  const symbol = updates[0]!.candle.symbol;
  const targets = routing.get(symbol);
  if (!targets || targets.length === 0) return;

  const groups = groupTenants(targets);
  const newsPts = newsMap.get(symbol) ?? 0;

  for (const [groupKey, { transform, tenantIds }] of groups) {
    const newsPx = newsPts > 0 ? newsPts * Math.pow(10, -transform.digits) : 0;

    for (const u of updates) {
      // Pin the transform to the bar's open so a mid-bar markup change cannot
      // restate a bar already on the client's screen.
      const pinned = transformEpochs.forBar(groupKey, u.candle, transform);
      const view = transformCandle(u.candle, pinned, newsPx);

      const idKey = `${groupKey}|${view.symbol}|${view.tf}|${view.t}`;
      const kind: CandleEventKind = u.closed
        ? 'closed'
        : publishedBars.has(idKey)
          ? 'updated'
          : 'created';
      if (u.closed) {
        publishedBars.delete(idKey);
        transformEpochs.release(groupKey, u.candle);
      } else {
        publishedBars.add(idKey);
      }

      const evt: CandleEvent = {
        kind,
        symbol: view.symbol,
        tf: view.tf,
        t: view.t,
        o: view.o,
        h: view.h,
        l: view.l,
        c: view.c,
        v: view.v,
      };
      const payload = JSON.stringify(evt);
      for (const tenantId of tenantIds) {
        pub.publish(`bt:${tenantId}:${Channels.CANDLES}`, payload);
      }
    }
  }

  // Bounded: a long-running process must not accumulate pins/ids forever.
  transformEpochs.prune();
  if (publishedBars.size > 100_000) publishedBars.clear();
}

/**
 * Write candles.
 *
 * Two conflict policies, and the difference is the whole point:
 *
 * - **overwrite** (default) — the writer owns this bar. Used by the canonical
 *   tick engine, and by bridge history for buckets older than the canonical era.
 *   Never GREATEST/LEAST-merges: tick prices can sit on a different absolute
 *   level than Manager chart bars (observed on XAUUSD.s), and merging the two
 *   permanently corrupts wicks.
 *
 * - **gapFill** — insert only if the bucket is empty. Used for bridge history
 *   inside the canonical era, so an MT5 bar can repair a hole left by a restart
 *   but can never restate a bar the tick engine already produced. Without this
 *   a hole was permanent, because the bars were dropped rather than considered.
 */
async function persistCandleBatch(rows: PersistRow[], gapFill = false): Promise<void> {
  if (rows.length === 0) return;
  const values = rows.map(
    (r) =>
      Prisma.sql`(${r.symbol}, ${r.tf}, ${r.t}, ${r.o}, ${r.h}, ${r.l}, ${r.c}, 0, NOW())`,
  );
  if (gapFill) {
    await prisma.$executeRaw`
      INSERT INTO market_candles (symbol, tf, t, o, h, l, c, v, "updatedAt")
      VALUES ${Prisma.join(values)}
      ON CONFLICT (symbol, tf, t) DO NOTHING
    `;
    return;
  }
  await prisma.$executeRaw`
    INSERT INTO market_candles (symbol, tf, t, o, h, l, c, v, "updatedAt")
    VALUES ${Prisma.join(values)}
    ON CONFLICT (symbol, tf, t) DO UPDATE SET
      o = EXCLUDED.o,
      h = EXCLUDED.h,
      l = EXCLUDED.l,
      c = EXCLUDED.c,
      v = EXCLUDED.v,
      "updatedAt" = NOW()
  `;
}

type LiveBidQuote = { bid: number; ask?: number; ts?: number; staleMs?: number };
type LiveBidBooks = {
  defaultBook: Map<string, LiveBidQuote>;
  allBook: Map<string, Map<string, LiveBidQuote>>;
};

/**
 * Persist bridge-pushed OHLC history from MT5 Manager ChartRequest.
 *
 * ChartRequest OHLC is stored 1:1 — never shifted onto TickLast. Brokers often
 * quote TickLast on a different absolute level than chart bars; rebasing (and
 * especially additive backfills of older rows) destroyed candle geometry vs MT5.
 * Dealable quotes stay on the tick path; charts stay on ChartRequest.
 */
async function persistBridgeCandles(
  symbol: string,
  tf: string,
  bars: Array<{ t: number; o: number; h: number; l: number; c: number; v?: number }>,
  _books: LiveBidBooks,
): Promise<void> {
  const tfSec = TF_SECONDS[tf];
  if (!tfSec || !Array.isArray(bars) || bars.length === 0) return;
  const nowBucket = Math.floor(Date.now() / 1000 / tfSec) * tfSec;
  mt5ChartSymbols.add(symbol);

  const byT = new Map<number, PersistRow>();
  for (const b of bars) {
    const t = normalizeEpochSec(Number(b.t));
    const o = Number(b.o),
      h = Number(b.h),
      l = Number(b.l),
      c = Number(b.c);
    if (![t, o, h, l, c].every(Number.isFinite) || t <= 0) continue;
    // Accept closed bars and the current forming bucket; ignore future buckets.
    if (t > nowBucket) continue;
    if (!(o > 0 && h > 0 && l > 0 && c > 0) || h < l) continue;
    byT.set(t, { symbol, tf, t, o, h, l, c });
  }
  // Historical -> live boundary.
  //
  // Before the canonical era the bridge owns the bars outright. From the first
  // canonical bucket onward the tick engine owns them, so a bridge bar there is
  // marked gapFill: it can only occupy an empty bucket, never restate one the
  // engine produced. That keeps the two price definitions from fighting (the
  // original bug) while still letting MT5 repair holes left by a restart —
  // which the previous version could not do, because it discarded those bars
  // and the hole became permanent.
  const liveFrom = canonicalSince.get(symbol);
  const accepted = [...byT.values()]
    .map((b) => (liveFrom !== undefined && b.t >= liveFrom ? { ...b, gapFill: true } : b))
    .sort((a, b) => a.t - b.t);
  if (accepted.length === 0) return;

  logMissingMinutes(
    symbol,
    tf,
    accepted.map((b) => b.t),
  );

  // Keep in-memory tip aligned to raw ChartRequest so residual tick path cannot drift.
  const tip = accepted[accepted.length - 1]!;
  if (tip.t === nowBucket) {
    const key = `${symbol}|${tf}`;
    agg.set(key, {
      t: tip.t,
      o: tip.o,
      h: tip.h,
      l: tip.l,
      c: tip.c,
      lastPersistAt: 0,
    });
    dirty.add(key);
  }

  enqueueHistory(accepted);
  if (pendingHistory.length <= accepted.length || pendingHistory.length % 2000 < accepted.length) {
    console.log(
      `[candle-hist] queued ${accepted.length} ${symbol} ${tf} bar(s) (histQ=${pendingHistory.length})`,
    );
  }
}

/**
 * Single-flight, chunked candle persist. Never overlaps flushes (the old
 * fire-and-forget $transaction of thousands of upserts exhausted the pool).
 */
async function flushCandlesOnce(): Promise<void> {
  if (candleFlushInFlight) return;
  if (pendingClosed.length === 0 && pendingHistory.length === 0 && dirty.size === 0) return;
  candleFlushInFlight = true;
  const now = Date.now();
  const batch: PersistRow[] = [];
  const closedInBatch: PersistRow[] = [];
  const historyInBatch: PersistRow[] = [];
  const tipSnapshots = new Map<string, PersistRow>();

  try {
    // Priority: MT5 bridge history (source of truth) → tick-closed → forming tips.
    // Deduplicate by symbol|tf|t so a later tick-closed bar cannot clobber MT5.
    const seen = new Set<string>();
    const pushUnique = (row: PersistRow, into: PersistRow[]) => {
      const k = `${row.symbol}|${row.tf}|${row.t}`;
      if (seen.has(k)) return false;
      seen.add(k);
      into.push(row);
      batch.push(row);
      return true;
    };

    while (pendingHistory.length > 0 && batch.length < CANDLE_MAX_PER_FLUSH) {
      const row = pendingHistory.shift()!;
      if (pushUnique(row, historyInBatch) && mt5ChartSymbols.has(row.symbol)) {
        // Drop any queued tick-closed duplicate for the same bar.
      }
    }
    while (pendingClosed.length > 0 && batch.length < CANDLE_MAX_PER_FLUSH) {
      const row = pendingClosed.shift()!;
      // Canonical bars are authoritative for every provider. This used to skip
      // MT5 symbols so ChartRequest owned their OHLC; under the canonical
      // architecture the engine owns live bars and bridge history is confined
      // to buckets before `canonicalSince` (see persistBridgeCandles), so the
      // two can no longer collide and the skip would only drop real bars.
      pushUnique(row, closedInBatch);
    }

    if (batch.length < CANDLE_MAX_PER_FLUSH) {
      for (const key of [...dirty]) {
        if (batch.length >= CANDLE_MAX_PER_FLUSH) break;
        const cd = agg.get(key);
        if (!cd) {
          dirty.delete(key);
          continue;
        }
        if (cd.lastPersistAt > 0 && now - cd.lastPersistAt < CANDLE_TIP_MIN_MS) continue;
        const [symbol, tf] = key.split('|');
        const row: PersistRow = {
          symbol,
          tf,
          t: cd.t,
          o: cd.o,
          h: cd.h,
          l: cd.l,
          c: cd.c,
        };
        if (!pushUnique(row, [])) continue;
        tipSnapshots.set(key, row);
      }
    }

    if (batch.length === 0) return;

    // Split by conflict policy: owned bars overwrite, gap-fill bars must not.
    // Mixing them in one statement would let a bridge bar restate a canonical
    // one, which is exactly the dual-source overwrite this design removes.
    const owned = batch.filter((r) => !r.gapFill);
    const fills = batch.filter((r) => r.gapFill);
    for (let i = 0; i < owned.length; i += CANDLE_BATCH_SIZE) {
      await persistCandleBatch(owned.slice(i, i + CANDLE_BATCH_SIZE));
    }
    for (let i = 0; i < fills.length; i += CANDLE_BATCH_SIZE) {
      await persistCandleBatch(fills.slice(i, i + CANDLE_BATCH_SIZE), true);
    }

    const doneAt = Date.now();
    for (const [key, written] of tipSnapshots) {
      const cd = agg.get(key);
      if (!cd) {
        dirty.delete(key);
        continue;
      }
      cd.lastPersistAt = doneAt;
      // Tip may have moved while we wrote; only clear dirty if still the same OHLC/bucket.
      if (
        written.t === cd.t &&
        written.o === cd.o &&
        written.h === cd.h &&
        written.l === cd.l &&
        written.c === cd.c
      ) {
        dirty.delete(key);
      }
    }
  } catch (e) {
    // Dequeued rows go back (ON CONFLICT makes retries safe). Tips stay in `dirty`.
    for (let i = historyInBatch.length - 1; i >= 0; i--) {
      pendingHistory.unshift(historyInBatch[i]);
    }
    for (let i = closedInBatch.length - 1; i >= 0; i--) {
      pendingClosed.unshift(closedInBatch[i]);
    }
    console.error('[candle-agg]', (e as Error).message);
  } finally {
    candleFlushInFlight = false;
    // Keep draining, but yield so inbound /ingest tick handlers stay responsive.
    if (pendingClosed.length || pendingHistory.length || dirty.size) {
      const delay = pendingClosed.length > 0 ? 0 : Math.max(0, CANDLE_FLUSH_YIELD_MS);
      setTimeout(() => {
        void flushCandlesOnce();
      }, delay);
    }
  }
}

function buildAdapter(resolveSource?: (token: string) => FeedSource | null): LpBridgeAdapter {
  // No fabricated prices: the default (unset/unknown driver) is the Null feed,
  // which distributes NOTHING. Mock is only used when EXPLICITLY requested with
  // LP_BRIDGE_DRIVER=mock (dev only) — never as a fallback.
  const driver = (process.env.LP_BRIDGE_DRIVER ?? '').toLowerCase();
  if (driver === 'generic-ws') {
    return new GenericWsAdapter(
      process.env.LP_BRIDGE_WS_URL ?? '',
      process.env.LP_BRIDGE_API_KEY,
    );
  }
  if (driver === 'mt5-ingest') {
    return new Mt5IngestAdapter({
      port: Number(process.env.MT5_INGEST_PORT ?? 4200),
      token: process.env.MT5_FEED_TOKEN ?? '',
      resolveSource,
      stripSuffix: process.env.MT5_SYMBOL_SUFFIX || undefined,
      maxAgeMs: Number(process.env.MT5_MAX_TICK_AGE_MS ?? 0),
    });
  }
  if (driver === 'mock') {
    // Explicit opt-in only. Never reached unless someone sets it deliberately.
    console.warn('[market-data] LP_BRIDGE_DRIVER=mock — distributing SIMULATED prices (dev only)');
    return new MockAdapter();
  }
  console.warn(`[market-data] no real LP driver (LP_BRIDGE_DRIVER="${driver}") — feed idle, NO prices distributed`);
  return new NullAdapter();
}

async function loadRouting(): Promise<Routing> {
  const symbols = await prisma.symbol.findMany({
    where: { enabled: true, tenant: { status: 'ACTIVE' } },
    include: { group: true },
  });
  const routing: Routing = new Map();
  for (const s of symbols) {
    const cfg: TenantSymbolConfig = {
      tenantId: s.tenantId,
      enabled: s.enabled,
      // group markup + symbol spreadMarkup (points → price units).
      markupBid: Number(s.group?.markupBid ?? 0) * Math.pow(10, -s.digits),
      markupAsk:
        (Number(s.group?.markupAsk ?? 0) + s.spreadMarkup) * Math.pow(10, -s.digits),
      digits: s.digits,
    };
    const arr = routing.get(s.symbol) ?? [];
    arr.push(cfg);
    routing.set(s.symbol, arr);
  }
  return routing;
}

// ── Symbol index (per tenant: canonical name → instrument class) ────────────
// Used to validate suffix-stripped / mapped names against real B-Trader symbols.
async function loadSymbolIndex(): Promise<Map<string, Map<string, string>>> {
  const rows = await prisma.symbol.findMany({
    where: { enabled: true, tenant: { status: 'ACTIVE' } },
    select: { tenantId: true, symbol: true, class: true },
  });
  const idx = new Map<string, Map<string, string>>();
  for (const s of rows) {
    const m = idx.get(s.tenantId) ?? idx.set(s.tenantId, new Map()).get(s.tenantId)!;
    m.set(s.symbol.toUpperCase(), s.class);
  }
  return idx;
}

// ── Liquidity providers (multi-source feed + symbol mapping) ─────────────────
interface ProviderInfo {
  code: string;
  tenantId: string;
  transport: string;
  isPrimaryFeed: boolean;
  staleMs: number;
  enabled: boolean;
  feedEndpoint: string | null;
  credentialRef: string | null;
  // Symbol mapping (feed name → canonical):
  explicitMap: Map<string, string>;   // rawUpper -> canonical symbol name
  suffixes: string[];                  // suffixes to try, longest-first
  classBySuffix: Map<string, string>;  // suffix -> required class (from suffixByClass)
}
interface ProviderSet {
  tokenMap: Map<string, FeedSource>; // feedToken -> source (code + tenant)
  byCode: Map<string, ProviderInfo>;
  primaryCodes: Set<string>;          // providers currently driving client pricing
  wsPull: ProviderInfo[];             // enabled WS_PULL providers to dial out to
}

async function loadProviders(): Promise<ProviderSet> {
  const rows = await prisma.liquidityProvider.findMany({
    where: { enabled: true, tenant: { status: 'ACTIVE' } },
    include: { symbolMaps: { include: { symbol: { select: { symbol: true } } } } },
  });
  const tokenMap = new Map<string, FeedSource>();
  const byCode = new Map<string, ProviderInfo>();
  const primaryCodes = new Set<string>();
  const wsPull: ProviderInfo[] = [];
  for (const r of rows) {
    const byClass: Record<string, string> =
      r.suffixByClass && typeof r.suffixByClass === 'object' ? (r.suffixByClass as Record<string, string>) : {};
    // Class-restrict a suffix only when it's class-specific (not the default).
    const classBySuffix = new Map<string, string>();
    for (const [cls, sfx] of Object.entries(byClass)) {
      if (sfx && sfx !== r.symbolSuffix) classBySuffix.set(sfx.toUpperCase(), cls);
    }
    const suffixSet = new Set<string>();
    if (r.symbolSuffix) suffixSet.add(r.symbolSuffix.toUpperCase());
    for (const sfx of Object.values(byClass)) if (sfx) suffixSet.add(sfx.toUpperCase());
    const suffixes = [...suffixSet].sort((a, b) => b.length - a.length);
    const explicitMap = new Map<string, string>();
    for (const m of r.symbolMaps) explicitMap.set(m.rawSymbol.toUpperCase(), m.symbol.symbol.toUpperCase());

    const info: ProviderInfo = {
      code: r.code,
      tenantId: r.tenantId,
      transport: r.transport,
      isPrimaryFeed: r.isPrimaryFeed,
      staleMs: r.staleMs,
      enabled: r.enabled,
      feedEndpoint: r.feedEndpoint,
      credentialRef: r.credentialRef,
      explicitMap,
      suffixes,
      classBySuffix,
    };
    byCode.set(r.code, info);
    if (r.isPrimaryFeed) primaryCodes.add(r.code);
    if (r.transport === 'MT5_PUSH' && r.feedToken) {
      tokenMap.set(r.feedToken, { code: r.code, tenantId: r.tenantId });
    }
    if (r.transport === 'WS_PULL' && r.feedEndpoint) wsPull.push(info);
  }
  return { tokenMap, byCode, primaryCodes, wsPull };
}

/**
 * Resolve a provider's raw feed symbol to a B-Trader canonical symbol name:
 * explicit map → per-class suffix strip → default suffix → exact match. Returns
 * null when nothing matches a real symbol (caller records it as unmapped).
 */
function resolveCanonical(p: ProviderInfo, raw: string, idx: Map<string, string> | undefined): string | null {
  if (!idx) return null;
  const R = raw.trim().toUpperCase();
  const ex = p.explicitMap.get(R);
  if (ex) return idx.has(ex) ? ex : null;
  for (const sfx of p.suffixes) {
    if (R.length > sfx.length && R.endsWith(sfx)) {
      const cand = R.slice(0, R.length - sfx.length);
      const cls = idx.get(cand);
      if (cls != null) {
        const req = p.classBySuffix.get(sfx);
        if (!req || req === cls) return cand;
      }
    }
  }
  return idx.has(R) ? R : null;
}

/** Persist a provider's latest per-symbol quote for the live spread monitor. */
function captureQuote(pub: Redis, tenantId: string, code: string, symbol: string, raw: RawTick): void {
  const key = `bt:liq:${tenantId}`;
  pub.hset(key, `${code}|${symbol}`, JSON.stringify({ bid: raw.bid, ask: raw.ask, ts: raw.ts }));
  pub.expire(key, 86_400); // self-clean if the feed stops
}

// Throttled record of feed symbols that matched no B-Trader symbol, so the admin
// can map them. Written at most once per (code, raw) every 30s.
const unmappedSeen = new Map<string, number>();
function recordUnmapped(pub: Redis, tenantId: string, code: string, raw: string): void {
  const k = `${tenantId}|${code}|${raw}`;
  const now = Date.now();
  if (now - (unmappedSeen.get(k) ?? 0) < 30_000) return;
  unmappedSeen.set(k, now);
  const key = `bt:unmapped:${tenantId}`;
  pub.hset(key, `${code}|${raw}`, String(now));
  pub.expire(key, 86_400);
}

// ── Tenant pricing policy (PRIMARY vs BEST_SPREAD) ──────────────────────────
interface TenantPricing {
  mode: string;          // 'PRIMARY' | 'BEST_SPREAD'
  marginPoints: number;  // hysteresis margin a challenger must beat the active source by
}
async function loadTenantPricing(): Promise<Map<string, TenantPricing>> {
  const rows = await prisma.tenant.findMany({
    where: { status: 'ACTIVE' },
    select: { id: true, pricingMode: true, bestSpreadMarginPoints: true },
  });
  const m = new Map<string, TenantPricing>();
  for (const r of rows) m.set(r.id, { mode: r.pricingMode, marginPoints: r.bestSpreadMarginPoints });
  return m;
}

// ── News mode: extra spread points per symbol while active (polled fast) ─────
async function loadNews(): Promise<Map<string, number>> {
  const rows = await prisma.symbol.findMany({
    where: { newsMode: true, enabled: true },
    select: { symbol: true, newsSpreadPoints: true },
  });
  const m = new Map<string, number>();
  for (const r of rows) m.set(r.symbol, Math.max(m.get(r.symbol) ?? 0, r.newsSpreadPoints));
  return m;
}

// ── In-memory quote books (hot path; per source, never persisted) ───────────
interface BookQuote {
  bid: number;
  ask: number;
  ts: number;
  staleMs: number;
}
const DEFAULT_SOURCE_STALE_MS = 10_000;

// Some LP feeds genuinely quote certain crosses with ask == bid (e.g. thinly
// traded synthetic/calculated pairs with no direct two-sided depth on that
// account) — real data, not corruption. Rejecting on strict ask > bid used to
// silently blank those symbols forever, even when perfectly fresh. Allow
// ask == bid here; the group markup applied downstream (publishForTenant)
// always widens the CLIENT-facing price to a positive spread, so this stays
// safe. Still reject a genuinely inverted book (ask < bid).
const fresh = (q: BookQuote, now: number): boolean =>
  now - q.ts <= q.staleMs && q.ask >= q.bid && q.bid > 0;

async function main() {
  const pub = new Redis(REDIS_URL, {
    // Never let a transient Redis blip take down the ingest HTTP server.
    maxRetriesPerRequest: 2,
    enableOfflineQueue: true,
  });
  pub.on('error', (err) => {
    console.error('[market-data] redis:', (err as Error).message);
  });
  await resumeCandleEngine();
  let routing = await loadRouting();
  let providers = await loadProviders();
  let pricing = await loadTenantPricing();
  let symbolIndex = await loadSymbolIndex();
  let newsMap = await loadNews();
  // Resolver reads the LATEST providers (reassigned on refresh) so new feed
  // tokens take effect without a restart.
  const adapter = buildAdapter((token) => providers.tokenMap.get(token) ?? null);

  adapter.onStatus((status, detail) => {
    // eslint-disable-next-line no-console
    console.log(`[market-data] LP ${adapter.name}: ${status}${detail ? ' ' + detail : ''}`);
  });

  // Latest quote per (tenant, symbol, provider code), the legacy default feed,
  // and a global view (for the single canonical candle stream).
  const tenantBook = new Map<string, Map<string, Map<string, BookQuote>>>();
  const defaultBook = new Map<string, BookQuote>();
  const allBook = new Map<string, Map<string, BookQuote>>(); // symbol -> sourceKey -> quote
  const selected = new Map<string, Map<string, string>>();    // tenant -> symbol -> active code (hysteresis)

  const tStaleMs = (code: string): number => providers.byCode.get(code)?.staleMs ?? 2000;
  const getSel = (tid: string) => selected.get(tid) ?? selected.set(tid, new Map()).get(tid)!;

  /** Choose the source quote for a tenant+symbol and publish the client tick. */
  const publishForTenant = (tenantId: string, symbol: string, now: number): void => {
    const target = routing.get(symbol)?.find((t) => t.tenantId === tenantId);
    if (!target) return;
    const mode = pricing.get(tenantId)?.mode ?? 'PRIMARY';

    let chosen: { code: string; q: BookQuote } | null = null;
    if (mode === 'BEST_SPREAD') {
      chosen = pickBestSpread(tenantId, symbol, now, target.digits);
      // Resilience: if no provider quote is fresh, fall back to the legacy feed
      // rather than blanking the client price.
      if (!chosen) {
        const dq = defaultBook.get(symbol);
        if (dq && fresh(dq, now)) chosen = { code: 'default', q: dq };
      }
    } else {
      // PRIMARY: the tenant's primary provider if it has one, else the default feed.
      const primaryCode = [...providers.byCode.values()].find((p) => p.tenantId === tenantId && p.isPrimaryFeed)?.code;
      const pq = primaryCode ? tenantBook.get(tenantId)?.get(symbol)?.get(primaryCode) : undefined;
      if (pq && fresh(pq, now)) chosen = { code: primaryCode!, q: pq };
      else {
        const dq = defaultBook.get(symbol);
        if (dq && fresh(dq, now)) chosen = { code: 'default', q: dq };
      }
    }
    if (!chosen) return;

    getSel(tenantId).set(symbol, chosen.code);
    pub.hset(`bt:bestsrc:${tenantId}`, symbol, chosen.code);
    // News mode: widen the shown spread symmetrically (still a real price).
    const newsPts = newsMap.get(symbol) ?? 0;
    const newsPx = newsPts > 0 ? newsPts * Math.pow(10, -target.digits) : 0;
    const tick: Tick = {
      symbol,
      bid: round(chosen.q.bid - target.markupBid - newsPx, target.digits),
      ask: round(chosen.q.ask + target.markupAsk + newsPx, target.digits),
      ts: chosen.q.ts,
    };
    const payload = JSON.stringify(tick);
    const stopRedis = latency.start('tick.redis');
    pub.publish(`bt:${tenantId}:${Channels.TICKS}`, payload);
    // Durably remember the last real tick per symbol so the client watchlist can
    // seed from it and never show blank — a stale-but-real price, MT5-style.
    pub.hset(`bt:${tenantId}:lastticks`, symbol, payload);
    stopRedis();
  };

  /** Narrowest fresh+sane spread among a tenant's providers, with hysteresis. */
  const pickBestSpread = (
    tenantId: string,
    symbol: string,
    now: number,
    digits: number,
  ): { code: string; q: BookQuote } | null => {
    const book = tenantBook.get(tenantId)?.get(symbol);
    if (!book) return null;
    let bestCode: string | null = null;
    let best: BookQuote | null = null;
    let bestSpread = Infinity;
    for (const [code, q] of book) {
      if (!fresh(q, now)) continue;
      const sp = q.ask - q.bid;
      if (sp < bestSpread) {
        bestSpread = sp;
        bestCode = code;
        best = q;
      }
    }
    if (!bestCode || !best) return null;

    // Hysteresis: keep the active source unless it went stale or the challenger
    // beats it by more than the configured margin (in price units).
    const marginPx = (pricing.get(tenantId)?.marginPoints ?? 0) * Math.pow(10, -digits);
    const inc = getSel(tenantId).get(symbol);
    if (inc && inc !== bestCode) {
      const incQ = book.get(inc);
      if (incQ && fresh(incQ, now)) {
        const incSpread = incQ.ask - incQ.bid;
        if (bestSpread + marginPx >= incSpread) return { code: inc, q: incQ };
      }
    }
    return { code: bestCode, q: best };
  };

  /** Single canonical candle stream: tightest fresh quote across ALL sources. */
  const aggregateCanonical = (symbol: string, now: number): void => {
    const book = allBook.get(symbol);
    if (!book) return;
    let bid: number | null = null;
    // Carry the chosen quote's own market timestamp through to bucketing.
    let bidTs = 0;
    let bestSpread = Infinity;
    for (const q of book.values()) {
      if (!fresh(q, now)) continue;
      const sp = q.ask - q.bid;
      if (sp < bestSpread) {
        bestSpread = sp;
        bid = q.bid;
        bidTs = q.ts;
      }
    }
    if (bid == null) return;
    // Canonical bars, then one transformed copy per distinct tenant transform.
    publishCandleUpdates(pub, routing, aggregateTick(symbol, bid, bidTs), newsMap);
  };

  // Shared tick handler for the ingest server AND every WS pull connector.
  // Diagnostic counters: how many incoming ticks are discarded for being too old.
  //
  // `fresh()` silently drops a tick whose own timestamp is older than its
  // source's staleMs. That is correct - never price on a stale quote - but it
  // is invisible. When an upstream terminal loses its session it keeps serving
  // its last quote WITH THE ORIGINAL TIMESTAMP, so ingest counters climb,
  // nothing reaches Redis, and no error appears anywhere. This makes that
  // failure announce itself instead of looking like a dead application.
  // Drop-reason counters. A tick can be discarded at several gates, all silent
  // by design. When the product goes dead with healthy containers and climbing
  // counters, these say which gate is eating them.
  const dropNames = new Map<string, number>();
  let dropNoRouteN = 0;
  let dropUnmappedN = 0;
  let dropLoggedAt = 0;
  const noteDrop = (k: string) => dropNames.set(k, (dropNames.get(k) ?? 0) + 1);
  const dropNoRoute = (sym: string) => { dropNoRouteN++; noteDrop(sym); };
  const dropUnmapped = (sym: string) => { dropUnmappedN++; noteDrop(sym); };
  const reportDrops = (now: number) => {
    if (now - dropLoggedAt < 30_000) return;
    if (dropNoRouteN === 0 && dropUnmappedN === 0) return;
    dropLoggedAt = now;
    const top = [...dropNames.entries()].sort((x, y) => y[1] - x[1]).slice(0, 8)
      .map(([k, v]) => `${k}=${v}`).join(' ');
    console.warn(
      `[feed-drop] last 30s: no-route=${dropNoRouteN} unmapped=${dropUnmappedN}. Top raw symbols: ${top}`,
    );
    dropNoRouteN = 0; dropUnmappedN = 0; dropNames.clear();
  };

  let staleSeen = 0;
  let staleMaxAgeMs = 0;
  let staleLoggedAt = 0;

  const lastSeq = new Map<string, number>();
  const handleTickImpl = (raw: RawTick) => {
    const now = Date.now();
    if (raw.sequence != null) {
      const prev = lastSeq.get(raw.symbol);
      if (prev != null && raw.sequence > prev + 1) {
        counters.inc('feed.seq_gap');
        console.warn(`[feed-gap] ${raw.symbol} sequence ${prev} → ${raw.sequence} (missed ${raw.sequence - prev - 1})`);
      }
      lastSeq.set(raw.symbol, raw.sequence);
    }
    const isProvider = !!raw.tenantId && !!raw.source && raw.source !== 'default';
    const staleMs = isProvider ? tStaleMs(raw.source) : DEFAULT_SOURCE_STALE_MS;
    {
      const age = now - raw.ts;
      if (age > staleMs) {
        staleSeen++;
        if (age > staleMaxAgeMs) staleMaxAgeMs = age;
      }
      reportDrops(now);
      if (staleSeen > 0 && now - staleLoggedAt > 30_000) {
        staleLoggedAt = now;
        console.warn(
          `[feed-stale] ${staleSeen} tick(s) dropped as too old in the last 30s; ` +
            `oldest ${(staleMaxAgeMs / 1000).toFixed(1)}s behind (limit ${staleMs / 1000}s). ` +
            `Upstream is republishing quotes without advancing their timestamp.`,
        );
        staleSeen = 0;
        staleMaxAgeMs = 0;
      }
    }
    const q: BookQuote = { bid: raw.bid, ask: raw.ask, ts: raw.ts, staleMs };

    if (isProvider) {
      const tenantId = raw.tenantId!;
      // Map this LP's feed name → B-Trader canonical symbol before anything else.
      const prov = providers.byCode.get(raw.source);
      const symbol = prov ? resolveCanonical(prov, raw.symbol, symbolIndex.get(tenantId)) : null;
      if (!symbol) {
        recordUnmapped(pub, tenantId, raw.source, raw.symbol.trim().toUpperCase());
        dropUnmapped(raw.symbol);
        return;
      }
      // Global book + canonical candle stream (one source of truth).
      (allBook.get(symbol) ?? allBook.set(symbol, new Map()).get(symbol)!).set(`${tenantId}:${raw.source}`, q);
      aggregateCanonical(symbol, now);
      // Monitor capture + tenant book (keyed by canonical name).
      captureQuote(pub, tenantId, raw.source, symbol, raw);
      const tb = tenantBook.get(tenantId) ?? tenantBook.set(tenantId, new Map()).get(tenantId)!;
      (tb.get(symbol) ?? tb.set(symbol, new Map()).get(symbol)!).set(raw.source, q);

      // PRIMARY tenants only republish when the PRIMARY source ticks — a
      // monitoring-only provider never moves their live price.
      const mode = pricing.get(tenantId)?.mode ?? 'PRIMARY';
      if (mode !== 'BEST_SPREAD' && prov?.isPrimaryFeed !== true) return;
      publishForTenant(tenantId, symbol, now);
      return;
    }

    // Legacy default feed (tenant-agnostic): the adapter already stripped the
    // global suffix, so raw.symbol is canonical. Drives every tenant that isn't
    // pricing off its own providers.
    (allBook.get(raw.symbol) ?? allBook.set(raw.symbol, new Map()).get(raw.symbol)!).set('default', q);
    aggregateCanonical(raw.symbol, now);
    defaultBook.set(raw.symbol, q);
    const targets = routing.get(raw.symbol);
    if (!targets) {
      dropNoRoute(raw.symbol);
      return;
    }
    for (const t of targets) publishForTenant(t.tenantId, raw.symbol, now);
  };
  // Timing wrapper so per-tick processing latency is captured across all the
  // early-return paths above.
  const handleTick = (raw: RawTick) => {
    const stop = latency.start('tick.handle');
    try {
      handleTickImpl(raw);
    } finally {
      stop();
    }
  };
  adapter.onTick(handleTick);

  // ── Outbound WS pull connectors (one per WS_PULL provider) ─────────────────
  const pullers = new Map<string, GenericWsAdapter>();
  async function syncPullers(): Promise<void> {
    const want = new Map(providers.wsPull.map((p) => [p.code, p]));
    for (const [code, a] of pullers) {
      if (!want.has(code)) {
        await a.disconnect().catch(() => undefined);
        pullers.delete(code);
      }
    }
    for (const [code, p] of want) {
      if (pullers.has(code)) continue;
      const apiKey = p.credentialRef ? process.env[`LP_SECRET_${p.credentialRef}`] : undefined;
      const a = new GenericWsAdapter(p.feedEndpoint!, apiKey);
      a.onStatus((s, d) => console.log(`[market-data] WS ${code}: ${s}${d ? ' ' + d : ''}`));
      a.onTick((raw) => handleTick({ ...raw, source: code, tenantId: p.tenantId }));
      await a.connect().catch((e) => console.error(`[market-data] WS ${code} connect failed`, (e as Error).message));
      await a.subscribe([...routing.keys()]).catch(() => undefined);
      pullers.set(code, a);
    }
  }

  function logFixPending(): void {
    const fix = [...providers.byCode.values()].filter((p) => p.transport === 'FIX_PULL');
    if (fix.length) {
      console.warn(
        `[market-data] ${fix.length} FIX_PULL provider(s) configured (${fix.map((f) => f.code).join(', ')}) — ` +
          'FIX market-data connector not yet implemented; no quotes ingested for them.',
      );
    }
  }

  // MT5 ChartRequest history → durable store (closed + forming). TickLast must
  // not overwrite these OHLC bars — brokers can quote ticks on a different level
  // than chart rates (observed on BTCUSD: TickLast≈627xx vs Chart≈625xx).
  if (adapter instanceof Mt5IngestAdapter) {
    mt5CandleIngestWired = true;
    adapter.onCandles((symbol, tf, bars) => {
      void persistBridgeCandles(symbol, tf, bars, { defaultBook, allBook });
    });
    console.log('[market-data] MT5 candle history ingest wired (ChartRequest authoritative)');
  }

  // Coalesced durable flush: one flight at a time, chunked INSERT ON CONFLICT.
  // Closed bars flush ASAP; forming tips at most every CANDLE_TIP_MIN_MS.
  setInterval(() => {
    void flushCandlesOnce();
  }, CANDLE_FLUSH_SCAN_MS);

  await adapter.connect();
  await adapter.subscribe([...routing.keys()]);
  await syncPullers();
  logFixPending();

  // Periodic latency profile of the tick path (per-tick processing + Redis
  // writes) so we can see throughput/hotspots in the logs without a metrics UI.
  setInterval(() => {
    const snap = latency.snapshot();
    if (Object.keys(snap).length) console.log('[latency]', JSON.stringify(snap));
  }, 15000);

  // Periodically refresh routing + providers (admin adds LPs / changes feeds /
  // marks the primary), reconnect pull connectors, and re-subscribe symbols.
  setInterval(async () => {
    routing = await loadRouting();
    providers = await loadProviders();
    pricing = await loadTenantPricing();
    symbolIndex = await loadSymbolIndex();
    await adapter.subscribe([...routing.keys()]);
    await syncPullers();
  }, 30_000);

  // News mode toggles must take effect fast (dealer flips it around news) — poll
  // just the news config every few seconds so the widened spread propagates.
  setInterval(async () => {
    newsMap = await loadNews().catch(() => newsMap);
  }, 3_000);

  // eslint-disable-next-line no-console
  console.log(
    `[market-data] running with ${routing.size} distinct symbols, ` +
      `${providers.byCode.size} liquidity provider(s)`,
  );
}

function round(v: number, digits: number): number {
  const f = Math.pow(10, digits);
  return Math.round(v * f) / f;
}

main().catch((e) => {
  // eslint-disable-next-line no-console
  console.error('[market-data] fatal', e);
  process.exit(1);
});
