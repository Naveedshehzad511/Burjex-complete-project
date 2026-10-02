/**
 * Choosing which candle rows one flush cycle writes.
 *
 * Pure (no I/O) so the rules can be tested. The queues are dequeued IN PLACE, exactly as the
 * flusher always did, and rows that did not fit stay queued.
 *
 * Rules
 *   1. MT5 bridge history for buckets BEFORE the engine's era (`gapFill` unset) is authoritative
 *      and wins over anything else for the same bar.
 *   2. An engine-CLOSED bar is final. It must be written, so it wins over a gap-fill bridge row for
 *      the same bar. Gap-fill rows are "insert only if the bucket is empty" (DO NOTHING on conflict),
 *      so when such a row used to claim the key first, the closed bar was discarded for good and the
 *      database kept the forming-tip snapshot taken up to 20 s earlier: the High / Low reached in
 *      the last seconds of the candle were lost and the finished candle's wick shrank.
 *   3. Gap-fill rows go last, only for buckets nothing else wrote this cycle.
 */
export interface FlushRow {
  symbol: string;
  tf: string;
  t: number;
  gapFill?: boolean;
}

export interface FlushSelection<R extends FlushRow> {
  /** Every row chosen for this cycle. */
  batch: R[];
  /** The history rows among them (re-queued on failure). */
  history: R[];
  /** The engine-closed rows among them (re-queued on failure). */
  closed: R[];
  /** Keys already claimed, so forming tips can be added without clashing. */
  seen: Set<string>;
}

export const flushKey = (r: FlushRow): string => `${r.symbol}|${r.tf}|${r.t}`;

export function selectFlushRows<R extends FlushRow>(
  pendingHistory: R[],
  pendingClosed: R[],
  max: number,
): FlushSelection<R> {
  const batch: R[] = [];
  const history: R[] = [];
  const closed: R[] = [];
  const seen = new Set<string>();
  const push = (row: R, into: R[]): boolean => {
    const k = flushKey(row);
    if (seen.has(k)) return false;
    seen.add(k);
    into.push(row);
    batch.push(row);
    return true;
  };

  // Everything the history queue hands over this cycle, in arrival order.
  const taken: R[] = [];
  while (pendingHistory.length > 0 && taken.length < max) taken.push(pendingHistory.shift()!);

  // 1. Authoritative bridge history.
  const gapFills: R[] = [];
  for (const row of taken) {
    if (row.gapFill) gapFills.push(row);
    else if (batch.length < max) push(row, history);
    else pendingHistory.push(row); // no room: stays queued
  }
  // 2. Engine-closed bars.
  while (pendingClosed.length > 0 && batch.length < max) push(pendingClosed.shift()!, closed);
  // 3. Gap-fill rows, only where nothing else claimed the bucket.
  const deferred: R[] = [];
  for (const row of gapFills) {
    if (batch.length >= max) deferred.push(row);
    else push(row, history);
  }
  // Rows that did not fit go back to the FRONT of the queue, in their original order.
  pendingHistory.unshift(...deferred);

  return { batch, history, closed, seen };
}
