/**
 * Pure Bid/Ask crossing rules for pending orders and protective SL/TP.
 *
 * No I/O. The engine calls these on every fast tick; tests prove gap/jump
 * behaviour without a database. MT5 sides:
 *   pending BUY  → Ask
 *   pending SELL → Bid
 *   long  SL/TP  → Bid  (exit)
 *   short SL/TP  → Ask  (exit)
 *
 * Crossing, not equality: a jump through the level still fires.
 */

export type PendingType =
  | 'BUY_LIMIT'
  | 'SELL_LIMIT'
  | 'BUY_STOP'
  | 'SELL_STOP'
  | 'LIMIT'
  | 'STOP'
  | 'STOP_LIMIT'
  | 'MARKET'
  | string;

export type Side = 'BUY' | 'SELL' | string;

/** What the trigger engine should do this tick. */
export type PendingAction = 'none' | 'fill' | 'arm_stop_limit';

export function pendingFires(args: {
  type: PendingType;
  side: Side;
  bid: number;
  ask: number;
  trigger: number;
  stopPrice?: number | null;
  limitPrice?: number | null;
  /** STOP_LIMIT: stop already armed on a previous tick. */
  stopTriggered?: boolean;
}): PendingAction {
  const t = String(args.type).toUpperCase();
  const side = String(args.side).toUpperCase();
  const { bid, ask, trigger } = args;
  if (!(bid > 0) || !(ask > 0) || !(trigger > 0)) return 'none';

  if (t === 'STOP_LIMIT') {
    const stop = args.stopPrice != null && args.stopPrice > 0 ? args.stopPrice : trigger;
    const limit = args.limitPrice != null && args.limitPrice > 0 ? args.limitPrice : trigger;
    const stopHit = side === 'BUY' ? ask >= stop : bid <= stop;
    const limitHit = side === 'BUY' ? ask <= limit : bid >= limit;
    if (!args.stopTriggered) {
      if (stopHit && limitHit) return 'fill';
      if (stopHit) return 'arm_stop_limit';
      return 'none';
    }
    return limitHit ? 'fill' : 'none';
  }

  switch (t) {
    case 'BUY_LIMIT':
      return ask <= trigger ? 'fill' : 'none';
    case 'SELL_LIMIT':
      return bid >= trigger ? 'fill' : 'none';
    case 'BUY_STOP':
      return ask >= trigger ? 'fill' : 'none';
    case 'SELL_STOP':
      return bid <= trigger ? 'fill' : 'none';
    case 'LIMIT':
      return side === 'BUY' ? (ask <= trigger ? 'fill' : 'none') : bid >= trigger ? 'fill' : 'none';
    case 'STOP':
      return side === 'BUY' ? (ask >= trigger ? 'fill' : 'none') : bid <= trigger ? 'fill' : 'none';
    default:
      return 'none';
  }
}

export function isLimitFillType(type: PendingType): boolean {
  const t = String(type).toUpperCase();
  return t === 'BUY_LIMIT' || t === 'SELL_LIMIT' || t === 'LIMIT' || t === 'STOP_LIMIT';
}

/** Protective SL/TP. BUY exits on Bid, SELL on Ask. SL wins if both hit. */
export function protectiveHit(args: {
  side: Side;
  bid: number;
  ask: number;
  sl?: number | null;
  tp?: number | null;
}): { hit: 'SL' | 'TP' | null; level: number | null } {
  const isBuy = String(args.side).toUpperCase() === 'BUY';
  const mkt = isBuy ? args.bid : args.ask;
  const sl = args.sl != null && args.sl > 0 ? args.sl : null;
  const tp = args.tp != null && args.tp > 0 ? args.tp : null;
  const hitSL = sl != null && (isBuy ? mkt <= sl : mkt >= sl);
  const hitTP = tp != null && (isBuy ? mkt >= tp : mkt <= tp);
  if (hitSL) return { hit: 'SL', level: sl };
  if (hitTP) return { hit: 'TP', level: tp };
  return { hit: null, level: null };
}

/**
 * Limit fills may never be worse than the client level. Stops take the market
 * (gap slippage stays with the client).
 */
export function clampLimitFill(side: Side, marketPrice: number, limit: number): number {
  return String(side).toUpperCase() === 'BUY' ? Math.min(marketPrice, limit) : Math.max(marketPrice, limit);
}
