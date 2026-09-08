# 3. API Specification

Base path: `/v1`. Interactive OpenAPI/Swagger is served at `/docs` (generated from the NestJS decorators at runtime). All timestamps are ISO-8601; all money is decimal.

Three auth schemes:
- **Bearer JWT** — mobile & admin (access token, 15 min; refresh, 30 days).
- **CRM HMAC key** — service-to-service for `/v1/crm/*` (`X-BT-Key`, `X-BT-Timestamp`, `X-BT-Signature`).
- **None** — `/v1/auth/login`, `/v1/auth/refresh`, `/v1/health`.

## Authentication

| Method | Path | Body | Notes |
|--------|------|------|-------|
| POST | `/auth/login` | `{email, password}` | Tenant from host/header. Returns `{accessToken, refreshToken, role}` |
| POST | `/auth/refresh` | `{refreshToken}` | Rotates both tokens; revokes old session |
| POST | `/auth/logout` | `{refreshToken}` | Revokes the session |
| POST | `/auth/force-logout` | `{userId}` | Admin; revokes all of a user's sessions |

## Tenants (SUPER_ADMIN)

`GET /tenants`, `POST /tenants` (name, slug, domains, branding), `PATCH /tenants/:id/branding`, `POST /tenants/:id/suspend`, `POST /tenants/:id/activate`, `DELETE /tenants/:id` (soft).

## Accounts & clients (admin)

`GET /accounts/clients`, `POST /accounts/clients`, `PATCH /accounts/clients/:userId/active`, `PATCH /accounts/:accountId/trading` (enable/disable), `PATCH /accounts/:accountId/leverage`, `POST /accounts/clients/:userId/force-logout`, `GET /accounts/:accountId`, `GET /accounts/exposure/net`.

## Symbols (admin manage, traders read)

`GET /symbols?enabled=true`, `POST /symbols` (full contract spec), `PATCH /symbols/:id` (contract size, margin, swap, sessions, lots, slippage), `PATCH /symbols/:id/enabled`, `DELETE /symbols/:id`, `GET /symbols/groups/all`, `POST /symbols/groups`.

## Trading (mobile/trader)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/orders` | Place market or pending order (all 8 types, one-click). Returns `ExecutionResult` |
| GET | `/orders?accountId&status` | List orders |
| DELETE | `/orders/:id` | Cancel a pending order |
| GET | `/positions?accountId&status` | List positions |
| PATCH | `/positions/:id` | Modify SL/TP |
| POST | `/positions/:id/close` | Close full or partial (`{volume?}`) |
| POST | `/accounts/:accountId/close-all` | Close all open positions |
| GET | `/history/deals?accountId&from&to` | Trade history |

`POST /orders` body (`PlaceOrderDto`): `accountId, symbol, side(BUY|SELL), type(MARKET|LIMIT|STOP|STOP_LIMIT|BUY_STOP|SELL_STOP|BUY_LIMIT|SELL_LIMIT), volume, price?, stopPrice?, slPrice?, tpPrice?, timeInForce?, expiresAt?, comment?, oneClick?`.

## Financial (admin)

`POST /financial/adjust` — `{accountId, type(DEPOSIT|WITHDRAWAL|BONUS|DIVIDEND|CREDIT|MANUAL|CORRECTION), amount, comment?}`. Requires `balance.adjust` permission. Idempotent when an `externalRef` is supplied.

## Risk (admin)

`GET /risk/limits`, `POST /risk/limits` (`{scope, maxLotPerOrder?, maxOpenLots?, maxOpenPositions?, maxNetExposure?, maxDailyLossPct?}`), `DELETE /risk/limits/:scope`, `GET /risk/margin-alerts`.

## Audit (admin)

`GET /audit?action&entity` — tenant-scoped, newest first.

## CRM integration (`/v1/crm/*`, HMAC) {#crm-integration}

This is the contract the **Example CRM** consumes — a superset of the CRM's existing `mt5.service.ts`. Signature: `HMAC_SHA256(secret, "{timestamp}.{rawBody}")`; replay window ±5 min; key scopes enforced; tenant resolved from the key.

| CRM method (today) | B-Trader route | Scope |
|--------------------|----------------|-------|
| `createAccount` | `POST /crm/accounts` | `crm.write` |
| `getUser`/`getAccount` | `GET /crm/accounts/:login` | `crm.read` |
| `getBatchAccounts` | `POST /crm/accounts/batch` | `crm.read` |
| `getOpenPositions` | `GET /crm/accounts/:login/positions` | `crm.read` |
| `getDealHistory` | `GET /crm/accounts/:login/deals?from&to` | `crm.read` |
| `enableAccount`/`disableAccount`/`updateAccount` | `PATCH /crm/accounts/:login` | `crm.write` |
| `changePassword` | `POST /crm/accounts/:login/password` | `crm.write` |
| `depositBalance`/`withdrawBalance` | `POST /crm/accounts/:login/balance` | `crm.write`, `balance.adjust` |
| — (new) | `GET /crm/accounts/:login/stats` | `crm.read` |

`POST /crm/accounts/:login/balance` body: `{amount, type(DEPOSIT|WITHDRAWAL|BONUS|DIVIDEND|CREDIT|CORRECTION), comment?, externalRef}`. `externalRef` (CRM transaction id) is the idempotency key — a duplicate returns `{duplicate:true}` and does not re-apply.

### Push webhooks (B-Trader → CRM)

To replace the CRM's polling, B-Trader pushes events via the outbox to `CRM_WEBHOOK_URL` (HMAC-signed): `account.snapshot`, `position.opened|modified|closed`, `deal.created`, `margin.call`, `stop.out`. Delivery is at-least-once with retry/backoff; the CRM should dedupe on event `id`.

## Errors

Stable codes from `packages/shared/src/errors.ts` (e.g. `BT_INSUFFICIENT_MARGIN`, `BT_MARKET_CLOSED`, `BT_DUPLICATE_REF`, `BT_RISK_LIMIT_BREACH`). HTTP status maps: 400 validation, 401 auth, 403 RBAC/tenant, 409 idempotency conflict, 422 trading rejection, 429 rate limit.

## Rate limiting

Global 300 req/min/IP (`@nestjs/throttler`), overridable per route. CRM keys get a separate higher bucket. WebSocket connections are capped per tenant.
