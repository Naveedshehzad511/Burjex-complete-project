/** Canonical, stable error codes returned by the API and engine. */
export enum BtErrorCode {
  // auth
  UNAUTHORIZED = 'BT_UNAUTHORIZED',
  FORBIDDEN = 'BT_FORBIDDEN',
  INVALID_SIGNATURE = 'BT_INVALID_SIGNATURE',
  IP_NOT_ALLOWED = 'BT_IP_NOT_ALLOWED',
  RATE_LIMITED = 'BT_RATE_LIMITED',
  // tenancy
  TENANT_NOT_FOUND = 'BT_TENANT_NOT_FOUND',
  TENANT_SUSPENDED = 'BT_TENANT_SUSPENDED',
  // trading
  SYMBOL_DISABLED = 'BT_SYMBOL_DISABLED',
  MARKET_CLOSED = 'BT_MARKET_CLOSED',
  INVALID_VOLUME = 'BT_INVALID_VOLUME',
  INVALID_PRICE = 'BT_INVALID_PRICE',
  STOPS_TOO_CLOSE = 'BT_STOPS_TOO_CLOSE',
  /** #2B: instant-execution price moved beyond tolerance — client must re-confirm the new price (carried in `details.newPrice`). */
  REQUOTE = 'BT_REQUOTE',
  TRADING_DISABLED = 'BT_TRADING_DISABLED',
  INSUFFICIENT_MARGIN = 'BT_INSUFFICIENT_MARGIN',
  NO_PRICE = 'BT_NO_PRICE',
  /** No quote→account conversion pair in the feed; the position cannot be valued. */
  FX_RATE_UNAVAILABLE = 'BT_FX_RATE_UNAVAILABLE',
  POSITION_NOT_FOUND = 'BT_POSITION_NOT_FOUND',
  ORDER_NOT_FOUND = 'BT_ORDER_NOT_FOUND',
  DUPLICATE_ORDER = 'BT_DUPLICATE_ORDER',
  RISK_LIMIT_BREACH = 'BT_RISK_LIMIT_BREACH',
  // financial
  DUPLICATE_REF = 'BT_DUPLICATE_REF',
  INSUFFICIENT_FUNDS = 'BT_INSUFFICIENT_FUNDS',
  // generic
  VALIDATION = 'BT_VALIDATION',
  INTERNAL = 'BT_INTERNAL',
}

export class BtError extends Error {
  constructor(
    public readonly code: BtErrorCode,
    message?: string,
    public readonly details?: unknown,
  ) {
    super(message ?? code);
    this.name = 'BtError';
  }
}
