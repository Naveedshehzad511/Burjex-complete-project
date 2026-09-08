// ============================================================================
//  Pure trading math — no I/O, fully unit-testable. This is the core of the
//  "MT5-like" account model: margin, P/L, equity, margin level, stop-out.
// ============================================================================

import { OrderSide } from '@btrader/shared';

export interface SymbolCalcSpec {
  digits: number;
  pipSize: number; // e.g. 0.0001
  contractSize: number; // units per 1.0 lot, e.g. 100000
  marginRate: number; // multiplier (1 = full notional / leverage)
  // #14: crypto/metals margin fraction of notional, independent of account
  // leverage. When set (> 0), margin = notional * marginPercent. null = FX
  // leverage-based margin.
  marginPercent?: number | null;
  quoteCurrency: string;
  baseCurrency: string;
}

/** Smallest price increment (a "point") = 10^-digits. */
export function pointSize(digits: number): number {
  return Math.pow(10, -digits);
}

/**
 * Notional value of a position in the QUOTE currency.
 *   notional = volume(lots) * contractSize * price
 */
export function notionalQuote(volumeLots: number, spec: SymbolCalcSpec, price: number): number {
  return volumeLots * spec.contractSize * price;
}

/**
 * Required margin in the ACCOUNT currency.
 *   margin = (volume * contractSize * openPrice * marginRate) / leverage * fx(quote→acct)
 * `quoteToAcct` converts one unit of quote currency into the account currency
 * (1 when quote === account currency).
 */
export function requiredMargin(
  volumeLots: number,
  spec: SymbolCalcSpec,
  price: number,
  leverage: number,
  quoteToAcct = 1,
): number {
  const rawNotional = notionalQuote(volumeLots, spec, price);
  // #14: crypto & metals hold a fixed fraction of notional as margin, independent
  // of the account's currency leverage (and of marginRate). e.g. marginPercent
  // 0.10 → 10% → 10x effective, whatever the account leverage is.
  if (spec.marginPercent != null && spec.marginPercent > 0) {
    return rawNotional * spec.marginPercent * quoteToAcct;
  }
  if (leverage <= 0) leverage = 1;
  const notional = rawNotional * spec.marginRate;
  return (notional / leverage) * quoteToAcct;
}

/**
 * Floating / realized profit in the ACCOUNT currency for a position.
 *   BUY:  (close - open) * volume * contractSize
 *   SELL: (open - close) * volume * contractSize
 * Then convert quote→account.
 */
export function positionProfit(
  side: OrderSide,
  volumeLots: number,
  openPrice: number,
  currentPrice: number,
  spec: SymbolCalcSpec,
  quoteToAcct = 1,
): number {
  const direction = side === 'BUY' ? 1 : -1;
  const priceDiff = (currentPrice - openPrice) * direction;
  const profitQuote = priceDiff * volumeLots * spec.contractSize;
  return profitQuote * quoteToAcct;
}

/** Value of one pip for a given volume, in account currency. */
export function pipValue(volumeLots: number, spec: SymbolCalcSpec, quoteToAcct = 1): number {
  return spec.pipSize * volumeLots * spec.contractSize * quoteToAcct;
}

// ── Trading-group pricing: spread markup + dealing commission ───────────────

export type GroupCommissionType = 'NONE' | 'PER_LOT' | 'PER_SIDE' | 'ROUND_TURN' | 'PERCENT';
export type SymbolPricingMethod = 'SPREAD_ONLY' | 'COMMISSION_ONLY' | 'SPREAD_AND_COMMISSION';

export interface GroupPricing {
  markupPoints: number; // extra points applied to the traded side (broker edge)
  slippagePoints: number; // execution slippage penalty (points) worsening every fill
  commissionType: GroupCommissionType;
  commissionValue: number;
  /** Spread Markup floor (points) from a Symbol Mapping (0 = unused). */
  minSpreadPoints?: number;
  /** Spread Markup ceiling (points); 0 = fixed at min (no LP-driven growth). */
  maxSpreadPoints?: number;
  pricingMethod?: SymbolPricingMethod;
  /** #2B: group execution model — 'MARKET' (fill at market) or 'INSTANT' (honour clicked price / requote). Undefined ⇒ MARKET. */
  executionMode?: 'MARKET' | 'INSTANT';
  /** #2B: max points the market may move from the client's quote before an INSTANT order requotes; 0 ⇒ fall back to the symbol's slippagePoints. */
  instantDeviationPoints?: number;
}

