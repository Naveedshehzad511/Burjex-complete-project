import { Tick } from '@btrader/shared';

/**
 * Hot price cache. In production this is backed by Redis (market-data service
 * writes ticks; engine reads). The in-memory map is the L1 cache updated by the
 * tick subscription. Keyed by `${tenantId}:${symbol}`.
 */
export class PriceSource {
  private readonly ticks = new Map<string, Tick>();

  /** Wall-clock ms when a tick last arrived carrying a DIFFERENT price, per tenant. */
  private readonly changedAt = new Map<string, number>();

  private key(tenantId: string, symbol: string) {
    return `${tenantId}:${symbol}`;
  }

  set(tenantId: string, tick: Tick): void {
    const k = this.key(tenantId, tick.symbol);
    const prev = this.ticks.get(k);
    // Track VALUE changes, not arrivals. An upstream that republishes the same
    // quote with a fresh timestamp keeps `ts` current forever, so tick age alone
    // cannot tell a live market from a frozen one — see [stillMs].
    if (!prev || prev.bid !== tick.bid || prev.ask !== tick.ask) {
      this.changedAt.set(tenantId, Date.now());
    }
    this.ticks.set(k, tick);
  }

  /**
   * Ms since ANY symbol for this tenant last moved, or undefined if nothing has
   * been seen yet.
   *
   * Deliberately tenant-wide rather than per-symbol: a single quiet instrument
   * can legitimately sit unchanged for minutes, so per-symbol stillness would
   * block trading on thin books during normal conditions. An entire price book
   * frozen at once is the signal that the feed has died while still delivering
   * packets.
   */
  stillMs(tenantId: string): number | undefined {
    const at = this.changedAt.get(tenantId);
    return at === undefined ? undefined : Date.now() - at;
  }

  get(tenantId: string, symbol: string): Tick | undefined {
    return this.ticks.get(this.key(tenantId, symbol));
  }

  /** Age (ms) of the latest tick for a symbol, or undefined if none cached. */
  ageMs(tenantId: string, symbol: string): number | undefined {
    const t = this.ticks.get(this.key(tenantId, symbol));
    return t ? Date.now() - t.ts : undefined;
  }

  /** Ask is the buy price; bid is the sell price. */
  buyPrice(tenantId: string, symbol: string): number | undefined {
    return this.ticks.get(this.key(tenantId, symbol))?.ask;
  }

  sellPrice(tenantId: string, symbol: string): number | undefined {
    return this.ticks.get(this.key(tenantId, symbol))?.bid;
  }

  all(tenantId: string): Tick[] {
    const out: Tick[] = [];
    for (const [k, v] of this.ticks) if (k.startsWith(`${tenantId}:`)) out.push(v);
    return out;
  }
}
