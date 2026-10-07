import type { CandleEvent } from '@btrader/shared';

/**
 * Latest server candle event per (tenant, symbol, timeframe).
 *
 * The candle engine publishes a bar only when a tick moves it, so a client that subscribes (first
 * open, reconnect) would otherwise have no server bar for the CURRENT bucket until the next tick,
 * and the chart has to leave that bar out rather than guess it. Remembering the newest event the
 * gateway already receives lets it hand the current bar over at subscribe time.
 *
 * Nothing is computed here: the stored event is the exact one market-data published (already in
 * the tenant's visible price), so the client sees the same bar a live subscriber would have.
 *
 * Bounded: one entry per tenant x symbol x timeframe, and at most [maxSeries] in total; when the
 * cap is hit the oldest-inserted symbol is dropped (it is refilled by its next event).
 */
export class LatestCandleCache {
  private readonly bySymbol = new Map<string, Map<string, CandleEvent>>();
  private count = 0;

  constructor(private readonly maxSeries = 50_000) {}

  private static key(tenantId: string, symbol: string): string {
    // Tenant-scoped, like the gateway's routing indexes: symbol names are only unique per tenant.
    return `${tenantId}\u0000${symbol}`;
  }

  /** Remember [ev]. A bar from an older bucket never replaces a newer one. */
  record(tenantId: string, ev: CandleEvent): void {
    if (!ev || !ev.symbol || !ev.tf || !Number.isFinite(ev.t)) return;
    if (![ev.o, ev.h, ev.l, ev.c].every(Number.isFinite)) return;
    const k = LatestCandleCache.key(tenantId, ev.symbol);
    let series = this.bySymbol.get(k);
    if (series === undefined) {
      series = new Map();
      this.bySymbol.set(k, series);
    }
    const prev = series.get(ev.tf);
    if (prev !== undefined && prev.t > ev.t) return;
    if (prev === undefined) this.count++;
    series.set(ev.tf, ev);
    while (this.count > this.maxSeries && this.bySymbol.size > 1) this.evictOldest(k);
  }

  /** The newest event of every timeframe held for this tenant's symbol. */
  snapshot(tenantId: string, symbol: string): CandleEvent[] {
    const series = this.bySymbol.get(LatestCandleCache.key(tenantId, symbol));
    return series === undefined ? [] : [...series.values()];
  }

  get size(): number {
    return this.count;
  }

  private evictOldest(keep: string): void {
    for (const [k, series] of this.bySymbol) {
      if (k === keep) continue;
      this.count -= series.size;
      this.bySymbol.delete(k);
      return;
    }
  }
}
