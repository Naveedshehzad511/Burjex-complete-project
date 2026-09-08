# Burjex Prime — deploying with an IP only (no domain, no TLS)

Companion to [README.md](README.md). Use **this** file when the server has a
bare public IP and no DNS yet; use the main README once you own a domain.

Three files make up this mode, and none of them touch the domain setup:

| File | Purpose |
|---|---|
| `deploy/docker-compose.ip.yml` | the whole stack, standalone (one `-f`) |
| `deploy/Caddyfile.ip` | plain-HTTP edge, one listener per service |
| `deploy/.env.prod.ip.example` | env template with IP placeholders |

---

## ⚠ Read this before anything else

Everything here runs over **plain HTTP**. Let's Encrypt cannot issue a
certificate for an IP address — it validates domain names, and there is no
domain to validate — so `auto_https off` is not a shortcut, it is the only
thing that will boot.

The consequence is that logins, JWTs, the MT5 feed token and every tick cross
the internet in the clear. Anyone between the client and the VPS can read them
and replay them.

**This is fine for your own testing. It is not fine for real clients.** Buy a
domain, point an A record at this box, and move to `docker-compose.prod.yml` +
`Caddyfile` before onboarding anyone. Section 13 covers that switch — it is
about ten minutes of work, and no data is lost.

---

## 1. Ports

Routing is **by port**, not by hostname or path.

| Host port | Reached as | Serves | Backend |
|---|---|---|---|
| `8000` | `http://IP:8000` | Django CRM: portal, `/admin`, `/api/v1`, `/static`, `/media`, live-chat WS | `crm-web:8000` |
| `4100` | `http://IP:4100` | B-Trader REST gateway (`/v1`, Swagger at `/docs`) | `btrader-gateway:4100` |
| `4101` | `ws://IP:4101` | B-Trader WebSocket (prices, account, positions) | `btrader-ws:4101` |
| `4200` | `http://IP:4200` | B-Trader admin dashboard (static Flutter web) | Caddy `file_server` |
| `4300` | `http://IP:4300/ingest` | MT5 tick ingest | `btrader-market-data:4200` |
| `4400` | `http://IP:4400` | B-Trader web trader (static Flutter web, optional) | Caddy `file_server` |

### The 4200 conflict, resolved

There were two different claims floating around about port 4200. Both are half
right, and the code settles it:

- **MT5 ingest really is 4200 inside its container.**
  `apps/market-data/src/main.ts` reads `MT5_INGEST_PORT ?? 4200`, and
  `docker-compose.prod.yml` sets `'4200'`. It is not 4103.
- **The admin dashboard was never on 4200.** It is a static Flutter web bundle,
  not a service. The local dev compose publishes it on host **8080**
  (`ports: ['8080:80']` in `btrader/infra/docker-compose.yml`); the TLS setup
  serves the files from Caddy with no port of its own.

In IP mode both need a host port, so: **admin keeps 4200** (the number people
already associate with it) and **ingest is published on 4300**. The container's
internal port is untouched at 4200 — only the host-side mapping changed, so
nothing in the market-data service or the bridge protocol differs.

### Why Caddy is still here

Direct `ports:` on each container would be simpler, but it breaks the CRM: this
Django project has **no WhiteNoise**, so with `DEBUG=0` it serves neither
`/static` nor `/media` — the admin would load with no CSS and every uploaded
file would 404. Caddy serves both straight off the shared volumes. It also
keeps the WebSocket transport tuning (`read_timeout 0`, `flush_interval -1`)
that stops an idle price socket from being torn down.

### Why port-based and not path-based

The ws-gateway listens on the **root** path and authenticates from the
`?token=` query string (`apps/ws-gateway/src/main.ts`), and the Flutter clients
build their URL as `'$wsUrl?token=…'` with no path segment. Putting it behind a
`/ws` prefix would need URL rewriting on the proxy *and* a client change. One
port per service avoids both.

### Tenant resolution without a Host header

`apps/gateway-api/src/common/tenant.middleware.ts` resolves the tenant in this
order: **`X-BT-Tenant` header → Host match → `?tenant=` query**. The header is
checked first, and `ApiClient` attaches it on every request from
`BtConfig.tenant`, which comes from `--dart-define=TENANT=<slug>` and defaults
to `demo` — the exact slug the Prisma seed creates. So a domainless deployment
resolves tenants correctly with no code change; just build the apps with the
matching `TENANT` value.

