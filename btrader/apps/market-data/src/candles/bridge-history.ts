/**
 * Conflict policy for MT5 bridge history bars (POST /ingest/candles).
 *
 * Pure so the rules can be tested.
 *
 * - `era` (default, the Manager bridge): before the canonical era (`liveFrom`) the bridge owns the
 *   bars outright; from `liveFrom` onward the tick engine owns them, so a bridge bar is gap-fill only.
 * - `gapsOnly`: every bar is gap-fill. It may occupy an empty bucket, never restate a stored bar.
 * - `authoritative` (the BTraderFeed EA's repair pass): MT5's own bar is the truth for every CLOSED
 *   bucket and overwrites the stored one; a bucket still forming is dropped, it belongs to the tick
 *   engine. Used when the EA's terminal is also the tick source, so its bar is the complete version
 *   of the same prices. That repairs a bar the engine only saw part of (ticks lost while the feed
 *   was down: the 08:00 M5 bar opened at the 08:01:09 price after an EA restart), which a
 *   gap-fill can never do because the bucket is not empty.
 */
export type BridgeMode = 'era' | 'gapsOnly' | 'authoritative';

export function markBridgeRows<R extends { t: number }>(
  rows: R[],
  liveFrom: number | undefined,
  mode: BridgeMode,
  nowSec: number,
  tfSec: number,
): Array<R & { gapFill?: boolean }> {
  const out: Array<R & { gapFill?: boolean }> = [];
  for (const b of rows) {
    if (mode === 'authoritative') {
      if (b.t + tfSec <= nowSec) out.push(b);
    } else if (mode === 'gapsOnly' || (liveFrom !== undefined && b.t >= liveFrom)) {
      out.push({ ...b, gapFill: true });
    } else {
      out.push(b);
    }
  }
  return out.sort((a, b) => a.t - b.t);
}
