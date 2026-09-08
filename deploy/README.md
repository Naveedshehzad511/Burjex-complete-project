# Burjex Prime — single-server production deployment

Runs the **Django CRM** and the **B-Trader** trading platform together on one
Ubuntu 22.04/24.04 VPS, behind one Caddy that terminates TLS for every hostname
and proxies WebSockets with buffering and timeouts disabled.

**No domain yet, only an IP?** Let's Encrypt cannot issue a certificate for an
IP address, so this setup will not start. Use
[README-IP.md](README-IP.md) instead — same stack, plain HTTP, one port per
service — and come back here once DNS points at the box.

This folder does not replace [`btrader/infra/`](../btrader/infra/) — it composes
it. The B-Trader service definitions, build args and env names here are copied
from `btrader/infra/docker-compose.prod.yml`; that file remains the reference
for deploying B-Trader *next to an existing CRM nginx*. Use this folder when you
are standing up **both** stacks on a fresh box.

---

## 1. What runs

| Container | Image / build | Port (internal) | Public hostname |
|---|---|---|---|
| `burjex_caddy` | caddy:2-alpine | 80, 443 | all of them |
| `crm_web` | `deploy/crm/Dockerfile` | 8000 | `crm.` |
| `crm_worker` | same image | — | — |
| `crm_beat` | same image | — | — |
| `crm_postgres` | postgres:16-alpine | 5432 | — |
| `crm_redis` | redis:7-alpine | 6379 | — |
| `btrader_gateway` | `btrader/infra/Dockerfile` (`gateway-api`) | 4100 | `api.` |
| `btrader_ws` | `btrader/infra/Dockerfile` (`ws-gateway`) | 4101 | `ws.` |
| `btrader_engine` | `btrader/infra/Dockerfile` (`trading-engine`) | — | — |
| `btrader_market_data` | `btrader/infra/Dockerfile` (`market-data`) | 4200 (ingest) | `feed.` |
| `btrader_postgres` | postgres:16-alpine | 5432 | — |
| `btrader_redis` | redis:7-alpine | 6379 | — |
| B-Trader admin / web trader | static Flutter web build | — | `admin.` / `app.` |

Only Caddy publishes host ports. Everything else is reachable solely on private
Docker networks.

Two corrections to the port list you may be carrying from elsewhere:

- **MT5 ingest is 4200, not 4103.** `btrader/infra/docker-compose.prod.yml` sets
  `MT5_INGEST_PORT: '4200'`; the engine has no port of its own (it is a pure
  Redis/Postgres worker).
- **The admin dashboard is not a service on 4200.** It is a static Flutter web
  bundle. The upstream infra serves it from a small nginx container; here Caddy
  serves the files directly, which removes a container.

### Resources

Two Postgres and two Redis instances is deliberate — it is how the upstream
B-Trader compose isolates the trading ledger from CRM data, and it keeps a CRM
migration from ever touching the trading DB. Budget **8 GB RAM / 4 vCPU / 80 GB
SSD**. It will boot on 4 GB, but Postgres, the JIT-warm Node services and a
Flutter web build will contend.

---

## 2. Domain layout (recommended)

Subdomains, not paths. Point all of these at the same server IP:

```
crm.burjexprime.com      A   <server-ip>   Django CRM (portal, admin, /api/v1, live chat WS)
api.burjexprime.com      A   <server-ip>   B-Trader REST gateway  :4100
ws.burjexprime.com       A   <server-ip>   B-Trader WebSocket     :4101   ← realtime feed
admin.burjexprime.com    A   <server-ip>   B-Trader admin (Flutter web)
app.burjexprime.com      A   <server-ip>   B-Trader web trader (optional)
feed.burjexprime.com     A   <server-ip>   MT5 tick ingest        :4200
```

**Why not one domain with paths.** The ws-gateway listens on the *root* path and
authenticates from the `?token=` query string
(`btrader/apps/ws-gateway/src/main.ts`), and the Flutter clients build their URL
as `'$wsUrl?token=…'` with no path segment. A `/ws` prefix would need rewriting
on the proxy and a client change. B-Trader also resolves the tenant from the
Host header in production, which subdomains give you for free. Caddy issues a
certificate per hostname automatically, so the extra names cost nothing.

---

## 3. Server prep

