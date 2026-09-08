# Burjex / Forexten — Windows Server deploy pack

**English + اردو** · All-in-one: Docker (Linux containers) + native MT5 bridge as a Windows Service.

This pack is **additive**. The existing Linux VPS setup (`187.127.215.195`, `deploy/docker-compose.ip.yml`) is **not** removed or replaced.

---

## ⚠ CRITICAL — always pass `--env-file`

```text
NEVER run:
  docker compose up -d
  docker compose up -d --force-recreate
  docker compose restart …

ALWAYS run the scripts in this folder (they inject --env-file):
  .\up.ps1
  .\recreate.ps1
  .\restart.ps1 caddy
  .\ps.ps1
  .\logs.ps1 btrader-market-data
  .\preflight-feed.ps1
```

**Why:** Compose interpolates `${BT_POSTGRES_*}`, `${BTRADER_DATABASE_URL}`, `${BTRADER_REDIS_URL}`, etc. from `--env-file`.  
Without it those values are **empty** → `btrader-market-data` **crash-loops** → ingest `:4300` **timeouts** → **price stutter**.  
This already happened in production once. Do not repeat it.

Runtime env path (same as Linux IP mode):

```text
deploy\.env.prod.ip
```

**Feed stability:** see [FEED.md](./FEED.md) — ACK-before-fanout, durable candle flush, loopback ingest, one-bridge cutover.

---

## Recommended architecture (same machine)

```text
┌──────────────────────────── Windows Server ────────────────────────────┐
│                                                                          │
│  Docker Desktop (Linux containers / WSL2)                                │
│    Caddy :8000 :4100 :4101 :4200 :4300 :4400                             │
│    CRM (Django + Celery) + Postgres + Redis                              │
│    BTrader (gateway, ws, engine, market-data) + Postgres + Redis         │
│                                                                          │
│  Native Windows                                                          │
│    MT5 Terminal / Manager API                                            │
│    mt5_bridge.py  (NSSM service "BurjexMt5Bridge")                       │
│         │                                                                │
│         └── POST http://127.0.0.1:4300/ingest   (published host port)    │
│         └── REST  http://127.0.0.1:4100/v1      (reconcile / covers)     │
└──────────────────────────────────────────────────────────────────────────┘
```

| Piece | Where it runs | Notes |
|---|---|---|
| CRM + BTrader + DBs | Docker Linux containers | Same `docker-compose.ip.yml` as VPS |
| MT5 + `mt5_bridge.py` | Native Windows | `MT5Manager` is Windows-only |
| Bridge → ingest | `http://127.0.0.1:4300` | Port published by Caddy; **not** `host.docker.internal` |
| Containers → host | N/A for feed | Feed is host → container via published port |

**Hybrid (optional):** Keep stack on Linux VPS; only MT5+bridge on Windows Server. Then set bridge `FeedUrl` / `BridgeApiUrl` to `http://<LINUX_VPS_IP>:4300` and `:4100/v1`, and set `FEED_ALLOWED_IPS` on the VPS to the Windows Server public IP.

---

## Folder layout on the server

Put the three project trees as **siblings** (compose build contexts expect this):

```text
C:\burjex\
  Burjex-Prime-Crm-main\     ← Django CRM code
  btrader\                   ← BTrader monorepo + bridges\
  deploy\                    ← compose + this windows-server\ pack
  web\admin\                 ← Flutter admin build (or placeholder index.html)
  web\trader\                ← Flutter trader build (optional)
```

