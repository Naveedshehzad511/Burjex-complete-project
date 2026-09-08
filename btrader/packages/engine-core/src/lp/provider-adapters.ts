import {
  LpExecutionAdapter,
  LpOrderRequest,
  LpOrderResult,
  LpCloseResult,
  LpExecDriver,
} from '@btrader/shared';

// ============================================================================
//  REAL LP EXECUTION ADAPTERS — drop-in skeletons.
//
//  Each provider exposes order routing over FIX 4.4 (PrimeXM, oneZero) or a
//  REST/WebSocket gateway (Centroid). Implement connect()/placeOrder()/
//  closeOrder() against the provider's session and the engine works unchanged.
//
//  Credentials are passed in from LpExecutionConfig (endpoint + comp ids) and a
//  secret resolved from the secret store via credentialRef — never hardcoded.
// ============================================================================

export interface LpConn {
  endpoint?: string | null;
  senderCompId?: string | null;
  targetCompId?: string | null;
  secret?: string | null; // resolved from credentialRef by the caller
}

abstract class BaseFixAdapter implements LpExecutionAdapter {
  abstract readonly driver: LpExecDriver;
  protected connected = false;
  protected statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  constructor(protected readonly conn: LpConn) {}

  abstract connect(): Promise<void>;

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

  abstract placeOrder(req: LpOrderRequest): Promise<LpOrderResult>;
  abstract closeOrder(externalRef: string, referencePrice: number): Promise<LpCloseResult>;

  protected notImplemented(): never {
    throw new Error(
      `${this.driver} execution adapter not implemented yet — connect FIX/REST session in provider-adapters.ts`,
    );
  }
}

/**
 * PrimeXM XCore — FIX 4.4 order routing. Implement a FIX session (e.g. via a FIX
 * engine), map LpOrderRequest -> NewOrderSingle (35=D), handle ExecutionReport
 * (35=8) for fills/rejects, and OrderCancelRequest for closes.
 */
export class PrimeXmAdapter extends BaseFixAdapter {
  readonly driver = 'PRIMEXM' as const;
  async connect(): Promise<void> {
    // TODO: open FIX session to this.conn.endpoint with sender/target comp ids.
    this.notImplemented();
  }
  async placeOrder(_req: LpOrderRequest): Promise<LpOrderResult> {
    this.notImplemented();
  }
  async closeOrder(_ref: string, _price: number): Promise<LpCloseResult> {
    this.notImplemented();
  }
}

/**
 * Centroid Bridge — REST/WebSocket order API. Implement HTTP auth + order POST,
 * poll or stream fills, map status to LpOrderResult.
 */
export class CentroidAdapter extends BaseFixAdapter {
  readonly driver = 'CENTROID' as const;
  async connect(): Promise<void> {
    this.notImplemented();
  }
  async placeOrder(_req: LpOrderRequest): Promise<LpOrderResult> {
    this.notImplemented();
  }
  async closeOrder(_ref: string, _price: number): Promise<LpCloseResult> {
    this.notImplemented();
  }
}

/**
 * oneZero EcoSystem — FIX 4.4 order routing (similar to PrimeXM). Map to
 * NewOrderSingle / ExecutionReport on the trading session.
 */
export class OneZeroAdapter extends BaseFixAdapter {
  readonly driver = 'ONEZERO' as const;
  async connect(): Promise<void> {
    this.notImplemented();
  }
  async placeOrder(_req: LpOrderRequest): Promise<LpOrderResult> {
    this.notImplemented();
  }
  async closeOrder(_ref: string, _price: number): Promise<LpCloseResult> {
    this.notImplemented();
  }
}
