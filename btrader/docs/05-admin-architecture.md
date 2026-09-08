# 5. Admin Dashboard Architecture

A Next.js (App Router) web app under `apps/admin-web` (scaffold), consuming the same `/v1` API with a TENANT_ADMIN/TENANT_STAFF JWT. A separate **super-admin** surface (or role-gated section) manages tenants platform-wide.

## Stack
- **Next.js 14 + React + TypeScript**, server components for data-heavy tables.
- **TanStack Query** for API state, **Tailwind** + the tenant theme tokens for white-label theming.
- **Recharts** for exposure / P&L / volume charts.
- Auth via the gateway's JWT; the dashboard never talks to the DB directly.

## Modules (map 1:1 to API)
- **User management** — create clients, enable/disable, enable/disable trading, change leverage, force-logout (`/accounts/*`).
- **Financial** — deposit, withdraw, bonus, dividend, manual adjustment (`/financial/adjust`), with audit trail.
- **Trading control** — view all positions, by client, modify/close/close-all, and **net exposure monitoring** (`/accounts/exposure/net`, `/positions`, `/positions/:id/*`).
- **Symbol management** — add/remove/enable/disable, set contract size, margin, leverage cap, swap, min/max/step lot, slippage (default 0), trading sessions (`/symbols/*`).
- **Risk** — limits and live margin-call alerts (`/risk/*`).
- **Audit logs** — searchable, tenant-scoped (`/audit`).
- **Super-admin** — tenants: create/suspend/delete, branding, plan/limits (`/tenants/*`).

## Real-time admin
The dashboard opens the same WebSocket (admin token) to stream net exposure and account health for the dealing desk, so risk staff see margin-call/stop-out events live rather than on refresh.

## Security
All admin actions are RBAC-gated (`@Roles` + `@RequirePerm`) and written to `AuditLog` with before/after snapshots and the actor's IP. Sensitive actions (balance adjust, leverage change) require explicit permission scopes beyond the base admin role.
