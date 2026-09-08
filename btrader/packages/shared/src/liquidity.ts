import { LpExecDriver } from './enums';

// ============================================================================
//  LIQUIDITY PROVIDERS + multi-source price monitor — shared contracts.
// ============================================================================

/** How a provider's price feed reaches B-Trader. */
export type FeedTransport = 'MT5_PUSH' | 'WS_PULL' | 'FIX_PULL';

/** Client-pricing selection across multiple providers. */
export type PricingMode = 'PRIMARY' | 'BEST_SPREAD';

/** Tenant-level pricing policy for the multi-provider feed. */
export interface TenantPricingDTO {
  pricingMode: PricingMode;
  /** Hysteresis margin (points) a challenger must beat the active source by. */
  bestSpreadMarginPoints: number;
}

export interface LiquidityProviderDTO {
  id: string;
  name: string;
  code: string;
  transport: FeedTransport;
  driver: LpExecDriver;
  enabled: boolean;
  isPrimaryFeed: boolean;
  staleMs: number;
  /** Symbol mapping: default suffix to strip + per-class overrides. */
  symbolSuffix?: string | null;
  suffixByClass?: Record<string, string> | null;
  /** Push auth — only returned masked (presence flag) for safety on lists. */
  hasFeedToken?: boolean;
  feedToken?: string | null;
  feedEndpoint?: string | null;
  senderCompId?: string | null;
  targetCompId?: string | null;
  credentialRef?: string | null;
  status?: string | null;
  createdAt?: string;
  updatedAt?: string;
}

export interface LiquidityProviderInput {
  name: string;
  code: string;
  transport?: FeedTransport;
  driver?: LpExecDriver;
  enabled?: boolean;
  isPrimaryFeed?: boolean;
  staleMs?: number;
  feedToken?: string | null;
  feedEndpoint?: string | null;
  senderCompId?: string | null;
  targetCompId?: string | null;
  credentialRef?: string | null;
  symbolSuffix?: string | null;
  suffixByClass?: Record<string, string> | null;
}

// ── Per-provider symbol mapping (feed name → B-Trader symbol) ───────────────

export interface ProviderSymbolMapDTO {
  id: string;
  lpProviderId: string;
  rawSymbol: string;
  symbolId: string;
  symbolName?: string | null;   // resolved for display
}

export interface ProviderSymbolMapInput {
  lpProviderId: string;
  rawSymbol: string;
  symbolId: string;
}

/** A feed symbol that arrived but matched no B-Trader symbol (mapping helper). */
export interface UnmappedSymbol {
  code: string;       // provider code
  rawSymbol: string;
  lastSeen: number;   // epoch ms
}

/** One provider's latest quote for a symbol (as captured by market-data). */
export interface LpQuote {
  code: string;       // provider code
  bid: number;
  ask: number;
  spread: number;     // ask - bid (price units)
  ts: number;         // epoch ms of the quote
  ageMs: number;      // now - ts at read time
  stale: boolean;     // ageMs > provider.staleMs
}

/** Per-symbol row in the live liquidity monitor: every provider's current quote. */
export interface LiquiditySymbolQuotes {
  symbol: string;
  digits: number;
  quotes: LpQuote[];
  /** provider code with the narrowest FRESH spread, or null if none fresh. */
  bestCode: string | null;
  /** provider code currently DRIVING the client price (hysteresis may hold an
   *  incumbent even when another is momentarily narrower); null if none. */
  activeCode: string | null;
}

export interface LiquidityMonitor {
  asOf: number;
  symbols: LiquiditySymbolQuotes[];
}
