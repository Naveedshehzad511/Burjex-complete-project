-- Idempotent client order ids + trigger audit columns.
-- Partial unique: many NULL clientOrderId rows are allowed.
-- Safe to re-run.

ALTER TABLE orders ADD COLUMN IF NOT EXISTS "clientOrderId" TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS "triggeredAt" TIMESTAMPTZ;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS "stopTriggered" BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS orders_tenant_account_client_order_uidx
  ON orders ("tenantId", "accountId", "clientOrderId")
  WHERE "clientOrderId" IS NOT NULL;

ANALYZE orders;
