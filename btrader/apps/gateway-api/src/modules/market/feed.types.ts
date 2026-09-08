/** Normalized OHLC candle returned to clients (epoch seconds). */
export interface Candle {
  t: number; // open time, epoch seconds
  o: number;
  h: number;
  l: number;
  c: number;
  v: number;
}

export type Timeframe = '1m' | '5m' | '15m' | '30m' | '1h' | '4h' | '1d' | '1w' | '1mn';

// Nominal bar length in seconds. W1/MN1 use fixed nominal values here (only for
// cache-TTL math); their bar boundaries are calendar-based (see the aggregator).
export const TF_SECONDS: Record<Timeframe, number> = {
  '1m': 60,
  '5m': 300,
  '15m': 900,
  '30m': 1800,
  '1h': 3600,
  '4h': 14400,
  '1d': 86400,
  '1w': 604800,
  '1mn': 2629800,
};

export interface CandleQuery {
  symbol: string; // B-Trader symbol, e.g. EURUSD
  tf: Timeframe;
  limit: number;
}

/**
 * A chart-data provider. New 3rd-party feeds = new adapter implementing this.
 * Adapters run server-side so API keys never reach the client.
 */
export interface ChartFeedAdapter {
  readonly name: string;
  fetchCandles(q: CandleQuery): Promise<Candle[]>;
}
