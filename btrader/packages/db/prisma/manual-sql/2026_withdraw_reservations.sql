-- Withdrawal reservations for trading-account withdrawals.
--
-- "reservedWithdraw"      = sum of the account's RESERVED withdrawal requests. The matching engine keeps that much of
--                           the free margin out of reach of new trades and triggered pending orders.
-- withdraw_reservations   = one row per CRM request ("externalRef" is unique), RESERVED -> RELEASED | FINALIZED.
--
-- Additive and idempotent (same result as `prisma db push`). Apply this BEFORE rolling out the engine and the
-- gateway: the engine selects "reservedWithdraw", so a new engine on an old database cannot read any account.
DO $$ BEGIN
  CREATE TYPE "WithdrawReservationStatus" AS ENUM ('RESERVED', 'RELEASED', 'FINALIZED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE accounts
  ADD COLUMN IF NOT EXISTS "reservedWithdraw" DECIMAL(28, 8) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS withdraw_reservations (
  id            TEXT PRIMARY KEY,
  "tenantId"    TEXT NOT NULL,
  "accountId"   TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT ON UPDATE CASCADE,
  "externalRef" TEXT NOT NULL,
  amount        DECIMAL(28, 8) NOT NULL,
  status        "WithdrawReservationStatus" NOT NULL DEFAULT 'RESERVED',
  "createdAt"   TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "settledAt"   TIMESTAMP(3)
);
CREATE UNIQUE INDEX IF NOT EXISTS "withdraw_reservations_externalRef_key" ON withdraw_reservations ("externalRef");
CREATE INDEX IF NOT EXISTS "withdraw_reservations_accountId_status_idx" ON withdraw_reservations ("accountId", status);
