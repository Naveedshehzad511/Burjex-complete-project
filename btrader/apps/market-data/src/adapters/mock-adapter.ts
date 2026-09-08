import { LpBridgeAdapter, RawTick } from '@btrader/shared';

/**
 * Mock LP bridge — generates a random-walk feed so the platform runs end-to-end
 * without a real liquidity provider. Swap for generic-ws / FIX adapters in prod.
 */
export class MockAdapter implements LpBridgeAdapter {
  readonly name = 'mock';
  private timer?: NodeJS.Timeout;
  private connected = false;
  private symbols = new Set<string>();
  private last = new Map<string, number>();
  private tickHandler?: (t: RawTick) => void;
  private statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  private seed: Record<string, number> = {
    EURUSD: 1.1, GBPUSD: 1.27, XAUUSD: 2350, BTCUSD: 68000, USDJPY: 157,
  };

  async connect(): Promise<void> {
    this.connected = true;
    this.statusHandler?.('connected');
    this.timer = setInterval(() => this.emit(), 250); // 4 ticks/sec/symbol
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    if (this.timer) clearInterval(this.timer);
    this.statusHandler?.('disconnected');
  }

  async subscribe(symbols: string[]): Promise<void> {
    symbols.forEach((s) => this.symbols.add(s));
  }
  async unsubscribe(symbols: string[]): Promise<void> {
    symbols.forEach((s) => this.symbols.delete(s));
  }

  onTick(handler: (t: RawTick) => void): void {
    this.tickHandler = handler;
  }
  onStatus(handler: (s: 'connected' | 'disconnected' | 'error', d?: string) => void): void {
    this.statusHandler = handler;
  }
  isConnected(): boolean {
    return this.connected;
  }

  private emit(): void {
    for (const symbol of this.symbols) {
      const base = this.last.get(symbol) ?? this.seed[symbol] ?? 100;
      const vol = base * 0.0002;
      const mid = base + (Math.random() - 0.5) * vol;
      this.last.set(symbol, mid);
      const spread = mid * 0.00008;
      this.tickHandler?.({
        symbol,
        bid: mid - spread / 2,
        ask: mid + spread / 2,
        ts: Date.now(),
        source: this.name,
      });
    }
  }
}
