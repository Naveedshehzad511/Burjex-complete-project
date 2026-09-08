# 6. WebSocket Architecture

## Topology
A dedicated stateless `ws-gateway` service is the only socket clients connect to. Market data and engine events flow through Redis pub/sub; any gateway replica can serve any client because it holds no authoritative state — only the per-connection subscription set.

```
LP bridge → market-data → Redis bt:{tenant}:ticks ┐
trading-engine → Redis bt:{tenant}:engine.evt    ┘→ ws-gateway → client sockets
```

## Connection lifecycle
1. Client connects to `wss://.../ws?token=<accessJWT>`.
2. Gateway verifies the JWT (same secret as gateway-api) and extracts `sub` + `tenantId`. Invalid → close 4401.
3. Client sends subscription ops; gateway tracks them per connection.
4. Gateway pattern-subscribes once to `bt:*:ticks` and `bt:*:engine.evt`, then routes each message to the matching connections (same tenant + subscribed symbol/account).

## Client protocol (JSON)
- `{op:"subscribe", symbols:[...]}` / `{op:"unsubscribe", symbols:[...]}`
- `{op:"watch_account", accountId}` / `{op:"unwatch_account", accountId}`
- `{op:"ping"}` → server `{t:"pong"}`

Server frames (`WsFrame`): `{t:"tick", d:Tick}`, `{t:"account", d:AccountSnapshot}`, `{t:"position", d:PositionDTO}`, `{t:"order", d:OrderDTO}`.

## Multi-tenant isolation
Every routed message checks `client.tenantId === channelTenantId`. A client can only ever receive ticks for symbols it subscribed to and account/position events for accounts it explicitly watches (and which belong to its tenant). There is no cross-tenant leakage even though one gateway process serves all tenants.

## Scale & resilience
- **Horizontal scale** — add `ws-gateway` replicas behind the ingress; Redis fan-out means no sticky sessions are required for correctness (the LB may still use IP affinity for efficiency).
- **Heartbeat** — 30s server ping; dead sockets are terminated and cleaned up.
- **Backpressure** — high-frequency symbols can be throttled/coalesced per connection (send latest tick per interval) to protect slow mobile links.
- **Reconnect** — the mobile `MarketSocket` reconnects with exponential backoff and replays its subscription set, so a gateway restart is invisible to users within a tick interval.

## Latency
Tick → client is a single Redis pub/sub hop plus a socket write — no DB on the path. This is what lets B-Trader push account/position updates in real time instead of the CRM's prior 30-second poll.
