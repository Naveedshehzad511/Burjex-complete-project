import { LpBridgeAdapter, RawTick } from '@btrader/shared';

/**
 * No-op price feed. Used when no real LP/MT5 driver is configured.
 *
 * It "connects" so the service stays healthy, but it NEVER emits a tick — so
 * the platform distributes no prices at all and Market Watch stays empty. This
 * is deliberate: a trading platform must never show fabricated/mock prices when
 * the real feed is absent. Set LP_BRIDGE_DRIVER=mt5-ingest (or generic-ws) to
 * take a real feed; mock is only used when explicitly set to LP_BRIDGE_DRIVER=mock.
 */
export class NullAdapter implements LpBridgeAdapter {
  readonly name = 'none';
  private connected = false;
  private statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  async connect(): Promise<void> {
    this.connected = true;
    this.statusHandler?.('connected', 'no LP driver configured — feed idle, no prices distributed');
  }
  async disconnect(): Promise<void> {
    this.connected = false;
    this.statusHandler?.('disconnected');
  }
  async subscribe(): Promise<void> {}
  async unsubscribe(): Promise<void> {}
  onTick(_handler: (tick: RawTick) => void): void {}
  onStatus(h: (status: 'connected' | 'disconnected' | 'error', detail?: string) => void): void {
    this.statusHandler = h;
  }
  isConnected(): boolean {
    return this.connected;
  }
}
