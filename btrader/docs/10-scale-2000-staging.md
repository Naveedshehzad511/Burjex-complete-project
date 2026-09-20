# 2,000-user staging verification

This repository does not certify 2,000 production traders. Run this procedure
only against an isolated staging stack with a disposable tenant and disposable
accounts; `scale_2000_staging.js` rejects `*.burjexprime.net` and
`5.226.139.8` as a safety backstop.

## Start an isolated stack

Use `deploy/docker-compose.staging.yml`, its distinct volumes and the `5100`,
`5101`, and `5300` host ports. Do not use a production MT5 bridge or a
production database. Pre-create `VUS` disposable accounts starting at
`LOGIN_BASE` and seed only synthetic/test prices.

```sh
k6 run \
  -e BASE_URL=http://127.0.0.1:5100 \
  -e WS_URL=ws://127.0.0.1:5101 \
  -e TENANT=loadtest \
  -e PASSWORD="$DISPOSABLE_PASSWORD" \
  -e LOGIN_BASE=700000 \
  btrader/loadtest/scale_2000_staging.js
```

The scenario is deliberately configured for 2,000 VUs but has not been run by
this change. Keep the raw k6 summary, container CPU/memory/PID metrics, Redis
memory/latency, and Postgres checkpoint/WAL statistics with the result.

## Acceptance data

The default client thresholds are order and close ack p95 `<250 ms`, p99
`<500 ms`, WS connection p95 `<500 ms`, WS state p95 `<250 ms`, and errors
`<1%`. They are test gates, not a promise: tighten them only after agreeing a
fast-market SLO including WAN latency.

Correlate a trade with `traceId` in the order response (derived from its
`clientOrderId`), the matching service `trade-hop` logs, the engine-event
`emittedAt`, and `ws-metrics`. Those report gateway→matcher time, per-account
queue wait, SQL commit duration, Redis lock/publish duration, price age, WS
event age, enqueue time, and slow-client disconnects.

## Database burst-commit checks

The stack budgets 160 gateway, 64 matching, 20 market-data, and 40 worker
connections under Postgres `max_connections=400`. Existing schema indexes that
must remain in the test plan include:

- `orders(tenantId, accountId, clientOrderId)` for idempotent submissions;
- `positions(accountId, status)` and `positions(tenantId, book, status)` for
  trade state and execution scans;
- `deals(accountId, createdAt)` for trade history.

The compose settings turn on WAL compression, set `max_wal_size=4GB`, and
spread checkpoints (`checkpoint_completion_target=0.9`). During the 2,000-VU
test, record `pg_stat_bgwriter`, WAL volume, checkpoint duration, fsync/commit
latency, and `EXPLAIN (ANALYZE, BUFFERS)` for the indexed order/position
queries. Do not change indexes or checkpoint settings based on assumptions;
validate on the staging disk and retain the before/after evidence.

## Host boundary

Compose limits protect the matching, gateway, WS, market-data, Postgres, and
Redis cgroups, but they do not pin a CPU core. Dedicated Linux Docker cores and
matching CPU pinning remain a host operation. The test result must explicitly
state the host CPU/RAM allocation and whether it was virtualized/WSL before it
is used for any capacity decision.
