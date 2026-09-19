/** Client-position lifecycle. Not HedgeStatus / MT5 CLOSE_PENDING. */

export type PosLifecycle = 'OPEN' | 'CLOSE_PENDING' | 'CLOSED';

export function parseLifecycle(status: unknown): PosLifecycle {
  const s = String(status ?? '').toUpperCase();
  if (s === 'CLOSE_PENDING') return 'CLOSE_PENDING';
  if (s === 'CLOSED') return 'CLOSED';
  return 'OPEN';
}

export function onProtectiveHit(status: unknown): 'claim' | 'ignore' {
  return parseLifecycle(status) === 'OPEN' ? 'claim' : 'ignore';
}

export function onProtectiveClose(status: unknown): 'close' | 'ignore' {
  return parseLifecycle(status) === 'CLOSED' ? 'ignore' : 'close';
}

export function onUserClose(status: unknown): 'close' | 'ignore' {
  return parseLifecycle(status) === 'OPEN' ? 'close' : 'ignore';
}

export function statusRank(status: unknown): number {
  const s = parseLifecycle(status);
  if (s === 'CLOSED') return 3;
  if (s === 'CLOSE_PENDING') return 2;
  return 1;
}

export function preferStatus(prev: unknown, next: unknown): PosLifecycle {
  return statusRank(next) >= statusRank(prev) ? parseLifecycle(next) : parseLifecycle(prev);
}

export function staleOpenBlocked(id: string, status: unknown, closedIds: Iterable<string>): boolean {
  if (!id) return false;
  if (parseLifecycle(status) !== 'OPEN') return false;
  const set = closedIds instanceof Set ? closedIds : new Set(closedIds);
  return set.has(id);
}