```bash
ssh root@<server-ip>

apt update && apt upgrade -y
timedatectl set-timezone UTC

# Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sh
docker compose version

# Firewall: only SSH + HTTP/HTTPS. Every service port stays private.
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp          # HTTP/3
ufw --force enable

# Swap helps on 4–8 GB boxes during Docker builds.
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Do **not** open 4100/4101/4200/5432/6379. Caddy is the only ingress.

## 4. Get the code up

```bash
mkdir -p /opt/burjex && cd /opt/burjex
git clone <your-repo-url> .
# or from your machine:
#   rsync -avz --delete --exclude '.git' --exclude 'node_modules' \
#     --exclude '**/build' --exclude '.dart_tool' --exclude 'deploy/.env.prod' \
#     ./ root@<server-ip>:/opt/burjex/
```

`deploy/.env.prod` must be excluded from every rsync or `--delete` will wipe
your credentials.

## 5. Fill the environment

```bash
cd /opt/burjex
cp deploy/.env.prod.example deploy/.env.prod
chmod 600 deploy/.env.prod

# Generate each secret:
openssl rand -hex 32     # DJANGO_SECRET_KEY, JWT_SECRET, JWT_REFRESH_SECRET, CRM_WEBHOOK_SECRET
openssl rand -hex 24     # MT5_FEED_TOKEN, BRIDGE_TOKEN
openssl rand -hex 16     # the Postgres / Redis passwords

nano deploy/.env.prod    # replace every CHANGE_ME, set the real domains
```

Two values that must be consistent or things fail in confusing ways:

- `JWT_SECRET` is read by both `gateway-api` and `ws-gateway`. If they differ,
  REST works and **every WebSocket closes with code 4401**.
- The password inside `DATABASE_URL` must equal `BT_POSTGRES_PASSWORD`, and the
  ones inside `REDIS_URL` / `CELERY_BROKER_URL` / `CHANNELS_REDIS_URL` must equal
  `CRM_REDIS_PASSWORD`.

## 6. Build and start

Validate the config first — this catches a typo'd variable or a bad Caddyfile
in seconds instead of halfway through a ten-minute build:

```bash
cd /opt/burjex
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod config >/dev/null && echo "compose OK"
docker run --rm -v "$PWD/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

`caddy validate` will warn about the `{$VAR}` placeholders being empty when run
this way — that is expected, since it does not load `.env.prod`. Syntax errors
are what you are looking for.

Then build and start:

```bash
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod up -d --build
docker compose -f deploy/docker-compose.prod.yml ps
```

The first build compiles the B-Trader pnpm monorepo four times (one image per
service, sharing cache layers) — expect 10–20 minutes on a 4 vCPU box.

`crm-web` runs `migrate` and `collectstatic` itself on every start, so the CRM
schema is created on first boot. B-Trader's Prisma schema is not, so apply it
once:

```bash
cd /opt/burjex
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod \
  run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && npx prisma migrate deploy --schema prisma/schema.prisma'

# First install only — creates a tenant + admin so you can sign in:
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod \
  run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && node prisma/seed.js'
```

If `migrate deploy` reports no migration directory, this repo's B-Trader tracks
schema with push instead — use
`npx prisma db push --skip-generate`, which the existing
[`btrader/infra/DEPLOY-CRM.md`](../btrader/infra/DEPLOY-CRM.md) also uses. It is
additive and will not reset data.

Create the CRM superuser:

```bash
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod \
  exec crm-web python manage.py createsuperuser
```

## 7. TLS

Nothing to do. Caddy requests and renews a certificate for each hostname on
first request, using `ACME_EMAIL`. Confirm:

```bash
docker compose -f deploy/docker-compose.prod.yml logs -f caddy   # look for "certificate obtained"
curl -I https://crm.burjexprime.com/
```

DNS must already resolve to the server before the first hit, or the challenge
fails. While testing, uncomment `acme_ca` (staging) in the `Caddyfile` to avoid
Let's Encrypt rate limits.

## 8. Wire the CRM to B-Trader

The CRM reads its gateway settings from the database, not from env — set them in
the CRM admin UI (Integrations → trading platform **BTRADER**):

| Field | Value |
|---|---|
| Base URL | `http://btrader-gateway:4100` |
| Key ID | the `keyId` from B-Trader admin → CRM / Integrations → *New key* |
| Secret | the `secret` shown once when that key is created |

