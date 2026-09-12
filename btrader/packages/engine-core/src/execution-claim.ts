/**
 * Latch + claim for protective SL/TP and pending triggers.
 *
 * Detection latches immediately. A later tick that reverses through the level
 * MUST NOT unclaim or re-arm. Two engine processes share the database claim;
 * in-memory latch is per-process only.
 */
import { protectiveHit, type Side } from './trigger';

export type ProtectiveKind = 'sl' | 'tp';

export interface ProtectiveLatch {
  claimed: boolean;
  closed: boolean;
  kind: ProtectiveKind | null;
  level: number | null;
  triggerWall: number;
  bid: number;
  ask: number;
}

export function emptyLatch(): ProtectiveLatch {
  return { claimed: false, closed: false, kind: null, level: null, triggerWall: 0, bid: 0, ask: 0 };
}

/**
 * Apply one Bid/Ask tick to a position's protective state.
 * Once claimed, further ticks (including reversals) are ignored until close.
 */
export function applyProtectiveTick(
  state: ProtectiveLatch,
  args: { side: Side; bid: number; ask: number; sl?: number | null; tp?: number | null },
  nowWall = Date.now(),
): ProtectiveLatch {
  if (state.closed || state.claimed) return state;
  const hit = protectiveHit(args);
  if (!hit.hit) return state;
  return {
    claimed: true,
    closed: false,
    kind: hit.hit === 'SL' ? 'sl' : 'tp',
    level: hit.level,
    triggerWall: nowWall,
    bid: args.bid,
    ask: args.ask,
  };
}

export type ClaimResult = 'claimed' | 'already_claimed' | 'already_closed';

export interface PositionClaimRecord {
  kind: string;
  claimedBy: string;
  triggerWall: number;
  triggerMono?: number;
  deadlineWall: number;
  delayMs: number;
  bid?: number;
  ask?: number;
  level?: number | null;
}

/** Single-process atomic claim map — used by tests and as a first-line in-memory latch. */
export class MemoryClaimStore<T = PositionClaimRecord> {
  private readonly m = new Map<string, T>();

  claim(id: string, data: T): ClaimResult {
    if (this.m.has(id)) return 'already_claimed';
    this.m.set(id, data);
    return 'claimed';
  }

  get(id: string): T | undefined {
    return this.m.get(id);
  }

  has(id: string): boolean {
    return this.m.has(id);
  }

  release(id: string): void {
    this.m.delete(id);
  }

  markClosed(id: string): void {
    this.m.delete(id);
  }

  get size(): number {
    return this.m.size;
  }
}

/**
 * Simulate two workers racing a claim against one store.
 * Exactly one 'claimed'; the rest are 'already_claimed'. Never two claimed.
 */
export function raceClaims(store: MemoryClaimStore, id: string, n: number, kind: string): ClaimResult[] {
  const out: ClaimResult[] = [];
  for (let i = 0; i < n; i++) {
    out.push(
      store.claim(id, {
        kind,
        claimedBy: `w${i}`,
        triggerWall: Date.now(),
        deadlineWall: Date.now(),
        delayMs: 0,
      }),
    );
  }
  return out;
}
