/**
 * A position's commission as clients see it.
 *
 * The engine debits commission from the balance when a trade is executed and stores it in
 * `commissionCharged`; `commission` only holds what is still to be realized at close (the old
 * behaviour, kept for positions that were already open when charging at execution began).
 * Whichever way a position was charged, the amount to show is their sum. Equity maths must keep
 * using `commission` alone — `commissionCharged` is already inside the balance.
 */
export function totalCommission(p: { commission?: unknown; commissionCharged?: unknown }): number {
  return Number(p.commission ?? 0) + Number(p.commissionCharged ?? 0);
}

/** Same row, with `commission` replaced by the display total and `commissionCharged` kept. */
export function withTotalCommission<T extends { commission?: unknown; commissionCharged?: unknown }>(
  p: T,
): Omit<T, 'commission'> & { commission: number } {
  return { ...p, commission: totalCommission(p) };
}
