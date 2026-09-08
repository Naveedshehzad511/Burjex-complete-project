# 10. Implementation Roadmap

A step-by-step path from this scaffold to a production brokerage platform. Phases are ordered by dependency; each ends with a shippable, testable increment.

## Phase 0 — Foundation (this repo)
Done: monorepo, Prisma schema, shared contracts, trading-engine core + math (unit-tested), market-data with LP adapter pattern + mock feed, ws-gateway, gateway-api (auth, tenants, accounts, symbols, trading, financial, CRM integration, risk, audit), Docker/K8s/nginx, mobile scaffold, full design docs.

**Next to make Phase 0 runnable end-to-end:** `pnpm install`, generate Prisma client, run migrations + seed, `pnpm dev`, then place an order against the mock feed and watch the WS push account updates.

## Phase 1 — Core trading hardening (weeks 1–3)
- Replace hot-path `number` math with a decimal library on ledger-affecting steps; property-test invariants (equity = balance + credit + ΣfloatingPL).
- Implement swap accrual (daily cron, triple-swap weekday), commission per symbol/group, and STOP_LIMIT two-stage semantics.
- Quote→account FX conversion for cross-currency symbols (e.g. account in EUR trading USDJPY).
- Pending-order expiry (GTD/DAY) and IOC/FOK fills.
- Integration tests covering every order type, partial close, SL/TP, margin call, and stop-out.

## Phase 2 — CRM integration cutover (weeks 3–5)
- Stand up CRM API keys + IP allowlists; implement the outbox delivery worker (retry/backoff) and the CRM-side webhook receiver.
- Map the CRM's `mt5.service` calls onto `/v1/crm/*` behind a feature flag; run B-Trader in shadow mode alongside MT5, reconciling balances/positions.
- Reconciliation job: nightly compare CRM `TradingAccount` vs B-Trader `Account` by `crmAccountId`.
- Cut deposits/withdrawals over to the idempotent balance endpoint.

## Phase 3 — Real liquidity (weeks 5–8)
- Implement the production LP bridge adapter for the chosen provider (PrimeXM / oneZero / B2 / cTrader Open API / FIX 4.4). Normalize symbols, handle subscribe/heartbeat/reconnect.
- Markup engine: per-group/per-symbol spread + markup, last-look/validity windows, stale-quote guards.
- A/B/C-book routing hooks and net-exposure-driven hedging signals for the dealing desk.

## Phase 4 — Mobile & admin to production (weeks 6–10)
- Build out mobile navigation (Auth/Markets/Trade/Portfolio/History/Account), charts (candles), watchlist management, push notifications (margin call, order filled), biometric unlock, and white-label build pipeline (per-tenant bundle id, store metadata).
- Build the admin dashboard UI on the existing endpoints; add the super-admin tenant console, live exposure board, and audit explorer.
- Accessibility + localization.

## Phase 5 — Scale, HA, and observability (weeks 9–12)
- Tenant-sharded trading-engine with consistent hashing + leader election; market-data leader election.
- Postgres HA (primary/replica/PgBouncer), Redis Sentinel/Cluster, multi-AZ.
- Prometheus/Grafana dashboards (order p99, fills/sec, stop-outs, outbox lag), alerting, load tests to validate the sub-MT5 latency target.

## Phase 6 — Compliance & launch (weeks 12+)
- Independent security review + penetration test; finalize secrets/KMS, mTLS in-cluster.
- DR drills (PITR restore, region failover), runbooks, on-call.
- Broker onboarding playbook: create tenant, brand, instruments, risk limits, LP credentials, store builds → go live.

## Risk register (top items)
- **Pricing/markup correctness** — mitigate with shadow-mode reconciliation vs the existing MT5 feed before cutover.
- **Money correctness** — decimal math + immutable Deal ledger + idempotent external refs + nightly reconciliation.
- **Latency under load** — DB transaction is the governor; partition by tenant and load-test early.
- **CRM coupling** — the contract is a documented superset of today's `mt5.service`, so the CRM changes are limited to base URL + auth headers.
