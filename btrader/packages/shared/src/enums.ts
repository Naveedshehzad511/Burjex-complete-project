// String-literal enums mirroring the Prisma schema so services and clients
// (mobile/admin) share one source of truth without importing @prisma/client.

export type OrderSide = 'BUY' | 'SELL';

export type OrderType =
  | 'MARKET'
  | 'LIMIT'
  | 'STOP'
  | 'STOP_LIMIT'
  | 'BUY_STOP'
  | 'SELL_STOP'
  | 'BUY_LIMIT'
  | 'SELL_LIMIT';

export type OrderStatus = 'PENDING' | 'PARTIAL' | 'FILLED' | 'CANCELLED' | 'REJECTED' | 'EXPIRED';

export type TimeInForce = 'GTC' | 'IOC' | 'FOK' | 'DAY' | 'GTD';

export type PositionStatus = 'OPEN' | 'CLOSED';

/** Execution book. A = STP (cover to LP). B = warehouse (broker is the house). */
export type BookType = 'A' | 'B';

export type HedgeStatus = 'PENDING' | 'FILLED' | 'REJECTED' | 'CLOSE_PENDING' | 'CLOSED';

export type LpExecDriver = 'MOCK' | 'PRIMEXM' | 'CENTROID' | 'ONEZERO' | 'MT5';

export type InstrumentClass =
  | 'FOREX'
  | 'METALS'
  | 'STOCKS'
  | 'INDICES'
  | 'CRYPTO'
  | 'COMMODITIES'
  | 'CUSTOM';

export type AccountStatus = 'ACTIVE' | 'TRADING_DISABLED' | 'READ_ONLY' | 'ARCHIVED';

export type AdjustmentType =
  | 'DEPOSIT'
  | 'WITHDRAWAL'
  | 'BONUS'
  | 'DIVIDEND'
  | 'CREDIT'
  | 'MANUAL'
  | 'CORRECTION';

export type DealType =
  | 'OPEN'
  | 'CLOSE'
  | 'PARTIAL_CLOSE'
  | 'BALANCE'
  | 'DEPOSIT'
  | 'WITHDRAWAL'
  | 'BONUS'
  | 'DIVIDEND'
  | 'SWAP'
  | 'COMMISSION'
  | 'CREDIT';

/** A "point" is the smallest price increment (10^-digits). A "pip" is the conventional unit. */
export const PENDING_ORDER_TYPES: OrderType[] = [
  'LIMIT',
  'STOP',
  'STOP_LIMIT',
  'BUY_STOP',
  'SELL_STOP',
  'BUY_LIMIT',
  'SELL_LIMIT',
];
