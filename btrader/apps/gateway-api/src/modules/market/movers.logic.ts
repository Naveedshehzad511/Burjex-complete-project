/**
 * Top Gainers / Top Losers: which instruments, and which five of them.
 * Pure functions (no database, no clock) so the rules can be tested on their own.
 */

/** The categories the Home screen covers. */
export type MoverCategory = 'COMMODITIES' | 'CRYPTO' | 'INDICES' | 'STOCKS' | 'FOREX';
export const MOVER_CATEGORIES: MoverCategory[] = ['COMMODITIES', 'CRYPTO', 'INDICES', 'STOCKS', 'FOREX'];

/** Cards in each carousel. */
export const MOVER_CARDS = 5;

/**
 * The admin-set instrument class -> the category shown on Home. Metals (gold, silver) are commodities.
 * Forex pairs are their own category. Custom instruments are not part of the movers.
 */
export function moverCategory(instrumentClass: string | null | undefined): MoverCategory | null {
  switch ((instrumentClass ?? '').toUpperCase()) {
    case 'COMMODITIES':
    case 'METALS':
      return 'COMMODITIES';
    case 'CRYPTO':
      return 'CRYPTO';
    case 'INDICES':
      return 'INDICES';
    case 'STOCKS':
      return 'STOCKS';
    case 'FOREX':
      return 'FOREX';
    default:
      return null;
  }
}

export interface MoverCandidate {
  /** The name the client sees (their group's display symbol). */
  symbol: string;
  /** The platform's own symbol (what the quotes are keyed by). */
  underlying: string;
  name: string;
  category: MoverCategory;
  price: number;
  digits: number;
  /** % change against the previous day's close. */
  changePct: number;
}

/** % change of [price] against [prevClose]; null when either is not a usable price. */
export function changePercent(price: number, prevClose: number): number | null {
  if (!(price > 0) || !(prevClose > 0)) return null;
  return ((price - prevClose) / prevClose) * 100;
}

/**
 * The cards of one carousel: the strongest mover of each category, then the next strongest overall,
 * up to [cards], ordered strongest first. A gainer must actually have gained and a loser actually lost, so a quiet
 * market gives fewer cards instead of a "gainer" that is down.
 */
export function pickMovers(candidates: MoverCandidate[], side: 'gainers' | 'losers', cards = MOVER_CARDS): MoverCandidate[] {
  const sign = side === 'gainers' ? 1 : -1;
  // strongest first; equal moves keep a stable order by name
  const stronger = (a: MoverCandidate, b: MoverCandidate) => sign * (b.changePct - a.changePct) || a.symbol.localeCompare(b.symbol);
  const moved = candidates.filter((c) => sign * c.changePct > 0).sort(stronger);

  const chosen: MoverCandidate[] = [];
  for (const category of MOVER_CATEGORIES) {
    const best = moved.find((c) => c.category === category);
    if (best) chosen.push(best);
  }
  for (const c of moved) {
    if (chosen.length >= cards) break;
    if (!chosen.includes(c)) chosen.push(c);
  }
  return chosen.sort(stronger).slice(0, cards);
}

/** Start (epoch seconds) of the broker's current day: the boundary between "today" and the previous day's close. */
export function brokerDayStartSec(nowMs: number, brokerUtcOffsetSec: number): number {
  const nowSec = Math.floor(nowMs / 1000);
  return Math.floor((nowSec + brokerUtcOffsetSec) / 86400) * 86400 - brokerUtcOffsetSec;
}
