/**
 * WS position close-sync helpers.
 * CLOSED / position_closed bypasses event batching; OPEN must not resurrect.
 */

export function posIdOf(body: unknown): string {
  const p = body as { id?: unknown; positionId?: unknown } | null;
  return String(p?.id ?? p?.positionId ?? '');
}

export function payloadClosed(obj: unknown): boolean {
  if (!obj || typeof obj !== 'object') return false;
  const p = obj as Record<string, unknown>;
  const st = String(p.status ?? '').toUpperCase();
  const book = String(p.book ?? '').toLowerCase();
  const reason = String(p.reason ?? '').toUpperCase();
  const stateVal = String(p.state ?? '').toLowerCase();
  const event = String(p.event ?? '').toLowerCase();
  if (st === 'CLOSE_PENDING') return false;
  return (
    event === 'position_closed' ||
    p.closing === true ||
    st === 'CLOSED' ||
    book === 'closed' ||
    stateVal === 'closed' ||
    reason === 'SL_HIT' ||
    reason === 'TP_HIT'
  );
}

export function statusRank(obj: unknown): number {
  if (payloadClosed(obj)) return 3;
  const st = String((obj as { status?: unknown } | null)?.status ?? '').toUpperCase();
  if (st === 'CLOSE_PENDING') return 2;
  return 1;
}

export function forceClosed(body: unknown, id: string): Record<string, unknown> {
  const prev = body && typeof body === 'object' ? (body as Record<string, unknown>) : {};
  return {
    ...prev,
    id: prev.id ?? id,
    positionId: prev.positionId ?? prev.id ?? id,
    status: 'CLOSED',
    book: 'closed',
    closing: true,
    event: 'position_closed',
  };
}

export function coalescePosition(
  prev: unknown,
  next: unknown,
  stillClosed: (id: string) => boolean,
  rememberClosed: (id: string) => void,
): unknown {
  const id = posIdOf(next) || posIdOf(prev);
  if (!id) return next;
  const nextClosed = payloadClosed(next);
  const prevClosed = payloadClosed(prev);
  if (nextClosed || stillClosed(id) || prevClosed) {
    rememberClosed(id);
    return forceClosed(nextClosed ? next : prevClosed ? prev : next, id);
  }
  if (stillClosed(id)) {
    rememberClosed(id);
    return forceClosed(next, id);
  }
  if (statusRank(prev) > statusRank(next)) return prev;
  return next;
}

export function reconcileOpenSnapshot<T extends { id: string; status?: string }>(
  snapshot: T[] | null | undefined,
  closedIds: Iterable<string>,
): T[] {
  if (!snapshot) return [];
  const closed = closedIds instanceof Set ? closedIds : new Set(closedIds);
  return snapshot.filter((p) => {
    if (!p?.id || closed.has(p.id)) return false;
    const st = String(p.status ?? 'OPEN').toUpperCase();
    return st === 'OPEN' || st === 'CLOSE_PENDING';
  });
}

export function overlayDropsChart(id: string, payload: unknown, closedIds: Iterable<string>): boolean {
  if (!id) return false;
  const closed = closedIds instanceof Set ? closedIds : new Set(closedIds);
  if (closed.has(id)) return true;
  return payloadClosed(payload);
}

export function openPositionsRedisKey(tenantId: string, accountId: string): string {
  return `bt:${tenantId}:openpos:${accountId}`;
}
