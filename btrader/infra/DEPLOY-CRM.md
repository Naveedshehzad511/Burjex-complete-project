# Deploy — per-tenant CRM config + account-login + JPY/session fixes + trader UI

This rollout ships:

- **Schema:** `CrmConfig` table (per-tenant webhook), `ApiKey.secret`, `Account.passwordHash`.
- **Gateway:** `/v1/auth/account-login` (login number + password), `/admin/crm/config` + `/admin/crm/keys`, per-key HMAC secret, CRM `password`/`createAccount` store hashed password, non-rotating refresh.
- **Engine:** per-tenant webhook delivery (always-on outbox worker), JPY/cross FX margin & P/L fix.
- **Admin web:** CRM / Integrations page.
- **Trader app:** account-number login, 5-tab nav, Portfolio/History/Settings redesign, trade toast, per-pair chart trades, 401 auto-refresh.

`prisma db push` only adds nullable/defaulted columns + new tables — **no reset, no data loss.**

## 1. Sync code to the server (from your Mac)

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

> `infra/.env` and `infra/.env.prod` live ONLY on the server — keep them excluded or `--delete` wipes the DB/Redis credentials. If `.env` goes missing: `cp infra/.env.prod infra/.env`.

## 2. Rebuild + migrate + restart (on the server)

```bash
ssh root@YOUR_SERVER_IP
cd /root/btrader/infra

# Rebuild images (regenerates the Prisma client + compiles new TS).
docker compose -f docker-compose.prod.yml build

# DB/Redis up first so the schema push has a target.
docker compose -f docker-compose.prod.yml up -d btrader-postgres btrader-redis
sleep 5

# Apply schema: CrmConfig table + ApiKey.secret + Account.passwordHash. No reset.
docker compose -f docker-compose.prod.yml run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && npx prisma db push --skip-generate'

# Roll out the rest.
docker compose -f docker-compose.prod.yml up -d

# Sanity check.
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs --tail=40 btrader-gateway btrader-engine
```

Look for the engine line `CRM outbox worker active (per-tenant webhooks)`.

## 3. Rebuild + push the admin web (from your Mac)

```bash
cd ~/B-Trader/B-Trader/flutter/apps/admin
flutter build web --release --dart-define-from-file=config/prod.json
rsync -avz --delete build/web/ root@YOUR_SERVER_IP:/root/btrader-admin/
```

Hard-refresh `https://admin.example.com` (Cmd/Ctrl+Shift+R). The new **CRM / Integrations** item appears under Administration.

## 4. Rebuild the trader APK (from your Mac)

Required this round — account-number login, the UI overhaul, JPY/session fixes are all client-side.

```bash
cd ~/B-Trader/B-Trader/flutter/apps/trader
flutter build apk --release --dart-define-from-file=config/prod.json
# Output: build/app/outputs/flutter-apk/app-release.apk  → distribute
```

## 5. First-time tenant wiring (in the admin dashboard)

1. Open **CRM / Integrations**.
2. *New key* → copy the `keyId` + `secret` into the CRM (secret shown once).
3. Set the webhook URL + signing secret, toggle **Enabled**.
4. CRM provisions accounts via `POST /v1/crm/accounts` (B-Trader returns the 6-digit login; CRM sends the password). See `docs/11-crm-integration.md`.

## Rollback

`prisma db push` is additive, so rolling back code is safe — redeploy the previous image tag and the new columns simply go unused.
