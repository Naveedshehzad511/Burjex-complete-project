// ============================================================================
//  Overnight-swap scheduling helpers.
//
//  Kept out of main.ts because that module boots the service on import (Redis
//  connections, tick subscriptions), which makes it untestable.
// ============================================================================

/**
 * Start of the UTC day that `now` belongs to.
 *
 * A position counts as already swapped for the day when it has a SWAP deal at
 * or after this instant. This is what makes the accrual idempotent across a
 * process restart: the previous in-memory `lastSwapDate` flag reset to empty on
 * boot, so a restart inside the rollover hour accrued every open position a
 * second time.
 *
 * Valid because the rollover hour always falls inside the same UTC date as the
 * run — do not set SWAP_ROLLOVER_HOUR outside 0..23.
 */
export function swapDayStart(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

/** True when `now` is inside the configured UTC rollover hour. */
export function isRolloverHour(now: Date, rolloverHour: number): boolean {
  return now.getUTCHours() === rolloverHour;
}

/** Swap multiplier for the day — triple on the symbol's 3-day weekday. */
export function swapMultiplier(now: Date, swap3DayWeekday: number | null | undefined): number {
  return now.getUTCDay() === swap3DayWeekday ? 3 : 1;
}
