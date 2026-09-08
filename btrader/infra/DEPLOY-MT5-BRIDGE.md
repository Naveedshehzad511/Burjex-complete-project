# Deploy update — MT5 bridge: symbol/group auto-sync + A-book covers

Server: `root@YOUR_SERVER_IP` · backend `/root/btrader` · compose `infra/docker-compose.prod.yml`
Bridge: runs on the **Windows MT5 VPS** (`bridges/mt5-manager-python/`).

This update adds:

- **Schema** — `LpExecDriver.MT5`, `HedgeStatus.CLOSE_PENDING` (additive enum values, no data loss).
- **Gateway** — new `/bridge/*` endpoints (symbol reconcile, group reconcile, A-book cover relay), guarded by a new `BRIDGE_TOKEN`.
- **Engine** — A-book covers on the `MT5` driver are left PENDING for the bridge to execute (async venue).
- **Bridge** — two new workers: symbol/group reconcile, and A-book cover execution via `DealerSend`.

`prisma db push` applies the enum changes with **no reset**. CRM stack untouched.

---

## 1. Add the bridge token on the server (one-time)

```bash
ssh root@YOUR_SERVER_IP "grep -q '^BRIDGE_TOKEN=' /root/btrader/infra/.env.prod || \
  echo \"BRIDGE_TOKEN=$(openssl rand -hex 24)\" >> /root/btrader/infra/.env.prod; \
  grep '^BRIDGE_TOKEN=' /root/btrader/infra/.env.prod"
```

Copy the printed `BRIDGE_TOKEN` value — you'll paste it into the bridge's `config.json` (`BridgeToken`).

## 2. Deploy backend (from your Mac)

```bash
./deploy.sh
```

(Runs the rsync + rebuild + `prisma db push` + restart. `db push` will report the two new enum values.)

## 3. Update the bridge on the MT5 VPS

Pull the updated `bridges/mt5-manager-python/` to the VPS, then edit `config.json`:

| key | value |
|-----|-------|
| `BridgeApiUrl` | `https://api.example.com/v1` (gateway base — the `/v1` prefix is required) |
| `BridgeToken`  | the `BRIDGE_TOKEN` from step 1 |
| `BtTenantId`   | the tenant these symbols/covers belong to |
| `ReconcileEnabled` | `true` to auto-sync symbols + groups |
| `EnableClasses` | e.g. `"FOREX,CRYPTO"` — classes auto-enabled on import (blank = all imported hidden) |
| `HedgeEnabled` | `true` to execute A-book covers on MT5 |
| `Mt5CoverLogin` | MT5 account login used to place cover trades |
| `SymbolSuffixStrip` | broker suffix (e.g. `.r`) so names match B-Trader |

Restart the bridge:

```powershell
python mt5_bridge.py
```

Look for `symbol/group reconcile worker started` and (if enabled) `A-book hedge worker started`.

## 4. Turn on the MT5 A-book venue (admin)

In B-Trader admin → **Dealing (A/B)**, set the LP execution driver to **MT5** and **enabled**. Then any client on book **A** has its fills covered on MT5 by the bridge.

---

## Notes & caveats

- **`DealerSend` needs a dealer-gateway entitlement** on your MT5 license. If your `MT5Manager` build doesn't expose it, the cover stays PENDING and is reported as rejected (broker exposed + alerted) rather than silently filled. Validate with `python -c "import MT5Manager; help(MT5Manager.ManagerAPI)"` and adjust `dealer_send`/`dealer_close` if the method/enum names differ on your build.
- **Symbol reconcile never flips `enabled`** on existing symbols — it only refreshes contract specs. New pairs are created hidden unless their class is in `EnableClasses`. Admin stays in control of what clients see.
- **Group reconcile** only creates missing trading groups; it never deletes or modifies existing ones.
- `BRIDGE_TOKEN` is separate from `MT5_FEED_TOKEN` on purpose — the low-risk price-feed secret never gains symbol/group/hedge authority.

## Rollback

Enum additions are additive — rollback = redeploy previous images. Set `ReconcileEnabled` / `HedgeEnabled` to `false` in the bridge config to disable the new workers without touching the backend.