If your copy lives at `D:\Burjex-Prime-Crm-main\` already containing `Burjex-Prime-Crm-main\`, `btrader\`, `deploy\`, that root is fine — just set `BURJEX_WEB_*` in the env file to matching `web\` paths.

---

## 1) Install Docker Desktop (Linux containers)

**English**

1. Install [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/).
2. Enable **WSL2** backend.
3. Switch to **Linux containers** (not Windows containers) — tray icon → “Switch to Linux containers”.
4. Settings → Resources: give Docker enough RAM/CPU (e.g. 8 GB+ RAM).
5. Confirm: `docker version` and `docker compose version`.

**اردو**

1. Docker Desktop انسٹال کریں۔  
2. WSL2 آن رکھیں، **Linux containers** موڈ استعمال کریں (Windows containers نہیں)۔  
3. `docker compose version` چلا کر تصدیق کریں۔

---

## 2) Copy project + create web folders

```powershell
# Example target
New-Item -ItemType Directory -Force -Path C:\burjex\web\admin, C:\burjex\web\trader | Out-Null

# Copy/clone so that C:\burjex\ contains Burjex-Prime-Crm-main, btrader, deploy
# (robocopy / git — your choice)

# Placeholder HTML so Caddy does not fail if Flutter builds are not ready yet
@'
<!doctype html><title>BTrader Admin</title><h1>Upload Flutter web build here</h1>
'@ | Set-Content C:\burjex\web\admin\index.html
@'
<!doctype html><title>BTrader</title><h1>Upload Flutter web build here</h1>
'@ | Set-Content C:\burjex\web\trader\index.html
```

---

## 3) Environment file

```powershell
cd C:\burjex   # or your repo root

Copy-Item deploy\windows-server\.env.windows-server.example deploy\.env.prod.ip

# Replace YOUR_SERVER_IP with this server's public IP
(Get-Content deploy\.env.prod.ip -Raw) `
  -replace 'YOUR_SERVER_IP','YOUR.PUBLIC.IP.HERE' |
  Set-Content deploy\.env.prod.ip -Encoding utf8 -NoNewline

# Edit and replace every CHANGE_ME (DB passwords, JWT, MT5_FEED_TOKEN, BRIDGE_TOKEN, …)
notepad deploy\.env.prod.ip
```

Also set:

```text
BURJEX_WEB_ADMIN=C:/burjex/web/admin
BURJEX_WEB_TRADER=C:/burjex/web/trader
```

`ENCRYPTION_KEY` must be **exactly 32 characters**.

`FEED_ALLOWED_IPS` for same-machine can stay as in the example (`127.0.0.1` + Docker ranges), or blank for first bring-up.

---

## 4) Firewall

```powershell
# Elevated PowerShell
cd C:\burjex\deploy\windows-server
.\open-firewall.ps1
```

Also open the same ports in Azure NSG / AWS security group / provider panel: **8000, 4100, 4101, 4200, 4300, 4400**.  
If the bridge is only local, you may leave **4300 closed** to the public internet.

---

## 5) Start Docker stack

```powershell
cd C:\burjex\deploy\windows-server
.\up.ps1
.\ps.ps1
```

First build: **10–30 minutes**.

Smoke test:

```powershell
curl.exe -i http://127.0.0.1:8000/health/ready/
curl.exe -i http://127.0.0.1:4100/v1/public/branding -H "X-BT-Tenant: demo"
curl.exe -i http://127.0.0.1:4300/health
```

### DB bootstrap (first time)

```powershell
cd C:\burjex\deploy\windows-server
. .\_compose.ps1

Invoke-BurjexCompose -ComposeArgs @('exec','crm-web','python','manage.py','createsuperuser')

Invoke-BurjexCompose -ComposeArgs @(
  'run','--rm','btrader-gateway',
  'sh','-lc','cd /app/packages/db && npx prisma db push --skip-generate'
)

# First install only — demo tenant:
Invoke-BurjexCompose -ComposeArgs @(
  'run','--rm','btrader-gateway',
  'sh','-lc','cd /app/packages/db && npx prisma db seed'
)
```

> Note: `crm-web` already runs `migrate` + `collectstatic` on start. Gateway compose command also runs `prisma db push` on boot — seed is still one-time.

### Wire CRM ↔ BTrader (admin UI)

