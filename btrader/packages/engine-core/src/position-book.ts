/**
 * In-memory index of OPEN positions, keyed by tenant + symbol.
 *
 * WHY THIS EXISTS
 * ---------------
 * onTick runs four passes per symbol and three of them issued the same query:
 *
 *     position.findMany({ where: { tenantId, symbolId, status: 'OPEN' } })
 *
 * checkProtectiveStops and checkStopOut run on every pass, emitLiveUpdates on
 * every other one, so at the default 250ms drain that is ten identical reads
 * per symbol per second. Measured on a 3.4M-row table those cost 10.5ms each
 * even with the right composite index - about 0.6 of a core across six busy
 * symbols, purely to re-read rows that had not changed.
 *
 * The book answers all three from memory instead. The database stays the
 * authority for every WRITE; this is only ever a read path.
 *
 * CORRECTNESS
 * -----------
 * A stale book is not a performance bug, it is a money bug: a position missing
 * from it never has its stop-loss checked. Three things keep it honest, and all
 * three matter:
 *
 *  1. WRITE-THROUGH, AFTER COMMIT. The engine updates the book only once the
 *     enclosing transaction has committed. Applying inside the transaction
 *     would leave the book holding a position that a rollback erased.
 *
 *  2. PERIODIC RECONCILE. Positions are also written outside this class -
 *     swap accrual in apps/trading-engine, admin tooling, a DBA at a psql
 *     prompt. Anything the book did not see is corrected by [reconcile], so a
 *     missed update self-heals within one interval instead of persisting until
 *     restart. This is the part that makes the design survive contact with a
 *     codebase that will keep growing new write sites.
 *
 *  3. DIVERGENCE IS REPORTED, NOT SWALLOWED. [reconcile] returns what it had to
 *     correct. A book that quietly repairs itself hides the bug that caused the
 *     drift; the caller is expected to log a non-zero result.
 *
 * SINGLE PROCESS ONLY
 * -------------------
 * This assumes ONE engine process per tenant. That is true today, but it is
 * incidental today and load-bearing after this: two engines would each hold a
 * book, each evaluate stops, and each try to close the same position. Guard it
 * at startup rather than trusting it stays true.
 */

import type { Prisma } from '@btrader/db';

/**
 * A position as the tick path reads it.
 *
 * Decimal columns keep their Prisma.Decimal type rather than being widened to
 * `unknown`: the readers pass them straight into d() and positionProfit(), and
 * a loose type here would push the money arithmetic into `any` where a unit
 * mix-up stops being a compile error.
 */
export type BookRow = {
  id: string;
  tenantId: string;
  accountId: string;
  symbolId: string;
  side: string;
  volume: Prisma.Decimal;
  openPrice: Prisma.Decimal;
  slPrice: Prisma.Decimal | null;
  tpPrice: Prisma.Decimal | null;
  marginUsed: Prisma.Decimal;
  swap: Prisma.Decimal;
  commission: Prisma.Decimal;
  coveredVolume: Prisma.Decimal;
  openedAt: Date;
  /** Denormalised from the owning account; emitLiveUpdates needs it per row. */
  accountCurrency: string;
  /** Trading group for client-quote markup on the SL/TP tick path. */
  groupId?: string | null;
  /** Set when SL/TP/manual close has been latched; skip re-detect. */
  execClaimKind?: string | null;
  execClaimedAt?: Date | null;
};

const key = (tenantId: string, symbolId: string) => `${tenantId}\u0000${symbolId}`;

export class PositionBook {
  private buckets = new Map<string, Map<string, BookRow>>();
  /** positionId -> bucket key, so a close can find its row without the symbol. */
  private where = new Map<string, string>();
  private hydrated = false;

  get ready(): boolean {
    return this.hydrated;
  }

  /** Total open positions held. Cheap; for logging and health checks. */
  get size(): number {
    return this.where.size;
  }

