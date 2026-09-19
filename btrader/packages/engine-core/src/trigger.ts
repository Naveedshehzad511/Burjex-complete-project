/** Bid/Ask crossing rules — same as Rust `apps/trading-core-rs/src/trigger.rs`. */

export function protectiveHit(
  side: string,
  bid: number,
  ask: number,
  sl?: number | null,
  tp?: number | null,
): { hit: 'SL' | 'TP' | null; level: number | null } {
  const isBuy = String(side).toUpperCase() === 'BUY';
  const mkt = isBuy ? bid : ask;
  const slv = sl != null && sl > 0 ? sl : null;
  const tpv = tp != null && tp > 0 ? tp : null;
  const hitSl = slv != null && (isBuy ? mkt <= slv : mkt >= slv);
  const hitTp = tpv != null && (isBuy ? mkt >= tpv : mkt <= tpv);
  if (hitSl) return { hit: 'SL', level: slv };
  if (hitTp) return { hit: 'TP', level: tpv };
  return { hit: null, level: null };
}