The WebSocket needs nothing at all: it reads `tenantId` out of the verified JWT
claims, never from a hostname.

---

## 2. Server prep

```bash
ssh root@YOUR_VPS_IP

apt update && apt upgrade -y
timedatectl set-timezone UTC

# Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sh
docker compose version

# Swap helps on 4-8 GB boxes during the Docker builds.
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### Firewall

Unlike the TLS setup — where only 80/443 are open — IP mode has to expose every
service port, because there is no hostname to multiplex them behind:

```bash
ufw allow OpenSSH
ufw allow 8000/tcp    # CRM
ufw allow 4100/tcp    # B-Trader REST
ufw allow 4101/tcp    # B-Trader WebSocket
ufw allow 4200/tcp    # B-Trader admin dashboard
ufw allow 4400/tcp    # B-Trader web trader (skip if unused)
ufw --force enable
```

For the ingest port, restrict it to the Windows MT5 box instead of opening it
to the world (do this **after** you know the bridge's IP):

```bash
ufw allow from <WINDOWS_VPS_IP> to any port 4300 proto tcp
```

Never open `5432` or `6379`. Both databases and both Redis instances stay on
private Docker networks and are not published by either compose file.

If your provider has its own firewall or security group (Hetzner, AWS, Oracle
Cloud, Azure), open the same ports there too — `ufw` alone will not help you.

## 3. Get the code up

```bash
mkdir -p /opt/burjex && cd /opt/burjex
git clone <your-repo-url> .
# or from your machine:
#   rsync -avz --delete --exclude '.git' --exclude 'node_modules' \
#     --exclude '**/build' --exclude '.dart_tool' --exclude 'deploy/.env.prod.ip' \
#     ./ root@YOUR_VPS_IP:/opt/burjex/

mkdir -p /opt/burjex/web/admin /opt/burjex/web/trader
```

`deploy/.env.prod.ip` must be excluded from every rsync, or `--delete` will
wipe your credentials. The two `web/` directories must exist before Caddy
starts — Docker would otherwise create them as root-owned mounts.

## 4. Fill the environment

```bash
cd /opt/burjex
cp deploy/.env.prod.ip.example deploy/.env.prod.ip
chmod 600 deploy/.env.prod.ip

# Write your real IP everywhere at once:
sed -i 's/YOUR_VPS_IP/203.0.113.10/g' deploy/.env.prod.ip

# Generate each secret:
openssl rand -hex 32     # DJANGO_SECRET_KEY, JWT_SECRET, JWT_REFRESH_SECRET, CRM_WEBHOOK_SECRET
openssl rand -hex 24     # MT5_FEED_TOKEN, BRIDGE_TOKEN
openssl rand -hex 16     # the Postgres / Redis passwords

nano deploy/.env.prod.ip   # replace every CHANGE_ME
```

The IP has to be written literally on each line: Docker Compose does not expand
`${VARS}` **inside** an env file when that file is handed to a container, so a
single `PUBLIC_HOST=` reference would arrive at Django as the literal string
`${PUBLIC_HOST}`. That is why the template ships placeholders and a `sed`.

Values that must be consistent, or things fail in confusing ways:

- `JWT_SECRET` is read by both `gateway-api` and `ws-gateway`. If they differ,
  REST works and **every WebSocket closes with code 4401**.
- The password inside `DATABASE_URL` must equal `BT_POSTGRES_PASSWORD`, and the
  ones inside `REDIS_URL` / `CELERY_BROKER_URL` / `CHANNELS_REDIS_URL` must
  equal `CRM_REDIS_PASSWORD`.
- `DJANGO_CSRF_TRUSTED_ORIGINS` needs the **scheme and the port**
  (`http://203.0.113.10:8000`). `DJANGO_ALLOWED_HOSTS` needs the **bare IP** —
  Django strips the port before matching that one.
- Leave `DJANGO_COOKIE_SECURE=0`. Set it to 1 over plain HTTP and the browser
  will refuse to store the session cookie, so login silently loops back to the
  form.

## 5. Build and start

Validate first — this catches a typo'd variable in seconds instead of halfway
through a ten-minute build:

