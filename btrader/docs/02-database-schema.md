# 2. Database Schema

The full schema is `packages/db/prisma/schema.prisma` (PostgreSQL, Prisma). It is a **separate database** from the Example CRM. Money is stored as `Decimal(28,8)`; prices as `Decimal(20,8)`. Every business row carries a `tenantId` and is indexed by it for isolation and query performance.

## Domains

**Tenancy & branding.** `Tenant` (status, base currency, custom `domain`/`adminDomain`/`appDomain`), `TenantBranding` (app name, logo, colors, iOS/Android bundle IDs, custom CSS), `TenantSetting` (arbitrary key/value JSON).

**Identity & auth.** `User` (role enum: SUPER_ADMIN, TENANT_ADMIN, TENANT_STAFF, TRADER, SERVICE; optional `crmUserId` link), `UserPermission` (fine-grained RBAC scopes), `Session` (hashed refresh tokens, revocable for force-logout), `ApiKey` (keyId + hashed secret, scopes, IP allowlist — used for CRM HMAC auth).

**Instruments.** `SymbolGroup` (markup buckets) and `Symbol` — the complete contract spec with no hardcoded instruments. Each symbol carries class (FOREX/METALS/STOCKS/INDICES/CRYPTO/COMMODITIES/CUSTOM), digits, pip size, contract size, min/max/step lot, margin currency & rate, leverage cap, **slippage points (default 0)**, spread markup, stops level, swap type & long/short rates, triple-swap weekday, and trading sessions (JSON). `SymbolTick` caches the latest bid/ask.

**Accounts.** `Account` holds authoritative `balance` and `credit` (bonus, non-withdrawable) plus cached live aggregates (`equity`, `margin`, `freeMargin`, `marginLevel`, `floatingPL`) that the engine recomputes, plus `leverage`, `marginCallLevel`, `stopOutLevel`, and `crmAccountId`. Login numbers are unique per tenant.

**Trading.** `Order` (all eight order types, status lifecycle, TIF, SL/TP, fills, link to position), `Position` (open lots, open/close price, SL/TP, margin used, swap, commission, profit), and `Deal` — an immutable ledger of everything that moves money or volume (OPEN/CLOSE/PARTIAL_CLOSE/BALANCE/DEPOSIT/WITHDRAWAL/BONUS/DIVIDEND/SWAP/COMMISSION/CREDIT) with `balanceAfter` for audit-grade reconstruction.

**Financial.** `BalanceAdjustment` records manual and CRM-originated money movements with a unique `externalRef` that provides **idempotency** — a retried CRM deposit never double-credits.

**Risk.** `RiskLimit` scoped to tenant / account / symbol / group: max lot per order, max open lots, max open positions, max net exposure, max daily loss %.

**Audit & integration.** `AuditLog` (actor, action enum, before/after JSON, IP) and `CrmSyncOutbox` (reliable at-least-once delivery of events to the CRM webhook with attempts/backoff).

## Why this mirrors and extends the CRM

The CRM's `TradingAccount` stores `balance/equity/margin/freeMargin` synced from a trading backend; B-Trader's `Account` is the authoritative source of exactly those fields plus credit, margin level, and floating P&L. The CRM's `Deposit`/`Withdrawal` originate financial intent; they land in B-Trader as `BalanceAdjustment` + `Deal` via the idempotent `/v1/crm/accounts/:login/balance` endpoint. The CRM's `crmUserId`/`crmAccountId` links keep the two systems reconcilable without sharing a database.

## Key indexes

Composite `(tenantId, status)` on accounts/orders/positions for admin dashboards; `(accountId, createdAt)` on deals for history pagination; unique `(tenantId, login)`, `(tenantId, symbol)`, and `externalRef` for idempotency; `(status, nextAttempt)` on the outbox for the delivery worker.

## Migrations

`pnpm --filter @btrader/db db:migrate` (dev) / `db:migrate:prod` (deploy). Seed data (`prisma/seed.ts`) provisions a platform super-admin, a demo tenant "Demo Broker", four instruments across asset classes, and a demo trader + account.