| Field | Value |
|---|---|
| Base URL | `http://btrader-gateway:4100` (internal Docker name — **not** public IP) |
| Key / Secret | Create in B-Trader admin → CRM integrations |

Webhook (B-Trader → CRM): `http://YOUR_SERVER_IP:8000/api/btrader/webhook/`  
Secret = `CRM_WEBHOOK_SECRET` from env.

---

## 6) Python + MT5 + bridge service

> **CUTOVER (mandatory):** Stop the **laptop / old-PC bridge completely** before starting `BurjexMt5Bridge` on this server.  
> Two bridges posting ticks = chaos (duplicate / fighting feed). See [FEED.md](./FEED.md).

**English**

1. Install **Python 3.10–3.12 x64**, tick “Add to PATH”.
2. Install MT5 Terminal / Manager files required by your broker.
3. Bridge deps:

```powershell
cd C:\burjex\btrader\bridges\mt5-manager-python
python -m pip install -r requirements.txt
python -c "import MT5Manager; print('MT5Manager OK')"
```

4. Config:

```powershell
Copy-Item C:\burjex\deploy\windows-server\config.windows-server.json.example .\config.json
notepad .\config.json
```

Same-machine values:

| Key | Value |
|---|---|
| `FeedUrl` | `http://127.0.0.1:4300` |
| `FeedToken` | = `MT5_FEED_TOKEN` in `.env.prod.ip` |
| `BridgeApiUrl` | `http://127.0.0.1:4100/v1` |
| `BridgeToken` | = `BRIDGE_TOKEN` |
| `BtTenantId` | `demo` or tenant UUID from admin |
| `TickFlushMs` | `50` |
| `TickHttpTimeoutSec` / `CandleHttpTimeoutSec` | `8` / `15` |
| `ReconcileEnabled` / `GroupsReconcileEnabled` | `false` / `false` |
| `Mt5Server` / login / password | your Manager API credentials |

5. Manual test (before service):

```powershell
python mt5_bridge.py
# Ctrl+C after you see ticks posting without errors
```

6. **Stop laptop bridge first**, then install as service (survives logoff):

```powershell
# Download nssm win64 → deploy\windows-server\tools\nssm\nssm.exe  (see script message)
cd C:\burjex\deploy\windows-server
# Elevated:
.\setup-bridge-service.ps1 -Start
.\preflight-feed.ps1
```

**اردو**

1. Python 3.10–3.12 لگائیں، MT5 Terminal لگائیں۔  
2. `pip install -r requirements.txt` — `MT5Manager` صرف Windows پر چلتا ہے۔  
3. `config.json` میں `FeedUrl=http://127.0.0.1:4300` رکھیں (جب Docker اسی سرور پر ہو)۔  
4. `setup-bridge-service.ps1` سے Windows Service بنائیں تاکہ RDP logoff کے بعد بھی قیمتیں آتی رہیں۔

### Hybrid reminder

اگر CRM/BTrader پرانا Linux VPS (`187.127.215.195`) پر رہیں اور صرف bridge یہاں ہو:

```json
"FeedUrl": "http://187.127.215.195:4300",
"BridgeApiUrl": "http://187.127.215.195:4100/v1"
```

اور VPS پر `FEED_ALLOWED_IPS=<اس Windows Server کا public IP>` سیٹ کر کے Caddy restart کریں (`--env-file` کے ساتھ!)۔

---

## 7) Scripts in this folder

| Script | Purpose |
|---|---|
| `_compose.ps1` | Shared helper — **always** adds `--env-file deploy\.env.prod.ip` |
| `up.ps1` | `up -d --build` |
| `down.ps1` | stop stack |
| `ps.ps1` | status |
| `logs.ps1 [service]` | follow logs |
| `restart.ps1 <svc…>` | restart services |
| `recreate.ps1 [svc…]` | `up -d --force-recreate` **with** env-file |
| `open-firewall.ps1` | inbound TCP rules |
| `setup-bridge-service.ps1` | NSSM install for `mt5_bridge.py` |
| `preflight-feed.ps1` | After up+bridge: `/health` freshness, service Running, FeedUrl sanity |
| `prepare-folders.ps1` | Create `web\admin` / `web\trader` placeholders |
| `FEED.md` | Why feed is stable + ops rules |