```bash
cd /opt/burjex
docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip config >/dev/null && echo "compose OK"
docker run --rm -v "$PWD/deploy/Caddyfile.ip:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

`caddy validate` warns that `{$FEED_ALLOWED_IPS}` is empty when run this way —
expected, it does not load the env file. Syntax errors are what you want.

Then:

```bash
docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip up -d --build
docker compose -f deploy/docker-compose.ip.yml ps
```

The first build compiles the B-Trader pnpm monorepo four times (one image per
service, sharing cache layers) — expect 10-20 minutes on a 4 vCPU box.

## 6. Database setup

`crm-web` runs `migrate` and `collectstatic` **itself on every start**, so the
Django schema and the static files are already done. To run them by hand:

```bash
cd /opt/burjex
C="docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip"

$C exec crm-web python manage.py migrate
$C exec crm-web python manage.py collectstatic --noinput
$C exec crm-web python manage.py createsuperuser
```

B-Trader's Prisma schema is **not** applied automatically. Apply it once, then
seed the `demo` tenant and its admin user:

```bash
$C run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && npx prisma db push --skip-generate'

# First install only — creates the `demo` tenant + an admin you can sign in as:
$C run --rm btrader-gateway \
  sh -lc 'cd /app/packages/db && npx prisma db seed'
```

`db push` is additive (new tables and nullable/defaulted columns only) — no
reset, no data loss. This is the same command
[`btrader/infra/DEPLOY-CRM.md`](../btrader/infra/DEPLOY-CRM.md) uses. The seed
creates the tenant with slug **`demo`**, which is what every `TENANT`
dart-define below expects.

## 7. Your URLs

Substitute your IP:

| What | URL |
|---|---|
| CRM portal + login | `http://IP:8000/` |
| CRM Django admin | `http://IP:8000/admin/` |
| CRM health probe | `http://IP:8000/health/ready/` |
| B-Trader admin dashboard | `http://IP:4200/` |
| B-Trader REST API | `http://IP:4100/v1` |
| B-Trader Swagger | `http://IP:4100/docs` |
| B-Trader WebSocket | `ws://IP:4101` |
| MT5 ingest | `http://IP:4300/ingest` |
| MT5 ingest health | `http://IP:4300/health` |
| B-Trader web trader | `http://IP:4400/` |

Smoke test from your laptop:

```bash
curl -i http://203.0.113.10:8000/health/ready/     # {"status":"ready"}
curl -i http://203.0.113.10:4100/v1/public/branding -H 'X-BT-Tenant: demo'
curl -i http://203.0.113.10:4300/health            # {"ok":true,...}
```

## 8. Wire the CRM to B-Trader

The CRM reads its gateway settings from the database, not from env — set them
in the CRM admin UI (Integrations → trading platform **BTRADER**):

| Field | Value |
|---|---|
| Base URL | `http://btrader-gateway:4100` |
| Key ID | the `keyId` from B-Trader admin → CRM / Integrations → *New key* |
| Secret | the `secret` shown once when that key is created |

The base URL stays **internal and unchanged from the TLS setup** — CRM and
gateway share the `edge` Docker network, so that call never leaves the host and
never touches plaintext HTTP on the wire. Do **not** put the public
`http://IP:4100` here. `btrader_integration/client.py` appends `/v1` itself, so
do not include it either.

In the B-Trader admin, set the outbound webhook to:

```
http://YOUR_VPS_IP:8000/api/btrader/webhook/
```

with the signing secret matching `CRM_WEBHOOK_SECRET`. Then press **Test
connection** in the CRM — it calls `GET /v1/crm/groups` and should report the
number of trading groups.

## 9. Flutter web builds (admin + web trader)

Built on your machine (the server has no Flutter SDK), then copied to the paths
Caddy serves. The define names below are the real ones — `API_BASE`, `WS_URL`
and `TENANT`, read by `BtConfig` in
`btrader/flutter/packages/btrader_core/lib/src/config.dart`:

```bash
# B-Trader admin  → http://IP:4200
cd btrader/flutter/apps/admin
flutter build web --release \
  --dart-define=API_BASE=http://203.0.113.10:4100 \
  --dart-define=WS_URL=ws://203.0.113.10:4101 \
  --dart-define=TENANT=demo
rsync -avz --delete build/web/ root@203.0.113.10:/opt/burjex/web/admin/

# B-Trader web trader (optional)  → http://IP:4400
cd ../trader
flutter build web --release \
  --dart-define=API_BASE=http://203.0.113.10:4100 \
  --dart-define=WS_URL=ws://203.0.113.10:4101 \
  --dart-define=TENANT=demo
rsync -avz --delete build/web/ root@203.0.113.10:/opt/burjex/web/trader/
```