The base URL stays **internal** — CRM and gateway share the `edge` network, so
the call never leaves the host. `btrader_integration/client.py` appends `/v1`
itself, so do not include it. Signing is
`HMAC_SHA256(secret, "{timestamp}.{rawBody}")` over the headers `X-BT-Key`,
`X-BT-Timestamp`, `X-BT-Signature`.

In the B-Trader admin, set the outbound webhook to:

```
https://crm.burjexprime.com/api/btrader/webhook/
```

with the signing secret matching `CRM_WEBHOOK_SECRET`. That is the route
registered in `config/urls.py`, and it is what keeps the CRM database in sync
for admin screens and reports.

Then press **Test connection** in the CRM. It calls `GET /v1/crm/groups` and
should report the number of trading groups.

## 9. Flutter web builds (admin + web trader)

Built on your machine (the server has no Flutter SDK), then copied to the paths
Caddy serves:

```bash
# B-Trader admin
cd btrader/flutter/apps/admin
flutter build web --release \
  --dart-define=API_BASE=https://api.burjexprime.com \
  --dart-define=WS_URL=wss://ws.burjexprime.com
rsync -avz --delete build/web/ root@<server-ip>:/opt/burjex/web/admin/

# B-Trader web trader (optional)
cd ../trader
flutter build web --release \
  --dart-define=API_BASE=https://api.burjexprime.com \
  --dart-define=WS_URL=wss://ws.burjexprime.com
rsync -avz --delete build/web/ root@<server-ip>:/opt/burjex/web/trader/
```

Create the directories once with `mkdir -p /opt/burjex/web/{admin,trader}` before
the first rsync.

## 10. Mobile APKs

Both apps must be built with `https://` and `wss://` — a release Android build
blocks cleartext, so an `http://` or `ws://` define fails silently at runtime.

**CRM app (`forexten_mobile`)** talks to both backends. `API_BASE_URL` must
include the `/api/v1` prefix, because the default in `api_config.dart` bakes it
in and the override replaces the whole string:

```bash
cd forexten_mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://crm.burjexprime.com/api/v1 \
  --dart-define=API_BASE=https://api.burjexprime.com \
  --dart-define=WS_URL=wss://ws.burjexprime.com \
  --dart-define=TENANT=burjex
# build/app/outputs/flutter-apk/app-release.apk
```

**B-Trader standalone trader app:**

```bash
cd btrader/flutter/apps/trader
flutter build apk --release \
  --dart-define=API_BASE=https://api.burjexprime.com \
  --dart-define=WS_URL=wss://ws.burjexprime.com \
  --dart-define=TENANT=burjex
```

`WS_URL` has **no path and no trailing slash** — `MarketSocket` appends
`?token=…` directly.

For an app-store build prefer `--dart-define-from-file=config/prod.json`, the
pattern the existing B-Trader deploy docs use.

---

## 11. The MT5 bridge runs on Windows — not on this server

This is a hard constraint, not a preference. The bridge in
`btrader/bridges/mt5-manager-python/` imports **`MT5Manager`**, the MetaQuotes
Manager API, which ships as a Windows-only binary. There is no Linux build, and
neither Wine nor a container changes that. The same applies to a tick-pushing
Expert Advisor, which needs an MT5 terminal.

So the topology is: **Linux VPS** runs everything in this compose file, and a
**small Windows VPS** (2 vCPU / 4 GB is plenty, ideally near your MT5 server)
runs the bridge and pushes ticks out over HTTPS.

On the Windows box, in the bridge's `config.json`:

| Key | Value |
|---|---|
| `FeedUrl` | `https://feed.burjexprime.com/ingest` |
| `InpToken` / feed token | must equal `MT5_FEED_TOKEN` in `.env.prod` |
| `BridgeApiUrl` | `https://api.burjexprime.com/v1` (the `/v1` is required) |
| `BridgeToken` | must equal `BRIDGE_TOKEN` in `.env.prod` |
| `BtTenantId` | the tenant these symbols and covers belong to |
| `SymbolSuffixStrip` | broker suffix, e.g. `.r`, so `EURUSD.r` → `EURUSD` |
| `ReconcileEnabled` | `true` to auto-sync symbols and groups |

Then set `FEED_ALLOWED_IPS` in `.env.prod` to the Windows VPS public IP so Caddy
rejects everyone else at the edge; the token still guards the endpoint too.
`MT5_FEED_TOKEN` and `BRIDGE_TOKEN` are separate on purpose — the low-risk price
token never gains symbol, group or hedge authority.

