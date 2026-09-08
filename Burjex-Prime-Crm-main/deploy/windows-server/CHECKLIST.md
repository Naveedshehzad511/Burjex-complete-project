# Windows Server — prerequisites & go-live checklist

## Prerequisites (hardware / OS)

| Item | Recommendation |
|---|---|
| OS | **Windows Server 2019 / 2022 / 2025** (Desktop Experience preferred for MT5 UI) |
| CPU | 8+ vCPU (4 minimum; first Docker build is heavy) |
| RAM | **32 GB** recommended (16 GB absolute minimum for CRM+BTrader+MT5) |
| Disk | 100+ GB SSD free (images + Postgres volumes + MT5 history) |
| Network | Public IP + RDP (3389) locked to your IPs |
| Docker | **Docker Desktop for Windows** → **Linux containers** (WSL2 backend) |
| Python | **3.10–3.12 x64** (MT5Manager does not support 3.13+) |
| MT5 | MetaTrader 5 Terminal + Manager API build matching your broker |
| NSSM | [nssm.cc](https://nssm.cc/download) win64 (for bridge Windows Service) |

## Ports to open (Windows Firewall + cloud NSG)

| Port | Service |
|---|---|
| 8000/tcp | Django CRM |
| 4100/tcp | B-Trader REST |
| 4101/tcp | B-Trader WebSocket |
| 4200/tcp | B-Trader admin (static) |
| 4300/tcp | MT5 ingest (can stay closed publicly if bridge is local-only) |
| 4400/tcp | B-Trader web trader (optional) |

Do **not** publish 5432 / 6379.

## Startup order

1. Docker Desktop running (Linux engine)
2. `deploy\windows-server\up.ps1`  ← always uses `--env-file`
3. Wait until `crm_web` healthy + `curl http://127.0.0.1:4300/health`
4. MT5 Terminal logged in (if required by your Manager API setup)
5. **Stop laptop / old bridge** (mandatory — two bridges = chaos)
6. Start `BurjexMt5Bridge` service (NSSM)
7. `.\preflight-feed.ps1` — `lastTickAt` fresh + service Running
8. Confirm ticks: `.\logs.ps1 btrader-market-data`

See [FEED.md](./FEED.md) for why this path does not stutter like laptop→VPS.

## Critical compose rule

```
NEVER:  docker compose up -d --force-recreate
ALWAYS: .\deploy\windows-server\up.ps1
        .\deploy\windows-server\recreate.ps1
        (these inject --env-file deploy\.env.prod.ip)
```

Missing `--env-file` → empty `BT_*` / `DATABASE_URL` / `REDIS_URL` → **market-data crash-loop** → **:4300 timeouts** → **price stutter**.

## Go-live checks

- [ ] Folder layout: `Burjex-Prime-Crm-main\`, `btrader\`, `deploy\`, `web\admin\`, `web\trader\` under e.g. `C:\burjex\`
- [ ] `deploy\.env.prod.ip` filled — no `CHANGE_ME`, no `YOUR_SERVER_IP`
- [ ] `BURJEX_WEB_ADMIN` / `BURJEX_WEB_TRADER` point at real folders (forward slashes)
- [ ] Firewall + cloud NSG ports open
- [ ] `.\up.ps1` completed; `.\ps.ps1` all Up / healthy
- [ ] `curl http://127.0.0.1:8000/health/ready/` → ready
- [ ] `curl http://127.0.0.1:4300/health` → ok
- [ ] CRM admin styled (Caddy serving `/static`)
- [ ] Prisma seed / superuser done (see README)
- [ ] CRM ↔ BTrader integration Base URL = `http://btrader-gateway:4100`
- [ ] Bridge `config.json`: `FeedUrl=http://127.0.0.1:4300`, `TickFlushMs=50`, reconcile flags false, tokens match env
- [ ] Old laptop bridge **stopped BEFORE** server bridge start
- [ ] NSSM service `BurjexMt5Bridge` Running after logoff test
- [ ] `.\preflight-feed.ps1` passed (`lastTickAt` fresh)
- [ ] Ticks in `btrader-market-data` logs; quotes move in admin
- [ ] Decision recorded: keep old Linux VPS or decommission after cutover

## Info still needed from you

- [ ] New Windows Server **public IP**
- [ ] Domain? (if yes, plan TLS migrate later — not required for IP mode)
- [ ] RDP access confirmed
- [ ] Keep **187.127.215.195** Linux VPS live during cutover, or migrate and shut down?
- [ ] MT5 server host:port + Manager login (for bridge `config.json`)
- [ ] Whether Flutter web builds already exist to drop into `web\admin` / `web\trader`
