import { AccountSnapshot, OrderDTO, PositionDTO } from './trading';
import { Tick } from './market-data';

/**
 * Internal event bus contract (Redis Streams / pub-sub). All inter-service
 * messages are tenant-scoped: stream key = `bt:{tenantId}:{channel}`.
 */
export const Channels = {
  TICKS: 'ticks',
  /**
   * Server-authoritative chart bars. Carries only the bar that changed, never
   * the whole series — see CandleEvent.
   */
  CANDLES: 'candles',
  ORDERS: 'orders',
  POSITIONS: 'positions',
  ACCOUNTS: 'accounts',
  ENGINE_CMD: 'engine.cmd',
  ENGINE_EVT: 'engine.evt',
  /** Admin group/config invalidation (not tenant-scoped). */
  ENGINE_CFG: 'engine.cfg',
} as const;

/**
 * `created` — first sighting of this bar.
 * `updated` — same bar, new high/low/close.
 * `closed`  — bar finalized; its values never change again.
 *
 * Clients upsert on identity (symbol + tf + t) regardless of kind, so a missed
 * `created` is self-healing: an `updated` for an unknown bar simply inserts it.
 */
export type CandleEventKind = 'created' | 'updated' | 'closed';

/**
 * One chart bar, already transformed into the receiving tenant's visible price.
 *
 * `t` is the bucket open time in epoch SECONDS, matching the REST history
 * endpoint and the client's own bucket maths.
 */
export interface CandleEvent {
  kind: CandleEventKind;
  symbol: string;
  tf: string;
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  v: number;
}

export type EngineCommand =
  | { kind: 'PLACE_ORDER'; tenantId: string; payload: unknown; corrId: string }
  | { kind: 'MODIFY_POSITION'; tenantId: string; positionId: string; sl?: number | null; tp?: number | null; corrId: string }
  | { kind: 'CLOSE_POSITION'; tenantId: string; positionId: string; volume?: number; corrId: string }
  | { kind: 'CLOSE_ALL'; tenantId: string; accountId: string; corrId: string }
  | { kind: 'CANCEL_ORDER'; tenantId: string; orderId: string; corrId: string };

export type EngineEvent =
  | { kind: 'ORDER_UPDATE'; tenantId: string; order: OrderDTO }
  | { kind: 'POSITION_UPDATE'; tenantId: string; position: PositionDTO }
  | { kind: 'ACCOUNT_UPDATE'; tenantId: string; account: AccountSnapshot }
  | { kind: 'MARGIN_CALL'; tenantId: string; accountId: string; marginLevel: number }
  | { kind: 'STOP_OUT'; tenantId: string; accountId: string; positionId: string };

/** Client-facing WS frames (mobile/admin subscribe to these). */
export type WsFrame =
  | { t: 'tick'; d: Tick }
  | { t: 'candle'; d: CandleEvent }
  | { t: 'account'; d: AccountSnapshot }
  | { t: 'position'; d: PositionDTO }
  | { t: 'order'; d: OrderDTO }
  | { t: 'pong'; d: { ts: number } };
