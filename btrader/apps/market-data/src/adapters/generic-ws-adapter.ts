import WebSocket from 'ws';
import { LpBridgeAdapter, RawTick } from '@btrader/shared';

/**
 * Generic WebSocket LP bridge adapter. Connects to an upstream price stream,
 * auto-reconnects with backoff, and normalizes the upstream message shape into
 * RawTick. Adjust `parse()` and `subscribeFrame()` per provider (PrimeXM,
 * oneZero, B2Broker, cTrader Open API, Binance, etc.).
 */
export class GenericWsAdapter implements LpBridgeAdapter {
  readonly name = 'generic-ws';
  private ws?: WebSocket;
  private connected = false;
  private symbols = new Set<string>();
  private backoff = 500;
  private tickHandler?: (t: RawTick) => void;
  private statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  constructor(
    private readonly url: string,
    private readonly apiKey?: string,
  ) {}

  async connect(): Promise<void> {
    this.open();
  }

  private open(): void {
    this.ws = new WebSocket(this.url, {
      headers: this.apiKey ? { Authorization: `Bearer ${this.apiKey}` } : undefined,
    });
    this.ws.on('open', () => {
      this.connected = true;
      this.backoff = 500;
      this.statusHandler?.('connected');
      if (this.symbols.size) this.send(this.subscribeFrame([...this.symbols]));
    });
    this.ws.on('message', (data) => {
      const tick = this.parse(data.toString());
      if (tick) this.tickHandler?.(tick);
    });
    this.ws.on('close', () => {
      this.connected = false;
      this.statusHandler?.('disconnected');
      this.reconnect();
    });
    this.ws.on('error', (err) => {
      this.statusHandler?.('error', err.message);
    });
  }

  private reconnect(): void {
    this.backoff = Math.min(this.backoff * 2, 15000);
    setTimeout(() => this.open(), this.backoff);
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    this.ws?.removeAllListeners();
    this.ws?.close();
  }

  async subscribe(symbols: string[]): Promise<void> {
    symbols.forEach((s) => this.symbols.add(s));
    if (this.connected) this.send(this.subscribeFrame(symbols));
  }
  async unsubscribe(symbols: string[]): Promise<void> {
    symbols.forEach((s) => this.symbols.delete(s));
  }

  onTick(h: (t: RawTick) => void): void {
    this.tickHandler = h;
  }
  onStatus(h: (s: 'connected' | 'disconnected' | 'error', d?: string) => void): void {
    this.statusHandler = h;
  }
  isConnected(): boolean {
    return this.connected;
  }

  private send(obj: unknown): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(obj));
  }

  // ── Provider-specific (override per bridge) ────────────────────────────────
  private subscribeFrame(symbols: string[]): unknown {
    return { op: 'subscribe', channel: 'quotes', symbols };
  }

  private parse(raw: string): RawTick | null {
    try {
      const m = JSON.parse(raw);
      if (m.symbol && m.bid != null && m.ask != null) {
        return { symbol: m.symbol, bid: Number(m.bid), ask: Number(m.ask), ts: m.ts ?? Date.now(), source: this.name };
      }
      return null;
    } catch {
      return null;
    }
  }
}
