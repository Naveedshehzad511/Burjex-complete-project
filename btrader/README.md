# B-Trader

A production-grade, multi-tenant SaaS trading platform (MT5-like) — mobile app, admin dashboard, trading engine, real-time market data, and a secure API surface that the **Example CRM** consumes. B-Trader is a **separate system** from the CRM and integrates with it through APIs only.

## What's in this repo

```
b-trader/
├── apps/
│   ├── gateway-api/      NestJS REST API (auth, tenants, accounts, symbols,
│   │                     trading, financial, CRM integration, risk, audit)
│   ├── trading-engine/   Execution + margin/P&L + SL/TP + stop-out (+ pure calc lib)
│   ├── market-data/      LP bridge adapters → tenant markup → Redis fan-out
│   └── ws-gateway/       Client-facing WebSocket (ticks, account, positions)
├── packages/
│   ├── db/               Prisma schema + client (trading domain)
│   └── shared/           Shared TS contracts (enums, DTOs, CRM contract, events)
├── flutter/              Flutter admin — shared btrader_core
│   ├── packages/btrader_core/   models, API (Dio), WebSocket, Riverpod state, theme
│   └── apps/admin/              web admin dashboard (Flutter web)
│       (client portal is static web/portal — Home/Quotes/Chart/Trade/History)
├── infra/                Docker Compose, Dockerfile, K8s, nginx
├── mockups/              Static HTML UI previews (trader + admin)
└── docs/                 The 10 design deliverables + roadmap
```

> The client apps are now **Flutter** (Riverpod + go_router + Dio). The earlier
> Next.js admin and React Native app were removed in favour of one Flutter
> codebase. See `flutter/README.md` to run them.

## Quick start (local)

```bash
pnpm install
cp .env.example .env
docker compose -f infra/docker-compose.yml up -d postgres redis
pnpm --filter @btrader/db db:generate
pnpm --filter @btrader/db db:migrate
pnpm --filter @btrader/db db:seed
pnpm dev            # runs gateway-api, trading-engine, market-data, ws-gateway
# API docs: http://localhost:4100/docs
```

The mock LP bridge generates a live feed so you can place orders end-to-end with no external provider.

### Flutter admin

```bash
dart pub global activate melos && (cd flutter && melos bootstrap)

# Admin (web)
cd flutter/apps/admin && flutter run -d chrome \
  --dart-define=API_BASE=http://localhost:4100 --dart-define=WS_URL=ws://localhost:4101
# sign in: tenant "demo", a TENANT_ADMIN/SUPER_ADMIN account (see seed)
```

The live client portal is the static Trade+ bundle in `web/portal` (Home, Quotes, Chart, Trade, History). Do not rebuild a Markets/Portfolio/Settings trader app onto it. Admin branding is fetched at launch from `/v1/public/branding`.

## Documentation

| # | Deliverable | File |
|---|-------------|------|
| 1 | System architecture | [docs/01-system-architecture.md](docs/01-system-architecture.md) |
| 2 | Database schema | [docs/02-database-schema.md](docs/02-database-schema.md) |
| 3 | API specification | [docs/03-api-spec.md](docs/03-api-spec.md) |
| 4 | Mobile app architecture | [docs/04-mobile-architecture.md](docs/04-mobile-architecture.md) |
| 5 | Admin dashboard architecture | [docs/05-admin-architecture.md](docs/05-admin-architecture.md) |
| 6 | WebSocket architecture | [docs/06-websocket-architecture.md](docs/06-websocket-architecture.md) |
| 7 | Multi-tenant design | [docs/07-multi-tenant.md](docs/07-multi-tenant.md) |
| 8 | Deployment plan | [docs/08-deployment.md](docs/08-deployment.md) |
| 9 | Security model | [docs/09-security.md](docs/09-security.md) |
| 10 | Implementation roadmap | [docs/10-roadmap.md](docs/10-roadmap.md) |

CRM integration contract: [docs/03-api-spec.md#crm-integration](docs/03-api-spec.md) and `packages/shared/src/crm-contract.ts`.
