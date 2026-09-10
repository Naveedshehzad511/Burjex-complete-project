-- Trading group Instant / Market delay + per-kind apply flags
-- Safe to re-run (IF NOT EXISTS).

ALTER TABLE trading_groups
  ADD COLUMN IF NOT EXISTS "executionDelayMs" INTEGER NOT NULL DEFAULT 0;

ALTER TABLE trading_groups
  ADD COLUMN IF NOT EXISTS "executionApplyTo" JSONB NOT NULL DEFAULT '{}'::jsonb;