---

## 8) Migration from laptop-bridge + Linux VPS

| Step | Action |
|---|---|
| 1 | Bring Windows Server stack up; verify health URLs locally |
| 2 | Point bridge at `127.0.0.1` (all-in-one) **or** keep pointing at VPS (hybrid) |
| 3 | **Stop laptop / old PC bridge FIRST** — then start server bridge. Two bridges = chaos |
| 4 | Run `.\preflight-feed.ps1` — `lastTickAt` must be fresh |
| 5 | If migrating data: `pg_dump` CRM + BTrader on VPS → restore into new containers (plan downtime) |
| 6 | Rebuild Flutter/mobile clients only when public IP/domain changes (not part of this pack) |
| 7 | Update DNS / bookmarks to `YOUR_SERVER_IP` when ready |
| 8 | Keep old VPS until 24–48h stable, then power off |

Linux VPS compose files are untouched. You can keep running the old Linux IP until cutover is done. **Do not** destructively change the live Linux VPS during first Windows bring-up.

---

## 9) Ops cheatsheet

```powershell
cd C:\burjex\deploy\windows-server

.\ps.ps1
.\logs.ps1 btrader-market-data
.\restart.ps1 caddy
.\recreate.ps1 btrader-market-data   # SAFE — includes --env-file

# After git pull / code copy:
.\up.ps1

# Bridge + feed gate
nssm status BurjexMt5Bridge
.\preflight-feed.ps1
Get-Content C:\burjex\btrader\bridges\mt5-manager-python\logs\bridge.out.log -Wait -Tail 40
```

Backups:

```powershell
docker exec crm_postgres pg_dump -U burjexcrm burjexcrm | Out-File -Encoding utf8 crm-$(Get-Date -Format yyyy-MM-dd).sql
docker exec btrader_postgres pg_dump -U btrader btrader | Out-File -Encoding utf8 btrader-$(Get-Date -Format yyyy-MM-dd).sql
```

---

## 10) Troubleshooting

| Symptom | Fix |
|---|---|
| market-data restart loop / empty DATABASE_URL | You ran compose **without** `--env-file`. Use `.\up.ps1` / `.\recreate.ps1` only |
| `:4300` timeouts / price stutter | Fix market-data first; then check bridge service + `FEED_ALLOWED_IPS` |
| `forbidden` on ingest | Source IP not in `FEED_ALLOWED_IPS` — for local bridge include `127.0.0.1` |
| Caddy can’t mount web | Create `web\admin` / `web\trader`; fix `BURJEX_WEB_*` paths (forward slashes) |
| CRM CSRF on login | `DJANGO_CSRF_TRUSTED_ORIGINS` needs `http://IP:8000` |
| WS close 4401 | `JWT_SECRET` mismatch — one env file must feed both gateway and ws |
| Bridge dies on logoff | Not using NSSM service — run `setup-bridge-service.ps1` |
| `MT5Manager` import error | Wrong Python version (use 3.10–3.12 x64) |

---

## What you still need to provide

1. New Windows Server **public IP**  
2. RDP access confirmed  
3. Keep old VPS **or** full migrate?  
4. MT5 Manager host / login (for `config.json`)  
5. Domain later? (TLS = separate `docker-compose.prod.yml` path)

See also: [FEED.md](./FEED.md) · [CHECKLIST.md](./CHECKLIST.md) · [../README-IP.md](../README-IP.md) · [../../btrader/infra/DEPLOY-MT5-BRIDGE.md](../../btrader/infra/DEPLOY-MT5-BRIDGE.md)
