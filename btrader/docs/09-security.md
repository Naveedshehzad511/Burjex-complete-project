# 9. Security Model

## Authentication
- **JWT access tokens** (15 min) signed with `JWT_SECRET`, carrying `sub`, `role`, `tenantId`.
- **Refresh tokens** (30 days) signed with a separate secret, stored only as a SHA-256 hash in `Session`, and **rotated on every use** (old session revoked) to limit replay.
- **Force-logout** revokes all of a user's sessions instantly (admin action) — useful for compromised accounts.
- **MFA** — TOTP fields on `User` (`mfaSecret`, `mfaEnabled`) for admin accounts.

## Authorization (RBAC)
Role hierarchy: SUPER_ADMIN, TENANT_ADMIN, TENANT_STAFF, TRADER, SERVICE. Routes are gated with `@Roles(...)` and fine-grained `@RequirePerm('scope')` (e.g. `balance.adjust`, `leverage.change`, `clients.create`) backed by `UserPermission`. The dealing desk can be granted exactly the scopes it needs and no more.

## Multi-tenant isolation
The JWT's `tenantId` must equal the request's resolved tenant or the guard rejects it (except SUPER_ADMIN). Combined with the mandatory `tenantId` filter on every query, this prevents cross-tenant access at both the auth and data layers. See [07](07-multi-tenant.md).

## Service-to-service (CRM)
`/v1/crm/*` uses API key + **HMAC-SHA256** over `"{timestamp}.{rawBody}"` with `X-BT-Key`/`X-BT-Timestamp`/`X-BT-Signature`. The guard enforces: key active & unexpired, IP allowlist, ±5-minute replay window, constant-time signature comparison, and required scopes. Keys are stored as hashes with per-key scopes and CIDR allowlists.

## Audit
Every state-changing admin/trading action writes to `AuditLog` (actor, actorType, action, entity, before/after JSON, IP). Logs are tenant-scoped and queryable. Financial and trading events also flow to the immutable `Deal` ledger.

## API hardening
Helmet headers, strict `ValidationPipe` (whitelist + forbid unknown fields) on every DTO, global rate limiting (`@nestjs/throttler`) with a separate bucket for CRM keys, and CORS restricted to tenant origins. WebSocket connections are authenticated and per-tenant capped.

## Secrets & data protection
Secrets are injected via environment / Kubernetes Secrets (KMS-backed in production), never committed. `ENCRYPTION_KEY` (AES-256) encrypts integration credentials at rest, matching the CRM's `crypto-js` approach. Passwords are bcrypt-hashed. TLS everywhere (client→edge and ideally mTLS edge→service in-cluster).

## Trading-specific safety
Default slippage is 0 (orders reject rather than fill at a worse price unless tolerance is set). Risk limits (max lot, max open lots/positions, net exposure, daily loss) are enforced pre-trade. Margin-call and stop-out levels are per-account and enforced by the engine on every tick. The idempotent `externalRef` on balance ops prevents double-spend from CRM retries.

## Note
This document describes design and controls; a production launch should include an independent security review and penetration test, plus the brokerage's regulatory/KYC obligations (handled in the CRM).
