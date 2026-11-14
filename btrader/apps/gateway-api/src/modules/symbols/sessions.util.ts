/**
 * Whether a symbol is tradable right now, from its admin-configured session
 * windows. Mirrors the trading engine's `is_symbol_tradable`
 * (trading-core-rs/src/sessions.rs) and the portal's own `isSymbolTradableNow`
 * (btrader_core/lib/src/models/symbol.dart) field-for-field, so the `tradable`
 * flag this endpoint returns never disagrees with what the engine will
 * actually accept or reject.
 *
 * This is served alongside the raw `tradingSessions` the portal already
 * receives — the client recomputes the same thing continuously (a session
 * boundary crossing must flip the BUY/SELL buttons with no refetch), this
 * field is the request-time snapshot for any other consumer.
 */

export interface TradingSessionWindow {
  day: number; // 0=Sunday..6=Saturday, UTC
  open: string; // "HH:MM", UTC
  close: string; // "HH:MM", UTC
}

function minutesOfDay(hhmm: string): number {
  const [h, m] = hhmm.split(':');
  return (parseInt(h, 10) || 0) * 60 + (parseInt(m, 10) || 0);
}

function isMarketOpen(sessions: TradingSessionWindow[], now: Date): boolean {
  if (sessions.length === 0) return true;
  const day = now.getUTCDay(); // 0=Sunday..6=Saturday
  const mins = now.getUTCHours() * 60 + now.getUTCMinutes();
  for (const s of sessions) {
    if (s.day !== day) continue;
    const open = minutesOfDay(s.open);
    const close = minutesOfDay(s.close);
    if (open <= close) {
      if (mins >= open && mins < close) return true;
    } else if (mins >= open || mins < close) {
      return true; // overnight window (e.g. 22:00 -> 06:00)
    }
  }
  return false;
}

/**
 * UTC offset of New York in hours: -4 in US daylight time (2nd Sunday of March 07:00 UTC to 1st Sunday of
 * November 06:00 UTC), else -5. Mirrors `new_york_offset_hours` in trading-core-rs/src/sessions.rs.
 */
export function newYorkOffsetHours(now: Date): number {
  const y = now.getUTCFullYear();
  const firstSunday = (month: number) => 1 + ((7 - new Date(Date.UTC(y, month, 1)).getUTCDay()) % 7);
  const start = Date.UTC(y, 2, firstSunday(2) + 7, 7);
  const end = Date.UTC(y, 10, firstSunday(10), 6);
  const t = now.getTime();
  return t >= start && t < end ? -4 : -5;
}

/** The forex week opens (Sunday) and closes (Friday) at 17:00 New York time: 21:00 UTC in summer, 22:00 UTC in winter. */
const FX_ROLL_NY_HOUR = 17;

function isForexWeekOpen(now: Date): boolean {
  const ny = new Date(now.getTime() + newYorkOffsetHours(now) * 3600_000);
  const day = ny.getUTCDay();
  const mins = ny.getUTCHours() * 60 + ny.getUTCMinutes();
  const roll = FX_ROLL_NY_HOUR * 60;
  if (day === 6) return false; // Saturday: always closed
  if (day === 0 && mins < roll) return false; // before the week opens Sunday
  if (day === 5 && mins >= roll) return false; // after the week closes Friday
  return true;
}

export function isSymbolTradableNow(
  sessions: unknown,
  instrumentClass: string | null | undefined,
  now: Date = new Date(),
): boolean {
  const parsed = Array.isArray(sessions)
    ? (sessions as any[]).filter(
        (s) => s && typeof s.day === 'number' && typeof s.open === 'string' && typeof s.close === 'string',
      )
    : [];
  if (parsed.length > 0) return isMarketOpen(parsed as TradingSessionWindow[], now);
  if ((instrumentClass ?? '').toUpperCase() === 'CRYPTO') return true;
  return isForexWeekOpen(now);
}
