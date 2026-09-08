import {
  LpExecutionAdapter,
  LpOrderRequest,
  LpOrderResult,
  LpCloseResult,
} from '@btrader/shared';

export interface MockLpOptions {
  /** Basis points of slippage applied to cover fills (positive = worse for broker). */
  slippageBps?: number;
  /** Percentage (0-100) of cover orders to reject — exercises the exposure-alert path. */
  rejectPct?: number;
  /** Simulated LP delay; router timeout still applies on top. */
  delayMs?: number;
}

/**
 * Simulated A-book bridge. Fills cover orders instantly at the reference price
 * (plus optional configurable slippage) so the whole STP path runs end-to-end
 * with no real liquidity provider. Swap for a real FIX/REST adapter in prod —
 * the engine and router are unchanged.
 */
export class MockLpAdapter implements LpExecutionAdapter {
  readonly driver = 'MOCK' as const;
  private connected = false;
  private seq = 0;
  private statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  constructor(private readonly opts: MockLpOptions = {}) {}

  async connect(): Promise<void> {
    this.connected = true;
    this.statusHandler?.('connected', 'mock bridge ready');
  }
  async disconnect(): Promise<void> {
    this.connected = false;
    this.statusHandler?.('disconnected');
  }
  isConnected(): boolean {
    return this.connected;
  }
  onStatus(h: (s: 'connected' | 'disconnected' | 'error', d?: string) => void): void {
    this.statusHandler = h;
  }

  async placeOrder(req: LpOrderRequest): Promise<LpOrderResult> {
    if (!this.connected) return { accepted: false, rejectReason: 'lp disconnected' };
    if (this.opts.delayMs) await new Promise((r) => setTimeout(r, this.opts.delayMs));
    if (!this.connected) return { accepted: false, rejectReason: 'lp disconnected' };
    if (this.shouldReject()) return { accepted: false, rejectReason: 'lp rejected (simulated)' };
    const slip = (this.opts.slippageBps ?? 0) / 10_000;
    // A BUY cover is filled slightly higher (worse), a SELL cover slightly lower.
    const dir = req.side === 'BUY' ? 1 : -1;
    const fillPrice = round(req.referencePrice * (1 + dir * slip), req.digits);
    return { accepted: true, externalRef: `MOCK-${Date.now()}-${++this.seq}`, fillPrice };
  }

  async closeOrder(_externalRef: string, referencePrice: number): Promise<LpCloseResult> {
    if (!this.connected) return { accepted: false, rejectReason: 'lp disconnected' };
    return { accepted: true, closePrice: referencePrice };
  }

  private shouldReject(): boolean {
    const pct = this.opts.rejectPct ?? 0;
    return pct > 0 && Math.random() * 100 < pct;
  }
}

function round(v: number, digits: number): number {
  const f = Math.pow(10, digits);
  return Math.round(v * f) / f;
}
