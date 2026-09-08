# B-Trader ↔ CRM Integration Guide

This guide explains how any broker CRM (Example or third-party) connects to B-Trader. The integration is **API-only** and **per-tenant**: every broker brand is a separate tenant with its own credentials, webhook, and isolated data. Nothing here is hardcoded to one CRM — different companies plug in different CRMs against the same contract.

There are two directions:

1. **Inbound — CRM → B-Trader.** The CRM calls B-Trader to provision accounts, push deposits/withdrawals/bonus/dividend, set passwords, change leverage, and read balances, positions, deals, and statistics. Authenticated with a per-tenant **API key + HMAC signature**.
2. **Outbound — B-Trader → CRM.** B-Trader pushes signed webhook events (trade opened/closed, balance changed, margin call, etc.) to the CRM's webhook URL so the CRM stays in sync without polling. Authenticated with an **HMAC signature** the CRM verifies.

Each tenant configures both directions from the admin dashboard under **CRM / Integrations**.

---

## 1. Per-tenant setup (admin dashboard)

A broker admin opens **CRM / Integrations** and does two things:

**Mint an inbound API key.** Click *New key* → optionally restrict by IP. B-Trader returns a `keyId` and a `secret`. **The secret is shown exactly once** — copy it into the CRM's configuration immediately; B-Trader stores only a hash for display and never returns the raw secret again. (Revoke and re-issue if it is lost.)

**Set the outbound webhook.** Enter the CRM endpoint URL, a signing secret, and toggle *Enabled*. B-Trader will sign every event with that secret. Optionally restrict which event types are delivered.

These settings live on the tenant, so each broker's CRM is fully isolated — one tenant's key can never read or write another tenant's data.

**Burjex Prime CRM:** paste `keyId` / `secret` / gateway base URL under **System Management → Integrations → Trading Platforms → BTrader**. Groups from `GET /v1/crm/groups` then appear in CRM Group Management like MT5 groups.

---

## 2. Authentication

### 2.1 Inbound (CRM → B-Trader)

Every request to `/v1/crm/*` must carry three headers:

| Header | Value |
| --- | --- |
| `X-BT-Key` | the `keyId` from the dashboard |
| `X-BT-Timestamp` | current epoch milliseconds (must be within ±5 minutes of server time) |
| `X-BT-Signature` | `HMAC_SHA256(secret, "{timestamp}.{rawBody}")`, hex-encoded |

The signature is computed over the literal string `` `${timestamp}.${rawBody}` `` where `rawBody` is the exact JSON body bytes you send (empty `{}` for GET/bodyless requests — sign over the same bytes you transmit). The server recomputes and compares in constant time, so the body you sign must byte-for-byte match the body you send. Do not re-serialize between signing and sending.

The tenant is resolved from the key itself, so you do not send a tenant id. (Platform-scope keys, which are rare, may add `X-BT-Tenant`.)

Each route also requires **scopes**, checked against the key:

- `crm.read` — read account info, positions, deals, stats.
- `crm.write` — create/update accounts, set passwords.
- `balance.adjust` — deposits/withdrawals/bonus/dividend (in addition to `crm.write`).

New keys default to `["crm.read", "crm.write", "balance.adjust"]`.

#### Signing example (Node.js)

