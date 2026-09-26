import { Injectable, Logger } from '@nestjs/common';
import { Candle, CandleQuery, ChartFeedAdapter, Timeframe, TF_SECONDS } from './feed.types';
import { TwelveDataAdapter, BinanceAdapter, PolygonAdapter, NativeMockAdapter, InternalAdapter } from './feed.adapters';
import { QuotesService } from './quotes.service';

/**
 * Resolves and caches the configured chart-data provider and serves candles.
 * Provider is chosen by CHART_PROVIDER env (twelvedata|binance|polygon|native).
 * Keys are read from env so they never reach the client. A short in-memory TTL
 * cache protects provider rate limits.
 */
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
    const key = `${this.adapter.name}:${q.symbol}:${q.tf}:${q.limit}`;
    const ttl =
      this.adapter.name === 'native'
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
      if (hit) return hit.data; // serve stale on provider failure
      // No mock fallback: if the real feed has no data, return empty so the
      // chart stays blank rather than showing fabricated candles.
      return [];
    }
  }

  validTimeframe(tf: string): tf is Timeframe {
    return tf in TF_SECONDS;
  }
}
