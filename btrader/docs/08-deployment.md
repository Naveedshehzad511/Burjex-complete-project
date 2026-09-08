# 8. Deployment Plan

## Environments
- **Local** — `docker compose -f infra/docker-compose.yml up` brings up Postgres, Redis, all four services, and nginx. The mock LP bridge gives a live feed with no external dependency.
- **Staging / Production** — Kubernetes (`infra/k8s/btrader.yaml`): namespace, ConfigMap, Secret, Deployments, Services, HPAs, and Ingress.

## Containers
One multi-stage `infra/Dockerfile` builds the pnpm monorepo and runs any service via `--build-arg SERVICE=<name>`. Prisma client is generated at build time. Images: `btrader-gateway-api`, `btrader-trading-engine`, `btrader-market-data`, `btrader-ws-gateway` (admin-web ships as its own Next.js image).

## Kubernetes shape
- **gateway-api** — 3+ replicas, HPA to 20 on 65% CPU, readiness/liveness on `/v1/health`.
- **ws-gateway** — 3+ replicas, HPA to 30 (connection-bound); stateless via Redis fan-out.
- **trading-engine** — 2+ replicas; shard tenants across replicas (consistent-hash on `tenantId`) so each tenant's book is owned by one replica at a time; standby replicas rebuild from Postgres on failover.
- **market-data** — single active writer per LP feed with leader election (one publisher avoids duplicate ticks); hot standby takes over on failure.
- **Postgres** — primary + sync replica, PgBouncer pooling, automated failover (e.g. Patroni/CloudNativePG).
- **Redis** — Sentinel or Cluster for HA pub/sub + streams.

## Networking
Ingress routes `/v1` → gateway-api and `/ws` → ws-gateway, preserves the Host header for tenant resolution, and sets long read timeouts for WebSockets. TLS via cert-manager, including per-tenant custom domains.

## CI/CD
Build → typecheck → unit tests (`trading-engine` calc suite) → Prisma migrate check → image build/push → `kubectl apply` (or GitOps/Argo). Migrations run as a pre-deploy `Job` (`db:migrate:prod`) before rolling the gateway.

## Observability
Structured logs (pino) shipped to a central stack; Sentry for errors (`SENTRY_DSN`); Prometheus metrics (order latency p50/p99, fills/sec, margin-call/stop-out counts, WS connections, outbox lag) with Grafana dashboards and alerting on outbox backlog and stop-out spikes.

## Backups & DR
Continuous Postgres WAL archiving + nightly base backups with point-in-time recovery; the immutable `Deal` ledger plus `balanceAfter` allows full account reconstruction. Redis is reconstructable (ticks are ephemeral; streams are acked). Target RPO ≤ 1 min, RTO ≤ 15 min intra-region with multi-AZ; cross-region warm standby optional.

## Scaling the trading loop
Throughput grows by adding gateway/ws replicas (stateless) and engine shards (tenant-partitioned). The single DB transaction per order is the throughput governor; partition by tenant and, if needed, move very large brokers to dedicated database shards.
