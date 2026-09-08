# 7. Multi-Tenant Design

## Model
B-Trader is a **shared-everything** multi-tenant SaaS: one deployment, one database, one set of services, serving every broker brand. Isolation is enforced in software on a mandatory `tenantId` discriminator present on every business row, mirroring the proven Example CRM approach.

## Tenant resolution
`TenantMiddleware` resolves the active tenant on every request, in priority order:
1. `X-BT-Tenant` header (platform/service callers, CRM keys).
2. Host match — request host (from `X-Forwarded-Host`) against `tenant.domain` / `adminDomain` / `appDomain`. App subdomains (`app.` / `admin.` / `api.`) are stripped to the registrable domain before matching, so `api.demofx.com`, `admin.demofx.com`, and `app.demofx.com` all resolve to the same tenant. (This matches the CRM's resolver exactly.)
3. `?tenant=slug` query (dev only).

Resolution is cached 60s in-process to keep it off the hot path.

## Isolation enforcement
- **Data** — every query is `where: { tenantId, ... }`. Unique keys are composite `(tenantId, login)`, `(tenantId, symbol)`, `(tenantId, email)` so brands never collide.
- **Auth** — the JWT carries `tenantId`; `JwtAuthGuard` rejects any token whose tenant ≠ the resolved tenant (except SUPER_ADMIN). A trader from broker A literally cannot act on broker B even with a stolen route.
- **WebSocket** — fan-out checks tenant on every message (see [06](06-websocket-architecture.md)).
- **CRM keys** — each `ApiKey` is bound to a tenant; the key alone determines the tenant scope.

## Per-tenant configuration
Each tenant independently owns: branding (name, logo, colors, iOS/Android bundle ids, custom CSS), base currency, timezone, instrument set and contract specs, markup/spread, leverage and margin-call/stop-out levels, risk limits, and trading sessions. Nothing is hardcoded — two brokers on the same cluster can offer entirely different instruments and pricing.

## Super-admin
A platform `SUPER_ADMIN` (tenant-less user) can create, brand, suspend, re-activate, and soft-delete tenants (`/v1/tenants/*`). Suspending a tenant flips its status; guards then reject trading for that tenant while preserving data.

## White-label custom domains
Brokers point their own domain (e.g. `app.demofx.com`) at the platform ingress; nginx/Ingress passes the Host through and the middleware resolves the tenant. TLS is provisioned per custom domain (cert-manager / ACME). Mobile white-label builds carry the tenant's bundle id and a compile-time `apiBase`.

## When to shard
The shared model scales to a large number of tenants. For very large brokers or strict data-residency requirements, a tenant can be promoted to a **dedicated schema or database** (the Prisma datasource is per-deployment, and `tenantId` already partitions everything), or pinned to a regional cluster — without changing application logic.
