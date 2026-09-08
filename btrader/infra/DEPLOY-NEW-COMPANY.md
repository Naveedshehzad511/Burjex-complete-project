# Deploying a new company on its own server

Each company gets a fully isolated B-Trader stack: own VPS, own database, own
domains, own secrets, own feed/cover EA instances. The central Example server
keeps read-only oversight through the HQ dashboard (Admin → Companies (HQ)).

The recipe below is repeatable; nothing in it touches the Example/CRM server.

## 1. Provision the server

- Ubuntu 22.04+ VPS, ≥2 vCPU / 4 GB RAM / 40 GB disk (Hetzner CX22-class is
  fine at launch scale). EU location keeps latency low to the MT5 VPS.
- Install Docker + compose plugin, open 80/443, set up SSH keys.

## 2. DNS (company's domain)

Point at the new server:
- `api.<company>.com`, `ws.<company>.com`, `feed.<company>.com`,
  `admin.<company>.com`

## 3. Create the deploy target + push source

```
cp infra/targets/example.conf.template infra/targets/<company>.conf
# edit: SERVER="root@<new-ip>"
./deploy.sh <company>        # first run builds everything
```

## 4. Server env files (`/root/btrader/infra/` on the new box)

Create fresh `.env` and `.env.prod` (NEVER copy Example's secrets):
- New DB password, JWT access/refresh secrets, `BRIDGE_TOKEN`, `MT5_FEED_TOKEN`.
- `MAX_PRICE_AGE_MS=20000` (same live-price-guard headroom as Example).
- **`HQ_TOKEN=<long random>`** — generate with `openssl rand -hex 24`. This is
  the read-only oversight credential the HQ dashboard uses.
- `LP_BRIDGE_DRIVER=mt5-ingest`.

Generate each secret with `openssl rand -hex 24`.

## 5. Reverse proxy on the new box

The new server runs its OWN Caddy (nothing shared): api./ws./feed./admin.
hostnames → gateway 4100 / ws 4101 / market-data 4200 / admin nginx 80. Copy
the Caddyfile shape from `infra/` docs and let Caddy issue TLS automatically.

## 6. Seed the tenant

On the new server, create the company's tenant + tenant-admin user (adapt
`packages/db/prisma/seed.ts` — change slug/name/emails/passwords, or insert
via psql). Verify login on `admin.<company>.com` after step 8.

## 7. Market data + covers (MT5 side)

On the Windows MT5 VPS (can be shared across companies):
- **Feed**: new chart + `BTraderFeed` instance → `InpFeedHost =
  https://feed.<company>.com`, `InpFeedToken` = the provider feed token created
  in the new admin (Liquidity → Providers), `InpSymbols` = the explicit mapped
  list (NEVER empty — see btrader-ea-feed-cover-ops memory / README).
- **Cover**: new chart + `BTraderCover` instance → `InpApiBase =
  https://api.<company>.com/v1`, that server's `BRIDGE_TOKEN`, the new tenant
  id, and the company's cover provider code.
- Allow-list both new hosts in the terminal's WebRequest settings.

## 8. Apps (per-brand builds)

- Admin web: `flutter build web --release --dart-define-from-file=config/<company>.json`
  (copy `config/prod.json`, set the company's API/WS URLs + tenant slug), rsync
  `build/web/` to the new server's `/root/btrader-admin/`.
- Trader APK: same `--dart-define-from-file` with the company config.

## 9. Register in the HQ dashboard

On admin.example.com (super admin) → **Companies (HQ) → Add company
server**: name, `https://api.<company>.com`, and the `HQ_TOKEN` from step 4.
The dashboard polls `/v1/hq/overview` (read-only aggregate; the token grants
no admin/trading authority).

## 10. Go-live checklist

- [ ] `GET https://api.<company>.com/v1/health` → 200
- [ ] Feed EA streams (`streaming N symbol(s)` log; Spread Monitor live)
- [ ] Symbols mapped (no unexpected "unmapped seen")
- [ ] Trading group + test client created; test order fills
- [ ] A-book routing rule + venue; 0.01-lot cover validates PENDING → FILLED
- [ ] Server shows ONLINE in Companies (HQ)
