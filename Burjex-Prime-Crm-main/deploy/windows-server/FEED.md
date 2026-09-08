# Why the feed stays stable on Windows Server

**English + short ops rules.** Goal: no laptop→VPS style gap / stutter (`ruk-ruk`).

---

## Root causes of the old stutter (what we already fixed)

| Failure mode | What happened | Why Windows Server avoids it |
|---|---|---|
| Compose without `--env-file` | `BT_*` / `DATABASE_URL` / `REDIS_URL` empty → `btrader-market-data` crash-loop | Pack scripts **always** inject `--env-file deploy\.env.prod.ip` |
| Ingest ACK blocked by Redis fan-out | Bridge hit 8s read timeout → intermittent gaps | Market-data **ACK-before-fanout** (`mt5-ingest-adapter.ts`) — normalize → JSON 200 → `setImmediate` fan-out |
| Candle history starved the event loop | Heavy Prisma flushes delayed `/ingest` | Durable candle flush: `CANDLE_FLUSH_YIELD_MS`, queue cap, tip throttle in compose + `main.ts` |
| Laptop bridge + remote VPS | WAN latency + laptop sleep/VPN/Wi‑Fi | Same-machine: bridge → `http://127.0.0.1:4300` (loopback, no WAN) |
| Two bridges at once | Duplicate / fighting ticks | **Cutover rule:** stop laptop bridge **before** starting server bridge |
| Reconcile fighting admin | Symbol/group churn during cutover | Example config: `ReconcileEnabled=false`, `GroupsReconcileEnabled=false` |

These server-side tick/candle fixes live in **this repo** (`btrader/apps/market-data`), not only on the old Linux VPS. Windows deploy builds from local `btrader\`.

---

## Guaranteed feed path (same-machine)

```text
MT5 Manager API  →  mt5_bridge.py (NSSM service)
                 →  POST http://127.0.0.1:4300/ingest   (Caddy → market-data:4200)
                 →  ACK 200 immediately
                 →  Redis fan-out to engine + WS (off HTTP path)
```

Bridge settings that matter (see `config.windows-server.json.example`):

| Key | Value | Why |
|---|---|---|
| `FeedUrl` | `http://127.0.0.1:4300` | Loopback; script appends `/ingest` |
| `TickFlushMs` | `50` | Snappy batches (bridge floor is 50) |
| `TickHttpTimeoutSec` | `8` | Separate from candle timeout |
| `CandleHttpTimeoutSec` | `15` | History can be slower without killing ticks |
| `ReconcileEnabled` | `false` | Stable cutover |
| `GroupsReconcileEnabled` | `false` | Stable cutover |

---

## Ops rules (do not break)

1. **NEVER** run bare `docker compose …` without `--env-file`. Use `.\up.ps1` / `.\recreate.ps1` / `.\restart.ps1` / `.\ps.ps1` / `.\logs.ps1` only.
2. **ONE bridge only.** Stop laptop / old PC bridge **before** `nssm start BurjexMt5Bridge` on the server.
3. Same-machine `FeedUrl` must stay `127.0.0.1` / `localhost` — not the public IP, not `host.docker.internal`.
4. After stack + bridge: run `.\preflight-feed.ps1` — checks `/health` `lastTickAt`, service Running, FeedUrl sanity.
5. Do not recreate `btrader-market-data` with raw compose; use `.\recreate.ps1 btrader-market-data`.
6. Keep old Linux VPS until 24–48h stable; do not wipe it during first bring-up.
7. If hybrid (bridge on Windows, stack on Linux): point FeedUrl at Linux IP and set `FEED_ALLOWED_IPS` on that VPS — still only **one** bridge.

---

## Quick verify

```powershell
cd deploy\windows-server
.\preflight-feed.ps1
curl.exe -s http://127.0.0.1:4300/health
nssm status BurjexMt5Bridge
.\logs.ps1 btrader-market-data
```

Healthy `/health` looks like: `{"ok":true,"received":…,"lastTickAt":<fresh ms>}`.

---

## Cutover order (chaos-free)

1. Bring Windows stack up (`.\up.ps1`) — verify CRM + `:4300/health` (may show `lastTickAt:0` until bridge starts).
2. Install MT5 + bridge config from example (`FeedUrl=http://127.0.0.1:4300`).
3. **Stop** laptop / old bridge completely (process + any autostart).
4. Start server bridge (`.\setup-bridge-service.ps1 -Start`).
5. `.\preflight-feed.ps1` — must pass (`lastTickAt` fresh).
6. Watch quotes in admin; keep old VPS as fallback until stable.
