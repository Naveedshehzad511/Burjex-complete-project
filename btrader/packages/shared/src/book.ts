import { OrderSide, BookType, HedgeStatus, LpExecDriver, InstrumentClass } from './enums';

// ============================================================================
//  A/B BOOK ROUTING — contracts shared by engine, gateway, and admin client.
// ============================================================================

/** A cover order to send to the liquidity provider for an A-book client fill. */
export interface LpOrderRequest {
  /** Internal position this cover order hedges. */
  positionId: string;
  /** Upstream symbol (post mapping). */
  symbol: string;
  /** LP side mirrors the client side (client BUY -> broker covers BUY). */
  side: OrderSide;
  volume: number; // lots
  /** Client fill price; used as the reference for slippage measurement. */
  referencePrice: number;
  digits: number;
}

/** Result of routing a cover order to the LP. */
export interface LpOrderResult {
  accepted: boolean;
  externalRef?: string; // LP order id
  fillPrice?: number;
  rejectReason?: string;
}

/** Result of closing a cover order at the LP. */
export interface LpCloseResult {
  accepted: boolean;
  closePrice?: number;
  rejectReason?: string;
}

/**
 * Contract every A-book execution bridge implements. Mirrors the LpBridgeAdapter
 * (price feed) pattern: one adapter per provider (Mock, PrimeXM, Centroid,
 * oneZero). New bridge = new adapter, no engine changes.
 */
export interface LpExecutionAdapter {
  readonly driver: LpExecDriver;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;
  /** Route a cover order to the market. */
  placeOrder(req: LpOrderRequest): Promise<LpOrderResult>;
  /** Close a previously routed cover order. */
  closeOrder(externalRef: string, referencePrice: number): Promise<LpCloseResult>;
  onStatus(handler: (status: 'connected' | 'disconnected' | 'error', detail?: string) => void): void;
}

// ── DTOs returned by the admin book/dealing endpoints ───────────────────────

/** Net warehouse (B-book) exposure for one symbol — the broker's own risk. */
export interface SymbolExposure {
  symbol: string;
  digits: number;
  longLots: number;   // total B-book long lots
  shortLots: number;  // total B-book short lots
  netLots: number;    // longLots - shortLots (broker is short this)
  netNotional: number; // signed notional in account currency (approx)
  floatingPL: number; // broker's floating P/L on the warehoused net (sign = house view)
  positions: number;  // count of open B-book positions on this symbol
  aHedgedLots: number; // A-book lots covered to LP on this symbol (informational)
  coveredLots: number; // lots allocated to the LP (A) across positions on this symbol
  warehousedLots: number; // net lots NOT covered (B-book risk: |Σ signed (vol - covered)|)
}

export interface ExposureSummary {
  asOf: number;
  symbols: SymbolExposure[];
  totalNetNotional: number;
  totalFloatingPL: number;
  aBookPositions: number;
  bBookPositions: number;
  hedgePending: number; // cover orders not yet filled
  hedgeRejected: number; // cover orders the LP rejected (broker exposed!)
}

export interface SetAccountBookRequest {
  /** 'A' | 'B' | null (null = inherit group default). */
  book: BookType | null;
}

export interface LpConfigDTO {
  driver: LpExecDriver;
  enabled: boolean;
  /** Tenant fallback venue used when a routing rule sets no provider. */
  isDefault?: boolean;
  /** Human-facing venue name (e.g. "PrimeXM London"). */
  label?: string | null;
  /** Provider this execution venue belongs to (Phase 3 per-provider execution). */
  lpProviderId?: string | null;
  lpProviderCode?: string | null;
  /** MT5 cover-account login for the async bridge path. */
  coverLogin?: string | null;
  endpoint?: string | null;
  senderCompId?: string | null;
  targetCompId?: string | null;
  credentialRef?: string | null;
  simSlippageBps: number;
  simRejectPct: number;
  status?: string | null;
}

// ── Routing Rules (Group × Symbol/Class → book + LP venue) ──────────────────

/**
 * One MT5-style routing rule. Scope fields are optional; null = wildcard. The
 * engine resolves the most-specific matching rule per order (symbol > group >
 * class, ties by `priority`) to pick the execution book + LP venue.
 */
/** How a routing rule selects the A-book LP venue. */
export type VenueMode = 'FIXED' | 'BEST_PRICE';

export interface RoutingRuleDTO {
  id: string;
  tradingGroupId?: string | null;
  tradingGroupName?: string | null;   // resolved for display
  symbolId?: string | null;
  symbolName?: string | null;         // resolved for display
  instrumentClass?: InstrumentClass | null;
  book: BookType;
  venueMode: VenueMode;
  lpProviderId?: string | null;       // FIXED venue: specific provider
  lpProviderCode?: string | null;     // resolved for display
  lpDriver?: LpExecDriver | null;     // legacy driver-level venue
  /** % of an A-book order covered to the LP at open (0–100; 100 = full STP). */
  coverageRatio?: number;
  priority: number;
  enabled: boolean;
  description?: string | null;
  createdAt?: string;
  updatedAt?: string;
}

/** Create/update payload for a routing rule. */
export interface RoutingRuleInput {
  tradingGroupId?: string | null;
  symbolId?: string | null;
  instrumentClass?: InstrumentClass | null;
  book: BookType;
  venueMode?: VenueMode;
  lpProviderId?: string | null;
  lpDriver?: LpExecDriver | null;
  coverageRatio?: number;
  priority?: number;
  enabled?: boolean;
  description?: string | null;
}

/** "Which rule applies" preview: resolve routing for a hypothetical order. */
export interface RoutingTestRequest {
  tradingGroupId?: string | null;
  symbolId?: string | null;
}

export interface RoutingTestResult {
  book: BookType;
  lpDriver: LpExecDriver | null;     // resolved driver (rule provider's driver or default)
  venueMode?: VenueMode;             // how the venue was selected
  lpProviderId?: string | null;      // resolved execution provider
  lpProviderCode?: string | null;    // resolved for display
  coverageRatio?: number;            // % covered to LP (A-book partial)
  matchedRuleId: string | null;      // null = no rule matched (fell back)
  /** Human-readable explanation of how the book + venue were resolved. */
  reason: string;
}

export interface HedgeOrderDTO {
  id: string;
  positionId: string | null;
  accountId: string | null;
  symbol: string;
  side: OrderSide;
  volume: number;
  status: HedgeStatus;
  driver: LpExecDriver;
  lpProviderId?: string | null;
  lpProviderCode?: string | null;    // resolved venue for display
  requestPrice?: number | null;
  fillPrice?: number | null;
  closePrice?: number | null;
  slippage: number;
  externalRef?: string | null;
  rejectReason?: string | null;
  openedAt: string;
  closedAt?: string | null;
}
