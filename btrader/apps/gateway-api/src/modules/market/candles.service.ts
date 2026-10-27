import { Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { Candle, CandleQuery, ChartFeedAdapter, Timeframe, TF_SECONDS } from './feed.types';
import { TwelveDataAdapter, BinanceAdapter, PolygonAdapter, NativeMockAdapter, InternalAdapter } from './feed.adapters';
import { QuotesService } from './quotes.service';

/**
 * Resolves and caches the configured chart-data provider and serves candles.
 * Provider is chosen by CHART_PROVIDER env (twelvedata|binance|polygon|native).
 * Keys are read from env so they never reach the client. A short in-memory TTL
 * cache protects provider rate limits.
 */
/**
 * How old a held copy of the LIVE tail may be and still stand in for a failed provider call: long enough to bridge a
 * blip, short enough that an outage is never hidden behind an old answer presented as current.
 */
export const STALE_TAIL_MS = 30_000;

@Injectable()
export class CandlesService {
  private readonly logger = new Logger('CandlesService');
  private readonly adapter: ChartFeedAdapter;
  private readonly cache = new Map<string, { at: number; data: Candle[] }>();

  constructor(private readonly quotes: QuotesService) {
    this.adapter = this.build();
    this.logger.log(`chart feed provider: ${this.adapter.name}`);
  }

  private build(): ChartFeedAdapter {
    // Default is the INTERNAL feed (real candles pushed by the MT5 bridge), not
    // a mock generator. Mock charts are only used when EXPLICITLY set to
    // CHART_PROVIDER=native — never as a default or fallback.
    const provider = (process.env.CHART_PROVIDER ?? 'internal').toLowerCase();
    switch (provider) {
      case 'internal':
      case 'mt5':
        return new InternalAdapter();
      case 'twelvedata':
        return new TwelveDataAdapter(process.env.TWELVEDATA_API_KEY ?? '');
      case 'binance':
        return new BinanceAdapter();
      case 'polygon':
        return new PolygonAdapter(process.env.POLYGON_API_KEY ?? '');
      case 'native':
        this.logger.warn('CHART_PROVIDER=native — serving SIMULATED candles (dev only)');
        return new NativeMockAdapter();
      default:
        return new InternalAdapter();
    }
  }

  async candles(q: CandleQuery, tenantId?: string): Promise<Candle[]> {
    const key = `${this.adapter.name}:${q.symbol}:${q.tf}:${q.limit}:${q.before ?? 'latest'}`;
    // A `before` page is a slice of immutable past history — it never changes
    // once served, so it can sit in cache far longer than the live tail.
    const ttl = q.before != null
      ? 5 * 60_000
      : this.adapter.name === 'native'
        ? 3_000
        : (q.tf === '1m'
            ? 2_000
            : Math.min(TF_SECONDS[q.tf], 15) * 1000);
    const hit = this.cache.get(key);
    if (hit && Date.now() - hit.at < ttl) return hit.data;
    try {
      let targetPrice: number | undefined;
      if (this.adapter.name === 'native') {
        try {
          const tid = tenantId || (await this.quotes.getDefaultTenantId());
          const ticks = await this.quotes.snapshot(tid, q.symbol);
          if (ticks.length > 0 && (ticks[0].bid || ticks[0].ask)) {
            targetPrice = ticks[0].bid || ticks[0].ask;
          }
        } catch {}
      }
      const data = await this.adapter.fetchCandles(q, targetPrice);
      this.cache.set(key, { at: Date.now(), data });
      return data;
    } catch (e) {
      this.logger.warn(`feed error (${this.adapter.name}): ${(e as Error).message}`);
      // A page of past history never changes, so a held copy of it is as right as a fresh one. The newest bars are only
      // as good as they are young: a blip is bridged with the copy we hold, an outage is not hidden behind it.
      const usable = hit && (q.before != null || Date.now() - hit.at < STALE_TAIL_MS);
      if (usable) return hit.data;
      // Never an empty 200 for a failure: the app reads [] as "there is no history here" and would stop asking for it.
      // An error tells it the request failed and should be repeated. (No mock fallback either: fabricated candles
      // are worse than none.)
      throw new ServiceUnavailableException('candle data temporarily unavailable');
    }
  }

  validTimeframe(tf: string): tf is Timeframe {
    return tf in TF_SECONDS;
  }
}