`WS_URL` has **no path and no trailing slash** — the client appends `?token=…`
directly to it.

Browser note: both bundles are served over `http://`, so they are not a secure
context. `http://IP:4200` calling `http://IP:4100` is a plain cross-origin
request and the gateway already answers with permissive CORS
(`NestFactory.create(AppModule, { cors: true })`), so it works. Do not mix
schemes — an `https://` page may not call `http://` or `ws://`.

## 10. Mobile APKs

```bash
cd btrader/flutter/apps/trader
flutter build apk --release \
  --dart-define=API_BASE=http://203.0.113.10:4100 \
  --dart-define=WS_URL=ws://203.0.113.10:4101 \
  --dart-define=TENANT=demo
# build/app/outputs/flutter-apk/app-release.apk
```

**CRM app (`forexten_mobile`)** — that project is not part of this repository
checkout, so the define names could not be verified against its source. Per the
main README it takes `API_BASE_URL` **including** the `/api/v1` prefix (the
default in `api_config.dart` bakes it in and the override replaces the whole
string), plus the same three B-Trader defines:

```bash
cd forexten_mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=http://203.0.113.10:8000/api/v1 \
  --dart-define=API_BASE=http://203.0.113.10:4100 \
  --dart-define=WS_URL=ws://203.0.113.10:4101 \
  --dart-define=TENANT=demo
```

Before shipping that APK, confirm the name by grepping its lib folder for
`String.fromEnvironment` — if it differs, the build succeeds and the app just
silently talks to the wrong host.

### Android cleartext — required for HTTP

Since Android 9 (API 28), release builds **block cleartext HTTP by default**.
`http://` and `ws://` calls fail at runtime with
`CLEARTEXT communication to 203.0.113.10 not permitted by network security
policy` — and because the failure is inside the HTTP client, it often surfaces
as nothing more than a spinner that never resolves.

Both B-Trader Android apps are now configured for it:

| App | Manifest | Status |
|---|---|---|
| `btrader/flutter/apps/trader` | `android/app/src/main/AndroidManifest.xml` | `android:usesCleartextTraffic="true"` — already present |
| `btrader/flutter/apps/admin` | `android/app/src/main/AndroidManifest.xml` | `android:usesCleartextTraffic="true"` — **added for IP mode** |

For `forexten_mobile`, check its own manifest and add the same attribute to the
`<application>` tag if it is missing:

```xml
<application
    android:label="..."
    android:usesCleartextTraffic="true">
```

`usesCleartextTraffic="true"` permits cleartext to **every** host, which is the
blunt version. Tighter, once you know your IP, is a network security config
that allows only that one:

```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">203.0.113.10</domain>
    </domain-config>
</network-security-config>
```

referenced from the manifest as
`android:networkSecurityConfig="@xml/network_security_config"` (and then drop
`usesCleartextTraffic`). **Remove all of this once you are on HTTPS** — an APK
in the wild with global cleartext enabled is downgrade-attackable.

iOS has the same restriction via App Transport Security and needs
`NSAllowsArbitraryLoads` in `Info.plist` for HTTP. Apple rejects App Store
submissions that use it without justification, so treat IP mode as
Android/testing only on the mobile side.

## 11. The MT5 bridge runs on Windows — not on this server

Unchanged from the main README: the bridge imports **`MT5Manager`**, the
MetaQuotes Manager API, which is a Windows-only binary. There is no Linux
build. So a **small Windows VPS** runs the bridge and pushes ticks to the Linux
box.

On the Windows machine, in the bridge's `config.json` — only the URLs differ
from the TLS setup:

| Key | Value |
|---|---|
| `FeedUrl` | `http://YOUR_VPS_IP:4300/ingest` |
| `InpToken` / feed token | must equal `MT5_FEED_TOKEN` in `.env.prod.ip` |
| `BridgeApiUrl` | `http://YOUR_VPS_IP:4100/v1` (the `/v1` is required) |
| `BridgeToken` | must equal `BRIDGE_TOKEN` in `.env.prod.ip` |
| `BtTenantId` | `demo`, or the tenant these symbols belong to |
| `SymbolSuffixStrip` | broker suffix, e.g. `.r`, so `EURUSD.r` → `EURUSD` |
| `ReconcileEnabled` | `true` to auto-sync symbols and groups |

