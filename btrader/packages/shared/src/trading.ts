import { OrderSide, OrderType, OrderStatus, TimeInForce, PositionStatus } from './enums';

/** Account money snapshot — the exact set of fields the mobile app + CRM display. */
export interface AccountSnapshot {
  accountId: string;
  login: string;
  currency: string;
  leverage: number;
  balance: number;
  credit: number; // bonus/credit
  equity: number; // balance + credit + floatingPL
  margin: number; // used margin
  freeMargin: number; // equity - margin
  marginLevel: number; // equity / margin * 100 (%)
  floatingPL: number;
  closedPL: number; // realized P/L lifetime (optional rollup)
  bonus: number;
  dividend: number;
  ts: number;
}

export interface PlaceOrderRequest {
  accountId: string;
  symbol: string;
  side: OrderSide;
  type: OrderType;
  volume: number; // lots
  price?: number; // limit price
  stopPrice?: number; // stop trigger
  slPrice?: number;
  tpPrice?: number;
  timeInForce?: TimeInForce;
  expiresAt?: string; // ISO, for GTD
  comment?: string;
  /** One-click trading sets this; engine applies symbol slippage tolerance. */
  oneClick?: boolean;
  source?: 'mobile' | 'admin' | 'crm' | 'api';
  /** Idempotency key. Repeat POST with the same key returns the original order. */
  clientOrderId?: string;
}

export interface OrderDTO {
  id: string;
  accountId: string;
  symbol: string;
  side: OrderSide;
  type: OrderType;
  status: OrderStatus;
  volume: number;
  filledVolume: number;
  price?: number;
  stopPrice?: number;
  slPrice?: number;
  tpPrice?: number;
  avgFillPrice?: number;
  rejectReason?: string;
  positionId?: string;
  createdAt: string;
  filledAt?: string;
  triggeredAt?: string;
  clientOrderId?: string;
}

export interface PositionDTO {
  id: string;
  accountId: string;
  symbol: string;
  side: OrderSide;
  status: PositionStatus;
  volume: number;
  openPrice: number;
  currentPrice?: number;
  closePrice?: number;
  slPrice?: number;
  tpPrice?: number;
  marginUsed: number;
  swap: number;
  commission: number;
  profit: number; // floating while OPEN, realized when CLOSED
  comment?: string;
  openedAt: string;
  closedAt?: string;
}

export interface ModifyPositionRequest {
  slPrice?: number | null;
  tpPrice?: number | null;
}

export interface ClosePositionRequest {
  /** Omit volume → full close. Provide < position.volume → partial close. */
  volume?: number;
  price?: number; // optional requested price (one-click)
}

/** Result of an execution attempt returned synchronously to the caller. */
export interface ExecutionResult {
  accepted: boolean;
  orderId?: string;
  positionId?: string;
  status: OrderStatus;
  fillPrice?: number;
  filledVolume?: number;
  reason?: string;
  account?: AccountSnapshot;
}
