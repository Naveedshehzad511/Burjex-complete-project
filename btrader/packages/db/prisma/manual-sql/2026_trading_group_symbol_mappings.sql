-- Per-symbol LP → Client mappings + pricing for trading groups.
-- Apply with prisma db push / migrate, or run this SQL by hand.

DO $$ BEGIN
  CREATE TYPE "SymbolPricingMethod" AS ENUM (
    'SPREAD_ONLY',
    'COMMISSION_ONLY',
    'SPREAD_AND_COMMISSION'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON e.enumtypid = t.oid
    WHERE t.typname = 'GroupCommissionType' AND e.enumlabel = 'ROUND_TURN'
  ) THEN
    ALTER TYPE "GroupCommissionType" ADD VALUE 'ROUND_TURN';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS "trading_group_symbol_mappings" (
  "id"              TEXT NOT NULL,
  "tradingGroupId"  TEXT NOT NULL,
  "lpSymbol"        TEXT NOT NULL,
  "clientSymbol"    TEXT NOT NULL,
  "symbolId"        TEXT,
  "pricingMethod"   "SymbolPricingMethod" NOT NULL DEFAULT 'SPREAD_ONLY',
  "minSpreadPoints" INTEGER NOT NULL DEFAULT 0,
  "maxSpreadPoints" INTEGER NOT NULL DEFAULT 0,
  "commissionType"  "GroupCommissionType" NOT NULL DEFAULT 'NONE',
  "commissionValue" DECIMAL(18, 6) NOT NULL DEFAULT 0,
  "enabled"         BOOLEAN NOT NULL DEFAULT true,
  "sortOrder"       INTEGER NOT NULL DEFAULT 0,
  "createdAt"       TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt"       TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "trading_group_symbol_mappings_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "trading_group_symbol_mappings_tradingGroupId_lpSymbol_key"
  ON "trading_group_symbol_mappings" ("tradingGroupId", "lpSymbol");

CREATE UNIQUE INDEX IF NOT EXISTS "trading_group_symbol_mappings_tradingGroupId_clientSymbol_key"
  ON "trading_group_symbol_mappings" ("tradingGroupId", "clientSymbol");

CREATE INDEX IF NOT EXISTS "trading_group_symbol_mappings_tradingGroupId_idx"
  ON "trading_group_symbol_mappings" ("tradingGroupId");

CREATE INDEX IF NOT EXISTS "trading_group_symbol_mappings_symbolId_idx"
  ON "trading_group_symbol_mappings" ("symbolId");

DO $$ BEGIN
  ALTER TABLE "trading_group_symbol_mappings"
    ADD CONSTRAINT "trading_group_symbol_mappings_tradingGroupId_fkey"
    FOREIGN KEY ("tradingGroupId") REFERENCES "trading_groups" ("id")
    ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE "trading_group_symbol_mappings"
    ADD CONSTRAINT "trading_group_symbol_mappings_symbolId_fkey"
    FOREIGN KEY ("symbolId") REFERENCES "symbols" ("id")
    ON DELETE SET NULL ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
