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
├── flutter/              Flutter apps — one codebase, shared btrader_core
│   ├── packages/btrader_core/   models, API (Dio), WebSocket, Riverpod state, theme
│   ├── apps/trader/             mobile trader app (iOS + Android)
│   └── apps/admin/              web admin dashboard (Flutter web)
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

### Flutter apps (trader + admin)

```bash
dart pub global activate melos && (cd flutter && melos bootstrap)

# Trader app (device/emulator)
cd flutter/apps/trader && flutter run \
  --dart-define=API_BASE=http://localhost:4100 \
  --dart-define=WS_URL=ws://localhost:4101 --dart-define=TENANT=demo
# sign in: trader@demofx.com / Trader123! (seed)

# Admin (web)
cd flutter/apps/admin && flutter run -d chrome \
  --dart-define=API_BASE=http://localhost:4100 --dart-define=WS_URL=ws://localhost:4101
# sign in: tenant "demo", a TENANT_ADMIN/SUPER_ADMIN account (see seed)
```

Trader tabs: Markets, Charts, Trade, Portfolio, Account (+ Settings, Funding, History). Both apps are responsive (phone → tablet/desktop) with light/dark themes. Chart/price feed runs on the built-in mock until a provider is purchased.

Tabs: Markets (live watchlist), Trade (all order types + one-click), Portfolio (modify SL/TP, partial/full/close-all), History, Account. Branding is fetched at launch from `/v1/public/branding` so each white-label build is themed per broker.

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
