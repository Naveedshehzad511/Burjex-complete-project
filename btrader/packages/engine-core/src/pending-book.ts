/**
 * In-memory index of working (PENDING / in-flight PARTIAL) orders, keyed by
 * tenant + symbol — the pending counterpart of PositionBook.
 *
 * triggerPendingOrders used to `findMany` on every fast tick. The index is
 * cheap; the cost was still a round-trip per symbol per 50ms. This book answers
 * "anything working on EURUSD?" from RAM. The database remains the authority
 * for claims and fills.
 */

export type PendingRow = {
  id: string;
  tenantId: string;
  accountId: string;
  symbolId: string;
  side: string;
  type: string;
  status: string;
  volume: number;
  price: number | null;
  stopPrice: number | null;
  slPrice: number | null;
  tpPrice: number | null;
  expiresAt: Date | null;
  updatedAt: Date;
  stopTriggered: boolean;
};

const key = (tenantId: string, symbolId: string) => `${tenantId}\u0000${symbolId}`;

export class PendingBook {
  private buckets = new Map<string, Map<string, PendingRow>>();
  private where = new Map<string, string>();
  private hydrated = false;

  get ready(): boolean {
    return this.hydrated;
  }

  get size(): number {
    return this.where.size;
  }

  load(rows: PendingRow[]): void {
    const buckets = new Map<string, Map<string, PendingRow>>();
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

  forSymbol(tenantId: string, symbolId: string): PendingRow[] {
    const b = this.buckets.get(key(tenantId, symbolId));
    return b === undefined ? [] : [...b.values()];
  }

  upsert(row: PendingRow): void {
    const k = key(row.tenantId, row.symbolId);
    const prev = this.where.get(row.id);
    if (prev !== undefined && prev !== k) this.buckets.get(prev)?.delete(row.id);
    let b = this.buckets.get(k);
    if (b === undefined) {
      b = new Map();
      this.buckets.set(k, b);
    }
    b.set(row.id, row);
    this.where.set(row.id, k);
  }

  patch(orderId: string, fields: Partial<PendingRow>): void {
    const k = this.where.get(orderId);
    if (k === undefined) return;
    const row = this.buckets.get(k)?.get(orderId);
    if (row === undefined) return;
    Object.assign(row, fields);
  }

  remove(orderId: string): void {
    const k = this.where.get(orderId);
    if (k === undefined) return;
    const b = this.buckets.get(k);
    b?.delete(orderId);
    if (b !== undefined && b.size === 0) this.buckets.delete(k);
    this.where.delete(orderId);
  }

  reconcile(rows: PendingRow[]): { missing: number; stale: number; extra: number } {
    const truth = new Map<string, PendingRow>();
    for (const r of rows) truth.set(r.id, r);
    let missing = 0;
    let stale = 0;
    for (const [id, r] of truth) {
      const k = this.where.get(id);
      const held = k === undefined ? undefined : this.buckets.get(k)?.get(id);
      if (held === undefined) missing++;
      else if (
        held.status !== r.status ||
        held.stopTriggered !== r.stopTriggered ||
        held.price !== r.price ||
        held.stopPrice !== r.stopPrice
      ) {
        stale++;
      }
    }
    let extra = 0;
    for (const id of this.where.keys()) if (!truth.has(id)) extra++;
    if (missing || stale || extra) this.load(rows);
    return { missing, stale, extra };
  }
}
