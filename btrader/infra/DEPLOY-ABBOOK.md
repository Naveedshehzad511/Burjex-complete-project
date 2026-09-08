# Deploy update — A/B Book (dealing desk)

Server: `root@YOUR_SERVER_IP`  ·  backend `/root/btrader`  ·  admin `/root/btrader-admin`
Compose: `/root/btrader/infra/docker-compose.prod.yml`

This update adds new Prisma tables (`hedge_orders`, `lp_execution_configs`) and
nullable/defaulted columns. `prisma db push` applies it with **no reset / no data loss**.
The CRM stack is untouched throughout.

---

## 1. Push backend source from your Mac

Run from the repo root on the Mac. `--exclude 'infra/.env.prod'` is REQUIRED so
`--delete` does not wipe the server-only secrets file.

```bash
cd ~/B-Trader/B-Trader
rsync -avz --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'flutter' \
  --exclude 'dist' \
  --exclude '**/build' \
  --exclude '.dart_tool' \
  --exclude 'infra/.env.prod' \
  --exclude 'infra/.env' \
  ./ root@YOUR_SERVER_IP:/root/btrader/
```

> IMPORTANT: both `infra/.env` (compose `${VAR}` interpolation) and
> `infra/.env.prod` (container `env_file`) live ONLY on the server. They MUST be
> excluded, or `--delete` wipes them and Postgres/Redis come up with blank
> credentials. If `.env` ever goes missing: `cp infra/.env.prod infra/.env`.

## 2. Rebuild + migrate + restart (on the server)

```bash
ssh root@YOUR_SERVER_IP
cd /root/btrader/infra

# Rebuild all images (regenerates the Prisma client + compiles the new TS).
docker compose -f docker-compose.prod.yml build

# Bring DB/Redis up first so the schema push has a target.
docker compose -f docker-compose.prod.yml up -d btrader-postgres btrader-redis
sleep 5

# Apply the schema (creates the 2 new tables + new columns). No reset.
docker compose -f docker-compose.prod.yml run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && npx prisma db push --skip-generate'

# Roll out the rest.
docker compose -f docker-compose.prod.yml up -d

# Sanity check.
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs --tail=40 btrader-gateway btrader-engine
```

Look for `A-book bridges configured` / `engine ready (... A-book router)` in the logs.

## 3. Rebuild + push the admin web (from your Mac)

The Dealing page lives in the admin app.

```bash
cd ~/B-Trader/B-Trader/flutter/apps/admin
flutter build web --release

rsync -avz --delete build/web/ root@YOUR_SERVER_IP:/root/btrader-admin/
```

nginx serves the files from a read-only volume, so no container restart is needed —
just hard-refresh `https://admin.example.com` (Cmd/Ctrl+Shift+R).

> The trader mobile app does NOT need rebuilding for this change (the `book`
> field it now parses is optional and unused on the client).

---

## 4. Smoke test the A/B book

1. Admin → **Dealing (A/B)** → LP bridge: driver **Mock**, **enabled**, Save → "Bridge active".
2. Set a test client to book **A**; leave another on **B**.
3. Place a trade from each client (phone or admin).
4. The A-book trade appears in the **A-book cover blotter** as `FILLED` and is
   excluded from **net B-book exposure**; the B-book trade shows up in exposure.
5. Set the bridge's **Sim reject %** to ~50 and trade again to see the
   `REJECTED` cover + "Covers REJECTED" alert (broker-exposed path).

## Rollback

Schema change is additive, so rollback = redeploy the previous images. The new
tables/columns can stay (ignored by old code). No data migration to reverse.
```
