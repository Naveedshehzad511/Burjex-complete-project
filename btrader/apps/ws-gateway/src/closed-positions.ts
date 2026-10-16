/**
 * Positions the engine has reported CLOSED, so a later non-closed update for one of them is dropped.
 *
 * The engine's live P/L loop works from a copy of the open book, so an OPEN snapshot taken just before a
 * close can be published just after the close event. Forwarded, it either replaced the close in a client's
 * flush window (one entry per position id, last write wins) and the client never learned of the close, or
 * it arrived after the close and painted the trade as live again. A position id never reopens, so a close
 * is final; ids are only remembered for [ttlMs], long enough to outlive any update still in flight.
 */
export class ClosedPositions {
  private closedAt = new Map<string, number>();

  constructor(
    private readonly ttlMs = 120_000,
    private readonly now: () => number = Date.now,
  ) {}

  /** Records a close; for any other update, true when the position was already reported closed. */
  isStale(key: string, closed: boolean): boolean {
    const t = this.now();
    if (closed) {
      this.closedAt.set(key, t);
      if (this.closedAt.size > 1024) this.prune(t);
      return false;
    }
    const at = this.closedAt.get(key);
    if (at === undefined) return false;
    if (t - at < this.ttlMs) return true;
    this.closedAt.delete(key);
    return false;
  }

  get size(): number {
    return this.closedAt.size;
  }

  private prune(t: number): void {
    for (const [k, at] of this.closedAt) {
      if (t - at >= this.ttlMs) this.closedAt.delete(k);
    }
  }
}
