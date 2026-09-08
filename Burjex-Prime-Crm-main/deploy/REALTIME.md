# Realtime: prices, balance, equity and margin without polling

Everything a trader watches move — bid/ask, equity, floating P/L, free margin,
margin level — is **pushed** over one WebSocket. Nothing on that path polls, and
nothing on it touches a database.

## The path

```
MT5 terminal (Windows VPS)
   │  bridge / EA POSTs tick batches
   │  HTTPS → https://feed.burjexprime.com/ingest   (MT5_FEED_TOKEN)
   ▼
market-data :4200
   │  applies the tenant's markup, publishes to Redis
   │  channel  bt:{tenantId}:ticks
   ├──────────────────────────────────────────────┐
   ▼                                              │
trading-engine                                    │
   │  revalues open positions, recomputes the     │
   │  account, publishes ACCOUNT_UPDATE /         │
   │  POSITION_UPDATE to bt:{tenantId}:engine.evt │
   ▼                                              │
ws-gateway :4101  ◄───────────────────────────────┘
   │  one Redis pattern-subscribe, fans out per connection:
   │  {t:"tick"}  {t:"account"}  {t:"position"}  {t:"order"}
   ▼
Caddy  wss://ws.burjexprime.com   (no buffering, no read timeout)
   ▼
Flutter apps — MarketSocket
```

Tick to screen is one Redis pub/sub hop plus a socket write. There is no
database read on the hot path, which is what makes it feel instant.

A second, slower path keeps the CRM's own tables correct:

```
trading-engine  →  outbox worker  →  HTTPS POST
                   https://crm.burjexprime.com/api/btrader/webhook/
                   → CRM Postgres → admin screens, reports, IB rebates
```

That webhook is for durability and reporting. The app never waits on it.

## Why the app is now instant

`AccountSnapshot` (`btrader/packages/shared/src/trading.ts`) carries
`balance`, `credit`, `equity`, `margin`, `freeMargin`, `marginLevel`,
`floatingPL` and both `accountId` and `login`. The engine emits it on every
`ACCOUNT_UPDATE`, which fires on each tick that moves an open position.

The client protocol was already in place — `MarketSocket` supports
`watch_account`, and `WsFrame` already carried `{t:"account"}`. What was missing
was the CRM app *using* it on Home.

**Before:** `home_screen.dart` ran `Timer.periodic(2s)` calling
`DashboardProvider.load(silent: true)`, so every balance was an HTTP round trip
to Django, which read a value the webhook had written some time earlier. Two
layers of staleness, and a request every 2 seconds per user.

**After** (`forexten_mobile/lib/trading/live_accounts_ws.dart`):

- `btraderAccountWatchProvider` sends `watch_account` for each B-Trader account
  the session owns. The gateway authorises this against the `accts` claim in the
  access JWT, so a client can only ever stream its own accounts.
- `liveAccountsByLoginProvider` listens to the socket's broadcast `frames`
  stream and stores each snapshot keyed by **login** — the account number the
  CRM shows. (`btrader_core`'s own `liveAccountProvider` keys by internal UUID
  and overwrites `login` with it, so CRM rows cannot match against it.)
- `applyLiveAccounts` / `applyLiveMetrics` overlay those pushed values onto the
  CRM rows and recompute the summary cards, so the totals and the per-account
  figures always agree.
- Equity is rendered from `liveEquity` (`balance + credit + floatingPL`) rather
  than the engine's cached `equity` column, so it stays correct between writes.
- The 2-second timer is now **30 seconds** and reconciles only what the trading
  socket cannot know: an approved deposit or withdrawal, an IB rebate, a new
  account, a KYC change.
- Snapshots older than 30s are treated as stale and the CRM value is shown
  instead — an account with no open positions stops emitting, and a frozen
  number is worse than a reconciled one.

MT5 and Match-Trader accounts are untouched by this overlay; they have no
B-Trader socket and are still reconciled by Celery.

## What the proxy has to get right

Caddy handles the `Upgrade` handshake itself — there is no Nginx-style
`proxy_set_header Upgrade` to write. Two things do need setting explicitly, and
both are in the `ws_proxy` snippet in the [`Caddyfile`](Caddyfile):

- `read_timeout 0` / `write_timeout 0` — the default would drop an idle socket
  mid-session. A quiet market is not a dead connection.
- `flush_interval -1` — flush every frame immediately. Response buffering is
  exactly what would reintroduce the lag this design removes.

`encode` is deliberately **not** applied to the `ws.` host: compressing a socket
adds latency and defeats per-frame flushing.

If you front this with Nginx instead, the equivalent is already written for you
in [`btrader/infra/nginx/btrader.prod.conf`](../btrader/infra/nginx/btrader.prod.conf)
— `proxy_http_version 1.1`, `Upgrade`/`Connection` headers from the
`$bt_conn_upgrade` map, and `proxy_read_timeout 3600s`. Add
`proxy_buffering off;` to that block for the same reason as `flush_interval -1`.

## Verifying it

```bash
# Ticks arriving from the Windows bridge
docker compose -f deploy/docker-compose.prod.yml logs -f btrader-market-data

# Sockets connecting
docker compose -f deploy/docker-compose.prod.yml logs -f btrader-ws

# Handshake from outside (101 Switching Protocols == working)
curl -i -N \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://ws.burjexprime.com/?token=<access-jwt>"
```

A close with code **4401** means the JWT was rejected: `JWT_SECRET` differs
between `btrader-gateway` and `btrader-ws`, or the token expired. Both services
read it from the same `.env.prod`, so a mismatch means one of them was started
against a stale env — recreate it rather than restarting it.

In the app, open a position and watch equity and floating P/L move continuously
rather than stepping every 2 seconds. Stepping means the socket is down and the
30-second reconcile is all that is left.
