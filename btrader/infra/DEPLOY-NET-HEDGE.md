# Deploy update — B-book net hedging (manual + auto cover to MT5)

Server: `root@YOUR_SERVER_IP` · compose `infra/docker-compose.prod.yml`

Lets the desk cover B-book exposure to the MT5 cover account, two ways:

- **Manual cover** — Dealing → **Net Hedge** tab: pick symbol, side, lots → Send. Goes straight to MT5.
- **Auto net-hedge** — per-symbol threshold; when the broker's net B-book exposure on a symbol exceeds it, the engine auto-covers the **excess** to MT5 (and unwinds when exposure falls). Threshold 0 = keep that symbol flat.

Both create `HedgeOrder` rows that the **existing** MT5 bridge executes (`DealerSend`). No bridge code change — but the bridge must have `HedgeEnabled: true` + `Mt5CoverLogin` set, and the LP driver must be **MT5 + enabled**.

## Schema (additive, no reset)

- `HedgeOrder.positionId` / `accountId` → nullable (broker hedges have no client position)
- `HedgeOrder.kind` → `HedgeKind` enum (`CLIENT_COVER` | `BROKER_MANUAL` | `BROKER_AUTO`), default `CLIENT_COVER`
- new `auto_hedge_rules` table

## Deploy

1. Backend — from your Mac:

   ```bash
   ./deploy.sh
   ```

2. Admin web — from your Mac:

   ```bash
   cd ~/B-Trader/B-Trader/flutter/apps/admin && flutter build web --release && \
     rsync -avz --delete build/web/ root@YOUR_SERVER_IP:/root/btrader-admin/
   ```

   Hard-refresh `admin.example.com`.

3. Bridge — **no change**. Just ensure on the MT5 VPS `config.json`: `HedgeEnabled: true`, `Mt5CoverLogin` = the cover account, and `DealerSend` validated on your build.

Optional engine env: `AUTOHEDGE_INTERVAL_SEC` (default 15) — how often the auto sweep runs.

## How the auto math works

Per enabled rule, each sweep:

```
clientNet   = Σ open B-book lots (BUY +, SELL −)        # broker holds the opposite
hedged      = Σ live broker hedge lots on MT5 (signed)
desired     = 0 if |clientNet| ≤ threshold
              else sign(clientNet) · (|clientNet| − threshold)
delta       = desired − hedged   → send a BROKER_AUTO cover for |delta| (BUY if +, SELL if −)
```

So the broker holds the **same** direction as clients' net on MT5 (clients net long → broker buys to cover), leaving up to `threshold` lots warehoused. It only fires when no broker hedge is already in flight on that symbol, and skips deltas below `minClipLots`.

## ⚠️ Test before trusting it with size

This moves real money on MT5. Recommended bring-up:

1. Keep `HedgeEnabled: false` until `DealerSend` is confirmed on your MT5 build.
2. First validate **manual cover** with a tiny lot (e.g. 0.01) and watch it fill on the cover account.
3. Then set **one** symbol's auto rule with a generous threshold and a small `minClipLots`, watch the Broker Hedge Blotter and the MT5 cover account agree.
4. Only then tighten thresholds / add symbols.

If the cover account's MT5 group is **netting** mode, auto-unwind works via opposing market orders. In **hedging** mode you'll accumulate separate positions — use the blotter's **Close** action or netting mode for clean unwinds.

## Rollback

Additive schema — redeploy previous images to roll back. Disable instantly without redeploy: turn off the auto rules in the Net Hedge tab, or set `HedgeEnabled: false` on the bridge.
