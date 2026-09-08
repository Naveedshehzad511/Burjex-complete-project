/** Normalized tick produced by the LP bridge adapter and fanned out to clients. */
export interface Tick {
  symbol: string;
  bid: number;
  ask: number;
  ts: number; // epoch ms
}

/** Raw bridge tick before tenant markup/filtering is applied. */
export interface RawTick {
  symbol: string;
  bid: number;
  ask: number;
  ts: number;
  source: string;
  /** Tenant that owns the source provider (multi-source feeds). Null = legacy
   *  tenant-agnostic feed that fans out to all tenants with the symbol. */
  tenantId?: string | null;
  /** Provider sequence when the feed supplies one — used to detect gaps. */
  sequence?: number;
}

export interface SymbolSpec {
  symbol: string;
  description?: string;
  class: string;
  digits: number;
  pipSize: number;
  contractSize: number;
  minLot: number;
  maxLot: number;
  lotStep: number;
  enabled: boolean;
}

/** Contract the LP bridge adapter must implement. New bridges = new adapter. */
export interface LpBridgeAdapter {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  /** Subscribe to a set of upstream symbols. */
  subscribe(symbols: string[]): Promise<void>;
  unsubscribe(symbols: string[]): Promise<void>;
  /** Register a handler invoked on every raw tick. */
  onTick(handler: (tick: RawTick) => void): void;
  onStatus(handler: (status: 'connected' | 'disconnected' | 'error', detail?: string) => void): void;
  isConnected(): boolean;
}
