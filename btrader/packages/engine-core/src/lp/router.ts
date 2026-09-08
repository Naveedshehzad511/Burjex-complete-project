import {
  LpExecutionAdapter,
  LpOrderRequest,
  LpOrderResult,
  LpCloseResult,
  LpExecDriver,
} from '@btrader/shared';
import { MockLpAdapter } from './mock-lp-adapter';
import { PrimeXmAdapter, CentroidAdapter, OneZeroAdapter, LpConn } from './provider-adapters';

export interface TenantLpConfig {
  driver: LpExecDriver;
  enabled: boolean;
  conn?: LpConn;
  simSlippageBps?: number;
  simRejectPct?: number;
}

interface Entry {
  adapter: LpExecutionAdapter;
  enabled: boolean;
  tenantId: string;
}

/**
 * Stable key for an execution venue. A provider-linked config keys by provider
 * id (so two same-driver MT5 venues stay distinct); a legacy config keys by
 * (tenant, driver). The engine and the loader MUST agree on this.
 */
export function venueKeyFor(tenantId: string, lpProviderId: string | null | undefined, driver: LpExecDriver): string {
  return lpProviderId ? `p:${lpProviderId}` : `d:${tenantId}:${driver}`;
}

/**
 * Per-(tenant, venue) registry of A-book execution bridges. A tenant may run
 * MULTIPLE LP venues at once (e.g. metals → PRIMEXM, FX → ONEZERO); the Routing
 * Rules layer picks which driver covers each order and the engine passes it to
 * route()/close(). The gateway configures one adapter per LpExecutionConfig row
 * (and refreshes on change).
 *
 * If the requested venue has no enabled bridge, route() returns { accepted:false,
 * reason:'no-lp' } so the engine can warehouse the position and raise an
 * exposure alert instead of silently leaving the broker uncovered.
 */
export class LpExecutionRouter {
  private readonly entries = new Map<string, Entry>();

  /** (Re)configure one venue by its stable key. Pass cfg=null to remove it. */
  async configure(venueKey: string, tenantId: string, cfg: TenantLpConfig | null): Promise<void> {
    const existing = this.entries.get(venueKey);
    if (existing) {
      await existing.adapter.disconnect().catch(() => undefined);
      this.entries.delete(venueKey);
    }
    if (!cfg) return;
    const adapter = buildLpAdapter(cfg);
    if (cfg.enabled) await adapter.connect().catch(() => undefined);
    this.entries.set(venueKey, { adapter, enabled: cfg.enabled, tenantId });
  }

  /** Remove every venue configured for a tenant (e.g. tenant deleted/disabled). */
  async clearTenant(tenantId: string): Promise<void> {
    for (const [k, e] of this.entries) {
      if (e.tenantId !== tenantId) continue;
      await e.adapter.disconnect().catch(() => undefined);
      this.entries.delete(k);
    }
  }

  hasBridge(venueKey: string): boolean {
    const e = this.entries.get(venueKey);
    return !!e && e.enabled && e.adapter.isConnected();
  }

  async route(venueKey: string, req: LpOrderRequest): Promise<LpOrderResult> {
    const e = this.entries.get(venueKey);
    if (!e || !e.enabled) return { accepted: false, rejectReason: 'no-lp' };
    if (!e.adapter.isConnected()) await e.adapter.connect().catch(() => undefined);
    const timeoutMs = Math.max(250, Number(process.env.LP_ROUTE_TIMEOUT_MS ?? 5000));
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const timedOut = new Promise<LpOrderResult>((resolve) => {
        timer = setTimeout(
          () => resolve({ accepted: false, rejectReason: `lp timeout after ${timeoutMs}ms` }),
          timeoutMs,
        );
      });
      return await Promise.race([e.adapter.placeOrder(req), timedOut]);
    } catch (err) {
      return { accepted: false, rejectReason: (err as Error).message };
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  async close(venueKey: string, externalRef: string, referencePrice: number): Promise<LpCloseResult> {
    const e = this.entries.get(venueKey);
    if (!e || !e.enabled) return { accepted: false, rejectReason: 'no-lp' };
    try {
      return await e.adapter.closeOrder(externalRef, referencePrice);
    } catch (err) {
      return { accepted: false, rejectReason: (err as Error).message };
    }
  }
}

export function buildLpAdapter(cfg: TenantLpConfig): LpExecutionAdapter {
  switch (cfg.driver) {
    case 'PRIMEXM':
      return new PrimeXmAdapter(cfg.conn ?? {});
    case 'CENTROID':
      return new CentroidAdapter(cfg.conn ?? {});
    case 'ONEZERO':
      return new OneZeroAdapter(cfg.conn ?? {});
    case 'MOCK':
    default:
      return new MockLpAdapter({ slippageBps: cfg.simSlippageBps, rejectPct: cfg.simRejectPct });
  }
}
