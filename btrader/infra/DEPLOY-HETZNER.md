# Deploying B-Trader on the existing Hetzner box (alongside the Example CRM)

B-Trader co-hosts cleanly with the CRM: it runs its **own** Postgres + Redis +
services, publishes **no host ports** (so nothing collides), and reuses the CRM's
single nginx for TLS by joining the CRM's Docker network. Charts/prices stay on
the built-in mock until you buy a feed.

Files referenced below live in `infra/`:
`docker-compose.prod.yml`, `nginx/btrader.prod.conf`, `.env.prod.example`.

---

## Step 0 — Check capacity

```bash
ssh root@your-hetzner-ip
free -h          # B-Trader adds ~1.5–2 GB RAM (pg + redis + 4 node services)
df -h            # ~3–5 GB disk to start
docker network ls   # confirm the CRM network name (expected: example_network)
```
If the box is ≥ 4 GB RAM with headroom, you're fine for testing. Tight? Resize
the Hetzner server one tier up first (a 5-minute reboot).

> If `docker network ls` shows a different CRM network name, edit the
> `example_network` entry at the bottom of `docker-compose.prod.yml` to match.

## Step 1 — DNS

Add three A records pointing at the **same server IP** (use your real domain):

```
api.btrader.example.com    A   <server-ip>
ws.btrader.example.com     A   <server-ip>
admin.btrader.example.com  A   <server-ip>
```
Wait for propagation (`dig api.btrader.example.com +short`).

## Step 2 — Get the code on the server

```bash
mkdir -p /opt/btrader && cd /opt/btrader
git clone <your-btrader-repo> .
cp infra/.env.prod.example infra/.env.prod
# Fill in every CHANGE_ME (use: openssl rand -hex 32)
nano infra/.env.prod
```

## Step 3 — Bring up the B-Trader stack (own DB/Redis, no host ports)

```bash
cd /opt/btrader
docker compose -f infra/docker-compose.prod.yml --env-file infra/.env.prod up -d --build
docker compose -f infra/docker-compose.prod.yml ps     # all healthy?
```

## Step 4 — Run database migrations + seed (one-off)

```bash
# migrate
docker compose -f infra/docker-compose.prod.yml --env-file infra/.env.prod \
  run --rm --workdir /app/packages/db btrader-gateway \
  npx prisma migrate deploy --schema prisma/schema.prisma

# seed a demo tenant + admin + trader (optional, for first login)
docker compose -f infra/docker-compose.prod.yml --env-file infra/.env.prod \
  run --rm --workdir /app/packages/db btrader-gateway \
  node prisma/seed.js   # or: npx ts-node --transpile-only prisma/seed.ts
```

## Step 5 — TLS certificates for the new subdomains

Your box already has certbot + the webroot (`/var/www/certbot`) and certs in
`/etc/letsencrypt` (mounted into the CRM nginx). Issue certs for the 3 names:

```bash
certbot certonly --webroot -w /var/www/certbot \
  -d api.btrader.example.com -d ws.btrader.example.com -d admin.btrader.example.com
```
(If certbot runs inside a container in your CRM setup, use that same flow.)

## Step 6 — Add the nginx server blocks

```bash
# Replace btrader.example.com with your domain throughout the file first:
sed -i 's/btrader.example.com/btrader.YOURDOMAIN.com/g' infra/nginx/btrader.prod.conf

# Make it visible to the CRM nginx container. Easiest: copy into the CRM's
# conf.d that nginx already mounts, then reload.
cp infra/nginx/btrader.prod.conf /path/to/example-crm/docker/nginx/conf.d/btrader.conf

# Reload the CRM nginx (no downtime):
docker exec example_nginx nginx -t && docker exec example_nginx nginx -s reload
```

> The CRM mounts a single `production.conf` as `default.conf`. If it does **not**
> auto-include other files in `conf.d`, either append the B-Trader `server {}`
> blocks into that file, or add `include /etc/nginx/conf.d/*.conf;` to its
> `http {}` and mount `btrader.conf` alongside it. See the CRM's `nginx.conf`.

## Step 7 — Build + deploy the Flutter web admin (static)

On your dev machine (needs the Flutter SDK):

```bash
cd flutter/apps/admin
flutter build web --release \
  --dart-define=API_BASE=https://api.btrader.YOURDOMAIN.com \
  --dart-define=WS_URL=wss://ws.btrader.YOURDOMAIN.com

# Copy the build to the server folder the nginx admin block serves:
rsync -av build/web/ root@your-hetzner-ip:/var/www/btrader-admin/
```
Mount `/var/www/btrader-admin` into the CRM nginx container (read-only) if it
isn't already, then reload nginx. Visit `https://admin.btrader.YOURDOMAIN.com`.

## Step 8 — Point the mobile trader app at the server

Build with the same URLs and distribute (APK / Firebase App Distribution / TestFlight):

```bash
cd flutter/apps/trader
flutter build apk --release \
  --dart-define=API_BASE=https://api.btrader.YOURDOMAIN.com \
  --dart-define=WS_URL=wss://ws.btrader.YOURDOMAIN.com \
  --dart-define=TENANT=demo
```

## Step 9 — Wire the CRM → B-Trader (internal, no public hop)

Because both stacks share `example_network`, the CRM API can call B-Trader
directly by container name. In the CRM's env, point its trading-backend base URL at:

```
http://btrader-gateway:4100/v1/crm
```
and set the shared `CRM_INTEGRATION_KEY` (HMAC). Public alternative:
`https://api.btrader.YOURDOMAIN.com/v1/crm`.

---

## Operational notes

- **Separation:** B-Trader uses its own Postgres/Redis containers + volumes
  (`btrader_pg`, `btrader_redis`). It never touches the CRM's data.
- **Backups:** add `btrader_pg` to your backup routine, e.g.
  `docker exec btrader_postgres pg_dump -U btrader btrader | gzip > btrader-$(date +%F).sql.gz`.
- **Firewall:** only 80/443 are public (via the single nginx). B-Trader's DB,
  Redis, engine and market-data have no published ports.
- **Update:** `git pull && docker compose -f infra/docker-compose.prod.yml --env-file infra/.env.prod up -d --build`.
- **Logs:** `docker compose -f infra/docker-compose.prod.yml logs -f btrader-gateway`.
- **Latency caveat:** co-hosting is ideal for testing. For production low-latency
  trading with a real LP, move B-Trader to its own box near the liquidity provider
  (the `infra/k8s` manifests are ready for that).
```