export interface SymbolMappingPricing {
  pricingMethod: SymbolPricingMethod;
  minSpreadPoints: number;
  maxSpreadPoints: number;
  commissionType: GroupCommissionType;
  commissionValue: number;
}

/**
 * Live Spread Markup (points) per Symbol Group Markup Engine Spec §5.1.
 *
 * Min / Max are **markup** amounts (not a total-spread band):
 * - Normal markets → applied markup ≈ Minimum
 * - When LP spread widens → markup may rise with it, never above Maximum
 * - COMMISSION_ONLY → 0 (raw feed spread; commission charged separately)
 *
 * Returns the **per-side** points the engine applies to the fill price.
 * Quote UI applies the same value to bid (−) and ask (+) so total spread
 * widens by `2 * perSide` when both sides move — for a configured markup M,
 * perSide = M / 2 so the visible total extra equals M (spec point shift).
 *
 * When min=max=0 under a mapping, markup is 0 (no silent legacy fallback).
 * `legacyMarkupPoints` is only used when there is no mapping band at all
 * (caller passes it for pre-mapping groups).
 */
export function spreadMarkupFromBand(
  lpSpreadPoints: number,
  method: SymbolPricingMethod | undefined,
  minSpreadPoints: number,
  maxSpreadPoints: number,
  legacyMarkupPoints = 0,
): number {
  if (method === 'COMMISSION_ONLY') return 0;
  const min = Math.max(0, minSpreadPoints || 0);
  const max = Math.max(0, maxSpreadPoints || 0);
  if (min === 0 && max === 0) {
    return method === 'SPREAD_ONLY' || method === 'SPREAD_AND_COMMISSION' || !method
      ? Math.max(0, legacyMarkupPoints)
      : 0;
  }
  // Spec: floor at min; track LP spread upward; cap at max (max=0 → fixed min).
  const lp = Math.max(0, lpSpreadPoints);
  let totalMarkup = min;
  if (max > 0) {
    totalMarkup = Math.min(max, Math.max(min, lp));
  }
  // Per-side so bid/ask each move by half → total extra spread ≈ totalMarkup.
  return totalMarkup / 2;
}

/** Resolve commission from a mapping's pricing method (NONE when spread-only). */
export function commissionFromMapping(
  mapping: SymbolMappingPricing | null | undefined,
  fallback: { commissionType: GroupCommissionType; commissionValue: number },
): { commissionType: GroupCommissionType; commissionValue: number } {
  if (!mapping) return fallback;
  if (mapping.pricingMethod === 'SPREAD_ONLY') {
    return { commissionType: 'NONE', commissionValue: 0 };
  }
  return {
    commissionType: mapping.commissionType ?? 'NONE',
    commissionValue: mapping.commissionType === 'NONE' ? 0 : Number(mapping.commissionValue || 0),
  };
}

/**
 * Apply a group's spread markup to the raw LP fill price. The markup always
 * moves the price against the client (broker edge): a BUY fills higher, a SELL
 * fills lower. `points` are price points (10^-digits).
 */
export function applyMarkup(
  side: OrderSide,
  rawPrice: number,
  markupPoints: number,
  digits: number,
): number {
  if (!markupPoints) return rawPrice;
  const delta = markupPoints * pointSize(digits);
  return side === 'BUY' ? rawPrice + delta : rawPrice - delta;
}

/**
 * Dealing commission in the ACCOUNT currency, returned as a NEGATIVE number to
 * store on the position (it flows into equity immediately and realizes at
 * close). Charged in full at open:
 *   PER_LOT  : value × lots               (round-turn)
 *   PER_SIDE : value × lots × 2           (open + close booked up front)
 *   PERCENT  : value% × notional × 2      (both sides)
 */
export function dealingCommission(
  pricing: GroupPricing,
  volumeLots: number,
  spec: SymbolCalcSpec,
  openPrice: number,
  quoteToAcct = 1,
): number {
  const v = pricing.commissionValue || 0;
  switch (pricing.commissionType) {
    case 'PER_LOT':
    case 'ROUND_TURN':
      return -(v * volumeLots);
    case 'PER_SIDE':
      return -(v * volumeLots * 2);
    case 'PERCENT': {
      const notionalAcct = notionalQuote(volumeLots, spec, openPrice) * quoteToAcct;
      return -((v / 100) * notionalAcct * 2);
    }
    default:
      return 0;
  }
}

