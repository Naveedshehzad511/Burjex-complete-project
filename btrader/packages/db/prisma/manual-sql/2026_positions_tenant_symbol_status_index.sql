-- Composite index for the live-P/L read path.
--
-- emitLiveUpdates() in packages/engine-core/src/engine.ts runs per symbol every
-- 500ms and issues:
--     WHERE "tenantId" = $1 AND "symbolId" = $2 AND status = 'OPEN'
--
-- The existing indexes cover these columns only separately, so the planner
-- BitmapAnds positions_symbolId_idx with positions_status_idx and then filters
-- tenantId on the heap. Measured on a 3.4M-row table (380k open / 3M closed,
-- Postgres 16): 387k + 380k index entries scanned, 6721 buffers, 24.6ms warm.
-- With this index: a single index scan, 4983 buffers, 10.5ms - 2.3x faster.
--
-- CONCURRENTLY because positions is written on every open, close and modify;
-- a plain CREATE INDEX takes an ACCESS EXCLUSIVE lock and would stall trading
-- for the duration of the build. CONCURRENTLY cannot run inside a transaction
-- block, so this file must NOT be wrapped in BEGIN/COMMIT, and psql must be
-- invoked without --single-transaction.
--
-- Safe to re-run: IF NOT EXISTS. If a previous attempt was interrupted, check
-- for an INVALID index first and drop it, or the create below is skipped:
--     SELECT indexrelid::regclass FROM pg_index
--      WHERE NOT indisvalid AND indrelid = 'positions'::regclass;

CREATE INDEX CONCURRENTLY IF NOT EXISTS positions_tenant_symbol_status_idx
  ON positions ("tenantId", "symbolId", status);

ANALYZE positions;
