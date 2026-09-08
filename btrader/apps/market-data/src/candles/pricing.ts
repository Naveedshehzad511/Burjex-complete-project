/**
 * Tenant chart pricing — turning canonical RAW candles into the bars a given
 * tenant actually sees.
 *
 * B-Trader's chart must show the price B-Trader exposes to that tenant, and
 * markup is per (tenant, symbol). Naively that implies one candle series per
 * tenant. It does not, because the chart transform is a **constant offset**:
 *
 *     visibleBid = round(rawBid - markupBid - newsPx, digits)
 *
 * Subtracting a constant and rounding are both monotonic, and monotonic
 * functions commute with min/max. So for a bar whose transform is fixed:
 *
 *     transform(max(prices)) === max(transform(prices))
 *     transform(min(prices)) === min(transform(prices))
 *
 * Aggregating transformed ticks and transforming an aggregated raw candle give
 * **identical** OHLC. That is why the engine can aggregate raw once per symbol
 * and every tenant view can be derived at publish time — no per-tenant
 * aggregation, no duplicated engines, no schema change.
 *
 * The one place the equivalence breaks is a markup change *during* a bar, which
 * is exactly what [TransformEpochs] pins down.
 */

import { CanonicalCandle } from './engine';

/** The per-tenant chart-price transform. Only these inputs affect a bid chart. */
export interface ChartTransform {
  /** Price units subtracted from raw bid (already scaled out of points). */
  markupBid: number;
  digits: number;
}

/**
 * Tenants sharing a transform share a candle stream.
 *
 * Most tenants sit at markupBid 0, so this collapses to very few groups in
 * practice. `newsPx` is deliberately NOT part of the key: it is symbol-global
 * (a news-event spread widening applied to every tenant of that symbol), so it
 * would fragment nothing and including it would churn group keys constantly.
 */
export function chartGroupKey(t: ChartTransform): string {
  return `${t.markupBid}:${t.digits}`;
}

/** Round half-up to `digits`, matching the publish path's `round`. */
export function roundTo(value: number, digits: number): number {
  const f = Math.pow(10, digits);
  return Math.round((value + Number.EPSILON) * f) / f;
}

/** Raw provider bid → the bid this tenant sees. */
export function toVisibleBid(rawBid: number, t: ChartTransform, newsPx = 0): number {
  return roundTo(rawBid - t.markupBid - newsPx, t.digits);
}

/**
 * Apply a transform to a whole candle.
 *
 * Volume is passed through untouched — markup changes price, never the
 * underlying market volume (spec §5).
 */
export function transformCandle(
  candle: CanonicalCandle,
  t: ChartTransform,
  newsPx = 0,
): CanonicalCandle {
  return {
    ...candle,
    o: toVisibleBid(candle.o, t, newsPx),
    h: toVisibleBid(candle.h, t, newsPx),
    l: toVisibleBid(candle.l, t, newsPx),
    c: toVisibleBid(candle.c, t, newsPx),
  };
}

/**
 * Pins the transform in force when each bar opened.
 *
 * Markup is reloaded from the database every 30 s and can therefore change
 * while a bar is forming. Applying the *current* markup to a whole bar would
 * retroactively restate its open and its already-observed high/low — the
 * "silently mutate historical OHLC" the specification forbids.
 *
 * Instead the transform is captured on a bar's first publish and reused for
 * that bar's lifetime. A configuration change opens a new pricing epoch: bars
 * that start after it use the new transform, bars already in flight finish
 * under the old one, and completed bars are never rewritten.
 */
export class TransformEpochs {
  private readonly pinned = new Map<string, ChartTransform>();

  private key(group: string, symbol: string, tf: string, t: number): string {
    return `${group}|${symbol}|${tf}|${t}`;
  }

  /** Transform to use for this bar — the one pinned at its first sighting. */
  forBar(
    group: string,
    candle: CanonicalCandle,
    current: ChartTransform,
  ): ChartTransform {
    const k = this.key(group, candle.symbol, candle.tf, candle.t);
    const existing = this.pinned.get(k);
    if (existing) return existing;
    const snapshot: ChartTransform = { ...current };
    this.pinned.set(k, snapshot);
    return snapshot;
  }

  /** Release a finalized bar's pin. */
  release(group: string, candle: CanonicalCandle): void {
    this.pinned.delete(this.key(group, candle.symbol, candle.tf, candle.t));
  }

  /** Bounded cleanup so a long-running process cannot grow this map forever. */
  prune(maxEntries = 50_000): void {
    if (this.pinned.size <= maxEntries) return;
    const excess = this.pinned.size - maxEntries;
    let removed = 0;
    for (const k of this.pinned.keys()) {
      this.pinned.delete(k);
      if (++removed >= excess) break;
    }
  }

  get size(): number {
    return this.pinned.size;
  }
}

/** Distinct transforms among a symbol's tenants, and who belongs to each. */
export function groupTenants<T extends { tenantId: string } & ChartTransform>(
  configs: readonly T[],
): Map<string, { transform: ChartTransform; tenantIds: string[] }> {
  const out = new Map<string, { transform: ChartTransform; tenantIds: string[] }>();
  for (const c of configs) {
    const key = chartGroupKey(c);
    const entry = out.get(key);
    if (entry) entry.tenantIds.push(c.tenantId);
    else {
      out.set(key, {
        transform: { markupBid: c.markupBid, digits: c.digits },
        tenantIds: [c.tenantId],
      });
    }
  }
  return out;
}