/**
 * Split a position's accrued swap and commission across a partial close.
 *
 * Swap and commission sit on the position and are realized into balance in
 * proportion to the lots being closed. Whatever is realized MUST be removed
 * from the position, or the remainder keeps carrying charges the client has
 * already paid — every subsequent close then bills them again. Four equal
 * partial closes of an un-split position charge the harmonic series
 * (1 + 1/2 + 1/3 + 1/4) ≈ 2.08x the true commission.
 *
 * `remaining*` is computed by subtraction rather than by its own ratio, so the
 * two halves sum back to the original to within one float ULP — exact once
 * stored at the column's Decimal(28,8) — instead of each side rounding
 * independently and leaving a residue that grows with every partial close.
 *
 * @param swap        accrued swap on the position (signed)
 * @param commission  commission on the position (negative = charged)
 * @param closeVolume lots being closed now
 * @param openVolume  lots on the position before this close
 */
export function splitPositionCharges(
  swap: number,
  commission: number,
  closeVolume: number,
  openVolume: number,
): {
  realizedSwap: number;
  realizedCommission: number;
  remainingSwap: number;
  remainingCommission: number;
} {
  // A full (or over-) close realizes everything; guard against divide-by-zero.
  if (!(openVolume > 0) || closeVolume >= openVolume) {
    return {
      realizedSwap: swap,
      realizedCommission: commission,
      remainingSwap: 0,
      remainingCommission: 0,
    };
  }
  const ratio = closeVolume / openVolume;
  const realizedSwap = swap * ratio;
  const realizedCommission = commission * ratio;
  return {
    realizedSwap,
    realizedCommission,
    remainingSwap: swap - realizedSwap,
    remainingCommission: commission - realizedCommission,
  };
}

export interface OpenPositionView {
  /** Position id — required to act on a view (e.g. pick a stop-out victim). */
  id?: string;
  side: OrderSide;
  volume: number;
  openPrice: number;
  currentPrice: number;
  marginUsed: number;
  swap: number;
  commission: number;
  spec: SymbolCalcSpec;
  quoteToAcct?: number;
}

export interface AccountAggregates {
  floatingPL: number;
  margin: number;
  equity: number;
  freeMargin: number;
  marginLevel: number; // %, 0 when no margin used
}

/**
 * Resolve the factor converting one unit of `quoteCcy` into `accountCcy`, or
 * null when the feed carries no usable conversion pair.
 *
 * Returning null rather than 1 is the whole point: a silent fallback to 1 books
 * margin and P/L in the wrong currency (a USD account trading EURGBP with no
 * GBPUSD quote was out by ~27%) and the error compounds for as long as the
 * position is open. Callers decide what to do — refuse when opening new risk,
 * warn and carry on when valuing something already open.
 *
 * @param mid returns the mid price of a symbol, or null if not quoted
 */
export function resolveFxFactor(
  accountCcy: string,
  quoteCcy: string,
  mid: (symbol: string) => number | null,
): number | null {
  if (!quoteCcy || !accountCcy || quoteCcy === accountCcy) return 1;
  const direct = mid(`${quoteCcy}${accountCcy}`); // e.g. GBP -> USD via GBPUSD
  if (direct != null && direct > 0) return direct;
  const inverse = mid(`${accountCcy}${quoteCcy}`); // e.g. JPY -> USD via USDJPY
  if (inverse != null && inverse > 0) return 1 / inverse;
  return null;
}

/**
 * Live P/L of one open position in the account currency, inclusive of the swap
 * and commission carried on it — the same quantity that flows into equity.
 */
export function positionFloating(p: OpenPositionView): number {
  return (
    positionProfit(p.side, p.volume, p.openPrice, p.currentPrice, p.spec, p.quoteToAcct ?? 1) +
    p.swap +
    p.commission
  );
}

/**
 * The open position carrying the largest loss — the stop-out victim.
 *
 * Selection MUST be done on live floating P/L. `Position.profit` in the
 * database is only written when a position closes, so ordering open rows by
 * that column sorts an all-zero field and liquidates an arbitrary position,
 * potentially a profitable one.
 *
 * Ties resolve to the earliest position in the input, so callers that read
 * positions in a stable order (openedAt) get deterministic, FIFO behaviour.
 *
 * @param skipIds positions to exclude — used to pass over one that failed to
 *                close so a single unclosable position cannot stall the cascade.
 */