Then set `FEED_ALLOWED_IPS` in `.env.prod.ip` to the Windows VPS public IP and
restart Caddy. In IP mode this is close to mandatory rather than optional: the
feed token crosses the wire in plaintext, so the allowlist is what remains if
somebody captures it.

```bash
$C restart caddy
```

**Without the bridge running there are no prices.** `LP_BRIDGE_DRIVER` is
deliberately not defaulted to `mock` — an empty value means no feed rather than
fake prices reaching real clients. Details for the reconcile and A-book workers
are in
[`btrader/infra/DEPLOY-MT5-BRIDGE.md`](../btrader/infra/DEPLOY-MT5-BRIDGE.md).

## 12. Go-live checklist (testing)

- [ ] `docker compose -f deploy/docker-compose.ip.yml ps` — every container up, `crm_web` healthy
- [ ] `curl http://IP:8000/health/ready/` returns `{"status":"ready"}`
- [ ] CRM admin loads **with styling** (proves Caddy is serving `/static`)
- [ ] Superuser can sign in — no CSRF error (proves `DJANGO_CSRF_TRUSTED_ORIGINS`)
- [ ] `http://IP:4200` loads the B-Trader admin and login succeeds
- [ ] `http://IP:4100/docs` shows Swagger
- [ ] Prisma `db push` + seed ran; the `demo` tenant exists
- [ ] Ticks arriving: `$C logs -f btrader-market-data`
- [ ] Quotes move in the admin market watch (proves the WS on 4101)
- [ ] APK built with `http://`/`ws://` connects — no `CLEARTEXT ... not permitted`
- [ ] `FEED_ALLOWED_IPS` set to the bridge IP
- [ ] `deploy/.env.prod.ip` is `chmod 600`, untracked, no `CHANGE_ME` left
- [ ] Both Postgres volumes are in a backup job

## 13. Moving to a domain later

No data is lost — the volumes are shared between both compose files, because
`name: burjex` and the volume names are identical.

1. Buy the domain, add the six A records from [README.md](README.md) §2.
2. `cp deploy/.env.prod.example deploy/.env.prod` and fill it in, reusing the
   **same** passwords and secrets from `.env.prod.ip` so the existing databases
   still open.
3. `docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip down`
4. `ufw delete` the service ports; keep only 22, 80, 443.
5. `docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod up -d`
6. Rebuild every Flutter app with `https://` / `wss://` and remove the cleartext
   permissions from the Android manifests.
7. Update the MT5 bridge's `FeedUrl` and `BridgeApiUrl`, and the B-Trader
   outbound webhook URL, to the HTTPS forms.

## 14. Operations

```bash
cd /opt/burjex
C="docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip"

$C ps
$C logs -f caddy                # routing / 404s
$C logs -f btrader-ws           # WebSocket connects/disconnects
$C logs -f btrader-market-data  # incoming ticks
$C logs -f crm-web

# Update
git pull && $C up -d --build

# Backups (both databases)
docker exec crm_postgres pg_dump -U burjexcrm burjexcrm | gzip > crm-$(date +%F).sql.gz
docker exec btrader_postgres pg_dump -U btrader btrader | gzip > btrader-$(date +%F).sql.gz
```

### Troubleshooting

| Symptom | Cause |
|---|---|
| Port unreachable from outside, fine via `curl` on the box | Provider firewall / security group, not `ufw` |
| CRM admin loads unstyled | Caddy is not serving `/static`; check the `crm_static` volume and that `collectstatic` ran |
| `CSRF verification failed` on login | `DJANGO_CSRF_TRUSTED_ORIGINS` missing the `http://IP:8000` form, scheme and port included |
| Login form reloads with no error | `DJANGO_COOKIE_SECURE=1` over HTTP — set it to `0` |
| `DisallowedHost` in the logs | IP missing from `DJANGO_ALLOWED_HOSTS` (bare IP, no port) |
| WebSocket closes with **4401** | `JWT_SECRET` differs between `btrader-gateway` and `btrader-ws` |
| API returns tenant-less / empty data | Client not sending `X-BT-Tenant`; rebuild with `--dart-define=TENANT=demo` |
| App hangs with no error on Android | Cleartext blocked — see §10 |
| No prices | `LP_BRIDGE_DRIVER` not `mt5-ingest`, bridge down, or 4300 blocked by `FEED_ALLOWED_IPS` |
