/**
 * Authoritative execution-delay / deadline policy.
 *
 * One place computes `trigger + group.executionDelayMs`. Individual paths
 * MUST call waitForDeadline(plan) instead of sleep(N) / sleep(200).
 * If the caller is already past the deadline (queue wait, slow tick), remaining
 * wait is 0 — the clock is never restarted.
 */
import {
  executionApplies,
  marketExecutionDelayMs,
  sleepUntil,
  type ExecutionApplyKind,
  type GroupPricing,
} from './calc';

export { executionApplies, marketExecutionDelayMs, sleepUntil };
export type { ExecutionApplyKind };

/** Process identity for claim rows and audit (not a secret). */
export const ENGINE_INSTANCE_ID =
  process.env.ENGINE_INSTANCE_ID ||
  `${process.env.HOSTNAME ?? process.env.COMPUTERNAME ?? 'eng'}-${process.pid}`;

export type ExecutionMode = 'MARKET' | 'INSTANT';

export interface ExecutionPlan {
  kind: ExecutionApplyKind;
  mode: ExecutionMode;
  /** Configured delay actually applied (0 if Instant or apply-to is off). */
  delayMs: number;
  /** Monotonic ms (performance.now) at the trigger/request. */
  triggerMono: number;
  /** Wall-clock Date.now() at the trigger/request (audit). */
  triggerWall: number;
  deadlineMono: number;
  deadlineWall: number;
  groupId?: string | null;
}

export function captureTrigger(nowMono = performance.now(), nowWall = Date.now()): {
  triggerMono: number;
  triggerWall: number;
} {
  return { triggerMono: nowMono, triggerWall: nowWall };
}

/**
 * Build the one deadline this execution may wait for.
 * INSTANT mode never waits (honours the level/click). MARKET waits only when
 * apply-to includes `kind`. The delay value is always the live group field —
 * never a hard-coded constant.
 */
export function createExecutionPlan(args: {
  pricing: Pick<GroupPricing, 'executionMode' | 'executionDelayMs' | 'executionApplyTo'> | null | undefined;
  kind: ExecutionApplyKind;
  triggerMono?: number;
  triggerWall?: number;
  groupId?: string | null;
}): ExecutionPlan {
  const triggerMono = args.triggerMono ?? performance.now();
  const triggerWall = args.triggerWall ?? Date.now();
  const mode: ExecutionMode =
    (args.pricing?.executionMode ?? 'MARKET') === 'INSTANT' ? 'INSTANT' : 'MARKET';
  const delayMs = marketExecutionDelayMs(args.pricing, args.kind);
  return {
    kind: args.kind,
    mode,
    delayMs,
    triggerMono,
    triggerWall,
    deadlineMono: triggerMono + delayMs,
    deadlineWall: triggerWall + delayMs,
    groupId: args.groupId ?? null,
  };
}

/** Sleep until the original deadline. No-op when already late. Never adds a second delay. */
export async function waitForDeadline(plan: ExecutionPlan | null | undefined): Promise<number> {
  if (!plan || !(plan.delayMs > 0)) return 0;
  const before = performance.now();
  await sleepUntil(plan.deadlineMono);
  return Math.max(0, performance.now() - before);
}

export function metricLabel(
  kind: ExecutionApplyKind | 'stopOut' | 'dealer',
  phase: 'trigger_to_commit' | 'trigger_to_exec' | 'request_to_exec' | 'commit_to_emit',
): string {
  return `exec.${kind}.${phase}`;
}

export function closeApplyKind(args: {
  protectiveKind?: 'sl' | 'tp';
  closeAll?: boolean;
  stopOut?: boolean;
  dealer?: boolean;
}): ExecutionApplyKind | null {
  if (args.stopOut || args.dealer) return null;
  if (args.protectiveKind) return args.protectiveKind;
  if (args.closeAll) return 'closeAll';
  return 'manualClose';
}

export function auditComment(plan: ExecutionPlan | undefined, extra: Record<string, unknown>): string {
  const body = {
    exec: plan?.kind ?? extra.kind ?? 'unknown',
    delayMs: plan?.delayMs ?? 0,
    triggerWall: plan?.triggerWall,
    deadlineWall: plan?.deadlineWall,
    engine: ENGINE_INSTANCE_ID,
    ...extra,
  };
  return JSON.stringify(body).slice(0, 480);
}