export function worstPosition(
  positions: OpenPositionView[],
  skipIds?: ReadonlySet<string>,
): OpenPositionView | null {
  let worst: OpenPositionView | null = null;
  let worstPL = Infinity;
  for (const p of positions) {
    if (skipIds && p.id && skipIds.has(p.id)) continue;
    const pl = positionFloating(p);
    if (pl < worstPL) {
      worstPL = pl;
      worst = p;
    }
  }
  return worst;
}

/**
 * Recompute live account aggregates from balance+credit and the set of open
 * positions. Called by the engine on every relevant tick.
 *   equity      = balance + credit + Σ floatingPL + Σ swap + Σ commission
 *   margin      = Σ marginUsed
 *   freeMargin  = equity - margin
 *   marginLevel = margin > 0 ? equity / margin * 100 : 0
 */
export function computeAggregates(
  balance: number,
  credit: number,
  positions: OpenPositionView[],
): AccountAggregates {
  let floatingPL = 0;
  let margin = 0;
  for (const p of positions) {
    floatingPL += positionFloating(p);
    margin += p.marginUsed;
  }
  const equity = balance + credit + floatingPL;
  const freeMargin = equity - margin;
  const marginLevel = margin > 0 ? (equity / margin) * 100 : 0;
  return { floatingPL, margin, equity, freeMargin, marginLevel };
}

/**
 * Cash an account may withdraw, given its balance and CURRENT free margin.
 *
 *   available = max(0, min(balance, freeMargin))
 *
 * Bounded by balance because credit (bonus) is not withdrawable, and by free
 * margin because funds backing an open position are not the client's to take.
 *
 * The caller must pass a `freeMargin` derived from live prices. Deriving it
 * from `Position.profit` treats open positions as flat and lets a client
 * withdraw an unrealized loss — the balance then goes negative when the
 * position closes.
 */
export function withdrawableCash(balance: number, freeMargin: number): number {
  return Math.max(0, Math.min(balance, freeMargin));
}

/** Round a volume to the symbol lot step and clamp to [min,max]. */
export function normalizeVolume(
  volume: number,
  minLot: number,
  maxLot: number,
  lotStep: number,
): number {
  const steps = Math.round(volume / lotStep);
  let v = steps * lotStep;
  v = Math.max(minLot, Math.min(maxLot, v));
  // fix floating error
  return Math.round(v / lotStep) * lotStep;
}

/**
 * Snap volume to lot step for NEW opens. Unlike normalizeVolume, never upgrades
 * undersized lots to minLot (that would open more risk than the client asked).
 * Returns null when volume is non-positive, off-step beyond float noise, or
 * outside [minLot, maxLot].
 */
export function snapVolume(
  volume: number,
  minLot: number,
  maxLot: number,
  lotStep: number,
): number | null {
  if (!(volume > 0) || !Number.isFinite(volume) || !(lotStep > 0)) return null;
  if (!(minLot > 0) || maxLot < minLot) return null;
  const steps = Math.round(volume / lotStep);
  let v = steps * lotStep;
  v = Math.round(v / lotStep) * lotStep;
  // Reject if snap drifted too far from the request (client sent junk / wrong step).
  if (Math.abs(volume - v) > lotStep * 0.51 + 1e-9) return null;
  if (v + 1e-12 < minLot || v - 1e-12 > maxLot) return null;
  return v;
}

/** Round a price to symbol digits. */
export function roundPrice(price: number, digits: number): number {
  const f = Math.pow(10, digits);
  return Math.round(price * f) / f;
}

/**
 * Apply slippage tolerance for a market/one-click order. Returns the worst
 * acceptable fill price; engine rejects if market is beyond it.
 *   slippagePoints = 0  → no slippage allowed (default per spec).
 */
export function slippageBound(
  side: OrderSide,
  requestedPrice: number,
  slippagePoints: number,
  digits: number,
): number {
  const slip = slippagePoints * pointSize(digits);
  // BUY fills at ask; tolerate higher. SELL fills at bid; tolerate lower.
  return side === 'BUY' ? requestedPrice + slip : requestedPrice - slip;
}
