// Trading-session evaluation. Sessions are stored on Symbol.tradingSessions as
// JSON: [{ day: 0-6, open: "HH:mm", close: "HH:mm" }]. Empty/null = 24/7.

export interface SessionWindow {
  day: number; // 0=Sun .. 6=Sat
  open: string; // "HH:mm"
  close: string; // "HH:mm"
}

function minutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

/** Is the market open for this symbol at the given instant (in tenant tz)? */
export function isMarketOpen(sessions: SessionWindow[] | null | undefined, now: Date): boolean {
  if (!sessions || sessions.length === 0) return true; // 24/7
  const day = now.getUTCDay();
  const mins = now.getUTCHours() * 60 + now.getUTCMinutes();
  for (const s of sessions) {
    if (s.day !== day) continue;
    const open = minutes(s.open);
    const close = minutes(s.close);
    if (open <= close) {
      if (mins >= open && mins < close) return true;
    } else {
      // wraps midnight
      if (mins >= open || mins < close) return true;
    }
  }
  return false;
}

/**
 * Default weekly forex schedule used when a symbol has NO explicit sessions.
 * The FX week runs Sunday ~21:00 UTC → Friday ~21:00 UTC; weekends are closed.
 * (21:00 UTC ≈ 5pm New York; admins can set precise per-symbol sessions to override.)
 */
export function isForexWeekOpen(now: Date): boolean {
  const day = now.getUTCDay(); // 0=Sun .. 6=Sat
  const mins = now.getUTCHours() * 60 + now.getUTCMinutes();
  const ROLL = 21 * 60; // 21:00 UTC
  if (day === 6) return false; // Saturday — closed all day
  if (day === 0 && mins < ROLL) return false; // Sunday before open
  if (day === 5 && mins >= ROLL) return false; // Friday after close
  return true;
}

/**
 * Market-open check for a symbol. Explicit `sessions` win. Otherwise the default
 * depends on the instrument class: CRYPTO trades 24/7; everything else (forex,
 * metals, indices, stocks, commodities) follows the forex week (closed weekends).
 */
export function isSymbolTradable(
  sessions: SessionWindow[] | null | undefined,
  instrumentClass: string | null | undefined,
  now: Date,
): boolean {
  if (sessions && sessions.length > 0) return isMarketOpen(sessions, now);
  if ((instrumentClass ?? '').toUpperCase() === 'CRYPTO') return true; // 24/7
  return isForexWeekOpen(now);
}

/**
 * When a DAY order expires: end of the current (or wrapping) session, else
 * Friday 21:00 UTC for FX, else next UTC midnight for 24/7 crypto.
 */
export function sessionClosesAt(
  sessions: SessionWindow[] | null | undefined,
  instrumentClass: string | null | undefined,
  now: Date,
): Date {
  if (sessions && sessions.length > 0) {
    const day = now.getUTCDay();
    const mins = now.getUTCHours() * 60 + now.getUTCMinutes();
    let best: Date | null = null;
    for (const s of sessions) {
      const closeM = minutes(s.close);
      const openM = minutes(s.open);
      let closeDay = s.day;
      if (openM > closeM) closeDay = (s.day + 1) % 7;
      const addDays = (closeDay - day + 7) % 7;
      if (addDays === 0 && mins >= closeM) continue;
      const d = new Date(now);
      d.setUTCDate(d.getUTCDate() + addDays);
      d.setUTCHours(Math.floor(closeM / 60), closeM % 60, 0, 0);
      if (!best || d < best) best = d;
    }
    if (best) return best;
  }
  if ((instrumentClass ?? '').toUpperCase() === 'CRYPTO') {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0));
    return d;
  }
  const ROLL = 21;
  const d = new Date(now);
  const day = d.getUTCDay();
  const mins = d.getUTCHours() * 60 + d.getUTCMinutes();
  let add = (5 - day + 7) % 7;
  if (day === 5 && mins >= ROLL * 60) add = 7;
  if (day === 6) add = 6;
  d.setUTCDate(d.getUTCDate() + add);
  d.setUTCHours(ROLL, 0, 0, 0);
  return d;
}