Details for the reconcile and A-book workers are in
[`btrader/infra/DEPLOY-MT5-BRIDGE.md`](../btrader/infra/DEPLOY-MT5-BRIDGE.md).

**Without the bridge running there are no prices.** `LP_BRIDGE_DRIVER` is
deliberately not defaulted to `mock`: an empty value means no feed rather than
fake prices reaching real clients. Set it to `mock` only to smoke-test a fresh
install, and change it back.

---

## 12. Realtime: how a price and a balance reach the app

See [REALTIME.md](REALTIME.md) for the full path and the proxy settings that
keep it instant.

---

## 13. Go-live checklist

Infrastructure

- [ ] All six DNS records resolve to the server (`dig +short crm.burjexprime.com`)
- [ ] `docker compose ps` shows every container healthy
- [ ] Caddy obtained a certificate for each hostname
- [ ] `ufw status` lists only 22, 80, 443
- [ ] `deploy/.env.prod` is `chmod 600` and untracked; no `CHANGE_ME` remains

Feed

- [ ] Windows MT5 VPS reachable and the bridge process running
- [ ] `LP_BRIDGE_DRIVER=mt5-ingest` (not `mock`, not empty)
- [ ] `FEED_ALLOWED_IPS` set to the bridge IP
- [ ] Ticks arriving: `docker compose logs -f btrader-market-data`
- [ ] Symbols imported and the intended classes enabled in B-Trader admin
- [ ] The feed provider is set as **primary** in admin

B-Trader

- [ ] Admin login works at `https://admin.burjexprime.com`
- [ ] Quotes move in the admin market watch
- [ ] A test order fills and appears in the ledger

CRM

- [ ] `curl https://crm.burjexprime.com/health/ready/` returns `{"status":"ready"}`
- [ ] Superuser can sign in at `https://crm.burjexprime.com`
- [ ] Static and media files load (they come from Caddy, not Django)
- [ ] Integrations → **Test connection** returns the trading group count
- [ ] `crm_beat` and `crm_worker` logs are clean
- [ ] Live chat connects (proves the Django Channels WS path works)

End to end

- [ ] Create a trading account from the CRM → it appears in B-Trader admin
- [ ] Approve a deposit in the CRM → balance changes in B-Trader
- [ ] Open a position → CRM reflects it via the webhook
- [ ] On the phone: open a position and confirm equity and floating P/L move
      continuously, with no 2-second step

Operations

- [ ] Both Postgres volumes are in a backup job
- [ ] `docker compose logs` reviewed for stack traces

---

## 14. Operations

```bash
cd /opt/burjex
C="docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod"

$C ps
$C logs -f btrader-ws          # WebSocket connects/disconnects
$C logs -f btrader-market-data # incoming ticks
$C logs -f crm-web

# Update
git pull && $C up -d --build

# Django management
$C exec crm-web python manage.py createsuperuser
$C exec crm-web python manage.py shell

# Backups (both databases)
docker exec crm_postgres pg_dump -U burjexcrm burjexcrm | gzip > crm-$(date +%F).sql.gz
docker exec btrader_postgres pg_dump -U btrader btrader | gzip > btrader-$(date +%F).sql.gz
```

### Notes on changes this deployment required

`config/settings.py` shipped with SQLite hardcoded and an in-memory Channels
layer, neither of which survives a multi-worker production process. Three
additive, backward-compatible switches were added — with the new variables
unset, local development behaves exactly as before:

- `POSTGRES_DB` set → Postgres with `CONN_MAX_AGE`; unset → SQLite as before.
- `CHANNELS_REDIS_URL` set → `RedisChannelLayer`; unset → in-memory as before.
- `DJANGO_COOKIE_SECURE=1` marks session and CSRF cookies Secure, and
  `DJANGO_CSRF_TRUSTED_ORIGINS` appends production origins to the built-in list.

Two more files outside this folder support the build:

- `Burjex-Prime-Crm-main/.dockerignore` — keeps `venv/`, `db.sqlite3`, `media/`
  and `staticfiles/` out of the image. Without it, a developer's local SQLite
  database would be baked into the production container.
- `Burjex-Prime-Crm-main/requirements.txt` — `channels` was added, because
  `config/asgi.py` imports it but it was not listed. The image additionally
  installs `gunicorn`, `uvicorn`, `channels-redis` and `certifi`, which are
  deployment concerns rather than application dependencies.
