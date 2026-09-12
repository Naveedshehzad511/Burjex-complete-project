// ============================================================================
//  CRM Integration Contract  (B-Trader  ⇄  Example CRM)
//
//  B-Trader is the system of record for trading. The CRM consumes these APIs.
//  This contract is a SUPERSET of what Example's apps/api/src/modules/mt5
//  (mt5.service.ts) already calls, so the CRM can swap MT5 → B-Trader by
//  pointing its connector at B-Trader and using the same method shapes.
//
//  Auth: API key (keyId) + HMAC-SHA256 signature of (timestamp + body) using the
//  shared secret. Header set: X-BT-Key, X-BT-Timestamp, X-BT-Signature.
//  Tenant is resolved from the key (platform key may pass X-BT-Tenant).
// ============================================================================

// ── Account provisioning (CRM creates trading accounts) ─────────────────────
export interface CrmCreateAccountRequest {
  crmUserId: string;
  email: string;
  name?: string;
  phone?: string;
  group?: string; // symbol/account group → maps to AccountType + SymbolGroup
  type?: 'STANDARD' | 'ECN' | 'RAW' | 'ISLAMIC' | 'DEMO';
  leverage: number;
  currency?: string;
  isDemo?: boolean;
  password?: string; // optional; if absent B-Trader generates
  comment?: string;
}

export interface CrmCreateAccountResponse {
  accountId: string;
  login: string;
}

// ── Account read (mirrors mt5.getAccount + getUser) ─────────────────────────
export interface CrmAccountInfo {
  accountId: string;
  login: string;
  crmUserId?: string;
  group?: string;
  currency: string;
  leverage: number;
  status: string;
  enabled: boolean;
  balance: number;
  credit: number;
  equity: number;
  margin: number;
  freeMargin: number;
  marginLevel: number;
  floatingPL: number;
  bonus: number;
  dividend: number;
}

// Batch read — replaces mt5.getBatchAccounts (CRM polls; B-Trader also pushes).
export interface CrmBatchAccountsRequest {
  logins: string[];
}
export type CrmBatchAccountsResponse = Record<string, CrmAccountInfo>;

// ── Positions (mirrors mt5.getOpenPositions) ────────────────────────────────
export interface CrmPosition {
  positionId: string;
  login: string;
  symbol: string;
  side: 'BUY' | 'SELL';
  volume: number; // lots
  openPrice: number;
  currentPrice: number;
  slPrice?: number;
  tpPrice?: number;
  swap: number;
  commission: number;
  profit: number;
  openedAt: string;
}

// ── Deal / trade history (mirrors mt5.getDealHistory) ───────────────────────
export interface CrmDeal {
  dealId: string;
  login: string;
  positionId?: string;
  symbol?: string;
  type: string; // OPEN | CLOSE | DEPOSIT | WITHDRAWAL | BONUS | DIVIDEND | SWAP | ...
  side?: 'BUY' | 'SELL';
  volume?: number;
  price?: number;
  profit: number;
  swap: number;
  commission: number;
  balanceAfter: number;
  comment?: string;
  externalRef?: string;
  createdAt: string;
}

export interface CrmDealHistoryRequest {
  login: string;
  from: string; // ISO
  to: string; // ISO
}

// ── Financial ops (CRM-originated; idempotent via externalRef) ──────────────
// Replaces mt5.depositBalance / withdrawBalance and adds bonus/dividend.
export interface CrmBalanceOpRequest {
  login: string;
  amount: number; // positive magnitude
  type: 'DEPOSIT' | 'WITHDRAWAL' | 'BONUS' | 'DIVIDEND' | 'CREDIT' | 'CORRECTION';
  comment?: string;
  externalRef: string; // CRM transaction id — idempotency key (required)
}

export interface CrmBalanceOpResponse {
  ok: boolean;
  dealId: string;
  balanceAfter: number;
  duplicate?: boolean; // true if externalRef was already processed
}

// ── Account control (mirrors mt5 enable/disable/leverage/password) ──────────
export interface CrmUpdateAccountRequest {
  leverage?: number;
  group?: string;
  enableTrading?: boolean;
  status?: 'ACTIVE' | 'TRADING_DISABLED' | 'READ_ONLY' | 'ARCHIVED';
  comment?: string;
}

export interface CrmChangePasswordRequest {
  newPassword: string;
  type?: 'MAIN' | 'INVESTOR';
}

// ── Trading statistics (CRM dashboards) ─────────────────────────────────────
export interface CrmTradingStats {
  login: string;
  totalDeposits: number;
  totalWithdrawals: number;
  totalBonus: number;
  totalDividend: number;
  closedPL: number;
  totalTrades: number;
  openPositions: number;
  volumeLots: number;
  winRate: number;
  lastTradeAt?: string;
}

// ── Webhook events B-Trader pushes to the CRM (low-latency, replaces polling) ─
export type CrmWebhookEventType =
  | 'account.snapshot'
  | 'position.opened'
  | 'position.modified'
  | 'position.closed'
  | 'deal.created'
  | 'margin.call'
  | 'stop.out';

export interface CrmWebhookEvent<T = unknown> {
  id: string;
  tenantId: string;
  type: CrmWebhookEventType;
  occurredAt: string;
  data: T;
}

/**
 * Reverse contract: methods the CRM's existing connector expects. Documented
 * here so the CRM team can map its mt5.service calls 1:1 onto B-Trader routes.
 *   mt5.createAccount      → POST   /v1/crm/accounts
 *   mt5.getUser/getAccount → GET    /v1/crm/accounts/:login
 *   mt5.getBatchAccounts   → POST   /v1/crm/accounts/batch
 *   mt5.getOpenPositions   → GET    /v1/crm/accounts/:login/positions
 *   mt5.getDealHistory     → GET    /v1/crm/accounts/:login/deals?from&to
 *   mt5.enableAccount      → PATCH  /v1/crm/accounts/:login  {enableTrading:true}
 *   mt5.disableAccount     → PATCH  /v1/crm/accounts/:login  {enableTrading:false}
 *   mt5.changePassword     → POST   /v1/crm/accounts/:login/password
 *   mt5.updateAccount      → PATCH  /v1/crm/accounts/:login  {leverage,group}
 *   mt5.depositBalance     → POST   /v1/crm/accounts/:login/balance {type:DEPOSIT}
 *   mt5.withdrawBalance    → POST   /v1/crm/accounts/:login/balance {type:WITHDRAWAL}
 */
export const CRM_ROUTE_MAP = {
  listGroups: 'GET /v1/crm/groups',
  listSymbols: 'GET /v1/crm/symbols',
  createAccount: 'POST /v1/crm/accounts',
  getAccount: 'GET /v1/crm/accounts/:login',
  batchAccounts: 'POST /v1/crm/accounts/batch',
  positions: 'GET /v1/crm/accounts/:login/positions',
  deals: 'GET /v1/crm/accounts/:login/deals',
  updateAccount: 'PATCH /v1/crm/accounts/:login',
  changePassword: 'POST /v1/crm/accounts/:login/password',
  balanceOp: 'POST /v1/crm/accounts/:login/balance',
  stats: 'GET /v1/crm/accounts/:login/stats',
} as const;
