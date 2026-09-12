-- Protective / pending execution claims + audit columns on positions.
-- Safe to re-run (IF NOT EXISTS).

ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execClaimKind" TEXT;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execClaimedAt" TIMESTAMPTZ;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execClaimedBy" TEXT;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execTriggerAt" TIMESTAMPTZ;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execDeadlineAt" TIMESTAMPTZ;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execDelayMs" INTEGER;
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execTriggerBid" NUMERIC(20, 8);
ALTER TABLE positions ADD COLUMN IF NOT EXISTS "execTriggerAsk" NUMERIC(20, 8);

CREATE INDEX IF NOT EXISTS positions_status_claim_idx
  ON positions (status, "execClaimedAt");