```js
const crypto = require('crypto');

async function callBTrader(method, path, bodyObj, { keyId, secret, baseUrl }) {
  const raw = bodyObj ? JSON.stringify(bodyObj) : '{}';
  const ts = Date.now().toString();
  const sig = crypto.createHmac('sha256', secret).update(`${ts}.${raw}`).digest('hex');
  const res = await fetch(`${baseUrl}/v1/crm${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-BT-Key': keyId,
      'X-BT-Timestamp': ts,
      'X-BT-Signature': sig,
    },
    body: method === 'GET' ? undefined : raw,
  });
  if (!res.ok) throw new Error(`B-Trader ${res.status}: ${await res.text()}`);
  return res.json();
}
```

> Note: for GET requests B-Trader signs over `{}`. Send no body but sign `"{ts}.{}"` — i.e. pass `bodyObj = null` above.

#### Signing example (PHP)

```php
function btSign($secret, $ts, $raw) {
  return hash_hmac('sha256', "$ts.$raw", $secret);
}
$raw = json_encode($payload, JSON_UNESCAPED_SLASHES);
$ts  = (string) round(microtime(true) * 1000);
$sig = btSign($secret, $ts, $raw);
// send $raw as the request body with X-BT-Key, X-BT-Timestamp=$ts, X-BT-Signature=$sig
```

### 2.2 Outbound (B-Trader → CRM)

B-Trader POSTs events to the configured webhook URL with:

| Header | Value |
| --- | --- |
| `X-BT-Timestamp` | epoch ms |
| `X-BT-Signature` | `HMAC_SHA256(webhookSecret, "{timestamp}.{rawBody}")` |

The CRM **must** verify the signature before trusting the payload:

```js
function verify(req, webhookSecret) {
  const ts = req.headers['x-bt-timestamp'];
  const sig = req.headers['x-bt-signature'];
  if (Math.abs(Date.now() - Number(ts)) > 5 * 60_000) return false; // replay window
  const expected = crypto.createHmac('sha256', webhookSecret)
    .update(`${ts}.${req.rawBody}`).digest('hex');
  return expected.length === sig.length &&
    crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(sig));
}
```

Respond `2xx` to acknowledge. Any non-2xx (or timeout) is retried with exponential backoff (cap 5 min, up to 10 attempts) — so the CRM endpoint **must be idempotent** on the event `id`.

---

## 3. Inbound endpoints (CRM → B-Trader)

Base path: `POST/GET {baseUrl}/v1/crm/...`. All are tenant-scoped by the key.

### 3.0 List trading groups (CRM Group Management)

`GET /v1/crm/groups` — scope `crm.read`

Returns the tenant's trading groups so the CRM can map them like MT5 groups (Group Management → Account Types). Pass the exact `name` as `group` on account create.

```json
[
  { "id": "uuid", "name": "Standard", "enabled": true, "defaultLeverage": 100, "defaultBook": "B" }
]
```

### 3.1 Create a trading account

`POST /v1/crm/accounts` — scope `crm.write`

B-Trader generates the 6-digit **login number**; the CRM supplies the **password** the trader will use to sign into the mobile app (login number + password). B-Trader hashes and stores it.

```json
{
  "crmUserId": "crm-user-123",
  "crmAccountId": "crm-acct-456",
  "email": "trader@example.com",
  "name": "Jane Doe",
  "phone": "+10000000000",
  "password": "the-traders-app-password",
  "type": "STANDARD",
  "currency": "USD",
  "leverage": 100,
  "isDemo": false
}
```

Response:

```json
{ "accountId": "uuid", "login": "500001" }
```

`login` is the account number the trader types into the app. The CRM stores it to show the client and for subsequent calls.

### 3.2 Read account info

`GET /v1/crm/accounts/{login}` — scope `crm.read`

```json
{
  "accountId": "uuid", "login": "500001", "crmUserId": "crm-user-123",
  "currency": "USD", "leverage": 100, "status": "ACTIVE", "enabled": true,
  "balance": 1000.0, "credit": 0.0, "equity": 1012.5, "margin": 50.0,
  "freeMargin": 962.5, "marginLevel": 2025.0, "floatingPL": 12.5,
  "bonus": 0.0, "dividend": 0.0
}
```

### 3.3 Batch account info (replaces polling)

`POST /v1/crm/accounts/batch` — scope `crm.read`

```json
{ "logins": ["500001", "500002"] }
```

Returns a map keyed by login → the account-info object above.

### 3.4 Open positions

`GET /v1/crm/accounts/{login}/positions` — scope `crm.read`. Returns an array of `{ positionId, login, symbol, side, volume, openPrice, currentPrice, slPrice?, tpPrice?, swap, commission, profit, openedAt }`.

### 3.5 Deal / trade history

`GET /v1/crm/accounts/{login}/deals?from=ISO&to=ISO` — scope `crm.read`. Returns up to 1000 deals `{ dealId, login, positionId?, type, side?, volume?, price?, profit, swap, commission, balanceAfter, comment?, externalRef?, createdAt }`. `type` includes trade events (`OPEN`/`CLOSE`) and balance events (`DEPOSIT`/`WITHDRAWAL`/`BONUS`/`DIVIDEND`).

### 3.6 Balance operations (deposit / withdraw / bonus / dividend)

`POST /v1/crm/accounts/{login}/balance` — scopes `crm.write` + `balance.adjust`

**Deposit and withdrawal requests originate in the CRM** and are pushed here.

```json
{
  "type": "DEPOSIT",
  "amount": 500.00,
  "comment": "Card deposit #98231",
  "externalRef": "crm-txn-98231"
}
```

`type` ∈ `DEPOSIT | WITHDRAWAL | BONUS | DIVIDEND`. For withdrawals send a positive `amount` with `type: "WITHDRAWAL"`.

**Idempotency:** always set `externalRef` to a unique CRM transaction id. Re-sending the same `externalRef` will not double-apply — this makes safe retries possible after a network failure.

### 3.7 Update account (leverage / enable-disable trading / status)

`PATCH /v1/crm/accounts/{login}` — scope `crm.write`

```json
{ "leverage": 200 }
{ "enableTrading": false }
{ "status": "ACTIVE" }
```

`enableTrading: false` sets status `TRADING_DISABLED`; `true` sets `ACTIVE`.

### 3.8 Set password

`POST /v1/crm/accounts/{login}/password` — scope `crm.write`

```json
{ "newPassword": "new-app-password", "type": "MAIN" }
```

`MAIN` is the trading/app login password. `INVESTOR` (read-only) is reserved for future use.

### 3.9 Trading statistics

`GET /v1/crm/accounts/{login}/stats` — scope `crm.read`

```json
{
  "login": "500001", "totalDeposits": 1500, "totalWithdrawals": 200,
  "totalBonus": 50, "totalDividend": 0, "closedPL": 312.4,
  "totalTrades": 18, "openPositions": 2, "volumeLots": 4.7,
  "winRate": 0.61, "lastTradeAt": "2026-06-19T10:22:00.000Z"
}
```

---

## 4. Outbound events (B-Trader → CRM webhook)

Envelope POSTed to the webhook URL:

```json
{
  "id": "outbox-uuid",
  "tenantId": "tenant-uuid",
  "type": "POSITION_CLOSED",
  "occurredAt": "2026-06-19T10:22:00.000Z",
  "data": { }
}
```

Event `type` values include account/position lifecycle and balance changes (e.g. `POSITION_OPENED`, `POSITION_CLOSED`, `BALANCE_CHANGED`, `MARGIN_CALL`). The CRM can restrict which types it receives in the dashboard. The `data` object carries the event-specific payload (account login, amounts, position fields).

**Handling rules:** verify the HMAC (§2.2), de-duplicate on `id` (retries reuse the same `id`), respond `2xx` quickly, and do heavy work asynchronously.

---

## 5. End-to-end onboarding flow

1. CRM admin creates the broker **tenant** (or it already exists).
2. In **CRM / Integrations**, mint an API key → store `keyId` + `secret` in the CRM, and set the webhook URL + secret.
3. When a client is approved in the CRM, call `POST /v1/crm/accounts` → receive the `login` number. Show it to the client; the client signs into the app with **login + password**.
4. Client funding requests in the CRM call `POST /v1/crm/accounts/{login}/balance` with a unique `externalRef`.
5. The CRM dashboard reads balances/positions/deals/stats via the `crm.read` endpoints (or batch), and stays live via webhook events.
6. Leverage changes, enabling/disabling trading, and password resets go through `PATCH /v1/crm/accounts/{login}` and `POST .../password`.

---

## 6. Errors & operational notes

- **401** — missing/invalid/expired key, stale timestamp (>5 min skew), or bad signature. Check clock sync and that you signed the exact transmitted body.
- **403** — IP not allowed, or the key lacks the required scope.
- **Validation errors** return a structured error code (e.g. account not found).
- **Clock skew** is the most common signing failure — keep the CRM server's time synced (NTP).
- **Rate limiting** applies per IP; batch reads instead of tight polling loops.
- **Secrets** are sensitive: store them encrypted in the CRM, rotate by minting a new key and revoking the old one.