  /**
   * Replace the entire contents. Used at boot and by [reconcile].
   *
   * Builds into fresh maps and swaps at the end: a reader running between a
   * clear() and a refill would see an empty book and skip every stop-loss for
   * that instant.
   */
  load(rows: BookRow[]): void {
    const buckets = new Map<string, Map<string, BookRow>>();
    const where = new Map<string, string>();
    for (const r of rows) {
      const k = key(r.tenantId, r.symbolId);
      let b = buckets.get(k);
      if (b === undefined) {
        b = new Map();
        buckets.set(k, b);
      }
      b.set(r.id, r);
      where.set(r.id, k);
    }
    this.buckets = buckets;
    this.where = where;
    this.hydrated = true;
  }

  /** Open positions on one symbol. Never null; empty when there are none. */
  forSymbol(tenantId: string, symbolId: string): BookRow[] {
    const b = this.buckets.get(key(tenantId, symbolId));
    return b === undefined ? [] : [...b.values()];
  }

  /** Distinct accounts holding this symbol - what checkStopOut iterates. */
  accountsForSymbol(tenantId: string, symbolId: string): string[] {
    const b = this.buckets.get(key(tenantId, symbolId));
    if (b === undefined) return [];
    const out = new Set<string>();
    for (const r of b.values()) out.add(r.accountId);
    return [...out];
  }

  /** Insert or replace one row. Call AFTER the transaction commits. */
  upsert(row: BookRow): void {
    const k = key(row.tenantId, row.symbolId);
    const prev = this.where.get(row.id);
    // A position never changes symbol, but if a caller ever passes a different
    // one, leaving the old entry behind would double-count it forever.
    if (prev !== undefined && prev !== k) this.buckets.get(prev)?.delete(row.id);
    let b = this.buckets.get(k);
    if (b === undefined) {
      b = new Map();
      this.buckets.set(k, b);
    }
    b.set(row.id, row);
    this.where.set(row.id, k);
  }

  /** Apply a partial change to a row already held, if it is held. */
  patch(positionId: string, fields: Partial<BookRow>): void {
    const k = this.where.get(positionId);
    if (k === undefined) return;
    const row = this.buckets.get(k)?.get(positionId);
    if (row === undefined) return;
    Object.assign(row, fields);
  }

  /** Drop a position - it closed, or is no longer OPEN. */
  remove(positionId: string): void {
    const k = this.where.get(positionId);
    if (k === undefined) return;
    const b = this.buckets.get(k);
    b?.delete(positionId);
    if (b !== undefined && b.size === 0) this.buckets.delete(k);
    this.where.delete(positionId);
  }

  /**
   * Compare against the authoritative rows and correct any drift.
   *
   * Returns counts of what was WRONG, so a caller can alarm on it. Zero is the
   * expected steady state; anything else means a write site is not updating the
   * book and should be found, not just papered over by the next reconcile.
   */
  reconcile(rows: BookRow[]): { missing: number; stale: number; extra: number } {
    const truth = new Map<string, BookRow>();
    for (const r of rows) truth.set(r.id, r);

    let missing = 0;
    let stale = 0;
    for (const [id, r] of truth) {
      const k = this.where.get(id);
      const held = k === undefined ? undefined : this.buckets.get(k)?.get(id);
      if (held === undefined) {
        missing++;
      } else if (!sameRow(held, r)) {
        stale++;
      }
    }
    // Held but no longer open in the database - a close the book never saw.
    // These are the dangerous ones in the other direction: the engine would
    // keep evaluating stops against a position that is already gone.
    let extra = 0;
    for (const id of this.where.keys()) if (!truth.has(id)) extra++;

    if (missing || stale || extra) this.load(rows);
    return { missing, stale, extra };
  }
}

/** Field-wise comparison of the values the tick path actually reads. */
function sameRow(a: BookRow, b: BookRow): boolean {
  return (
    String(a.volume) === String(b.volume) &&
    String(a.openPrice) === String(b.openPrice) &&
    String(a.slPrice ?? '') === String(b.slPrice ?? '') &&
    String(a.tpPrice ?? '') === String(b.tpPrice ?? '') &&
    String(a.swap) === String(b.swap) &&
    String(a.commission) === String(b.commission) &&
    String(a.marginUsed) === String(b.marginUsed) &&
    a.side === b.side &&
    a.accountId === b.accountId &&
    (a.groupId ?? '') === (b.groupId ?? '')
  );
}
