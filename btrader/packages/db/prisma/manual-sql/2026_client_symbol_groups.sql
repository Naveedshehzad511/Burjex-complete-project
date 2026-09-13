-- Reusable alias-symbol packs (admin: Symbols → Symbols Group).
-- Feed XAUUSD → client XAUUSD.s + spread and/or commission.
-- A trading group assigns one pack; engine still reads trading_group_symbol_mappings.

CREATE TABLE IF NOT EXISTS "client_symbol_groups" (
  "id"          TEXT NOT NULL,
  "tenantId"    TEXT NOT NULL,
  "name"        TEXT NOT NULL,
  "description" TEXT,
  "enabled"     BOOLEAN NOT NULL DEFAULT true,
  "createdAt"   TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt"   TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "client_symbol_groups_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "client_symbol_groups_tenantId_name_key"
  ON "client_symbol_groups" ("tenantId", "name");

CREATE INDEX IF NOT EXISTS "client_symbol_groups_tenantId_idx"
  ON "client_symbol_groups" ("tenantId");

DO $$ BEGIN
  ALTER TABLE "client_symbol_groups"
    ADD CONSTRAINT "client_symbol_groups_tenantId_fkey"
    FOREIGN KEY ("tenantId") REFERENCES "tenants" ("id")
    ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS "client_symbol_group_items" (
  "id"              TEXT NOT NULL,
  "groupId"         TEXT NOT NULL,
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
  CONSTRAINT "client_symbol_group_items_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "client_symbol_group_items_groupId_lpSymbol_key"
  ON "client_symbol_group_items" ("groupId", "lpSymbol");

CREATE UNIQUE INDEX IF NOT EXISTS "client_symbol_group_items_groupId_clientSymbol_key"
  ON "client_symbol_group_items" ("groupId", "clientSymbol");

CREATE INDEX IF NOT EXISTS "client_symbol_group_items_groupId_idx"
  ON "client_symbol_group_items" ("groupId");

CREATE INDEX IF NOT EXISTS "client_symbol_group_items_symbolId_idx"
  ON "client_symbol_group_items" ("symbolId");

DO $$ BEGIN
  ALTER TABLE "client_symbol_group_items"
    ADD CONSTRAINT "client_symbol_group_items_groupId_fkey"
    FOREIGN KEY ("groupId") REFERENCES "client_symbol_groups" ("id")
    ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE "client_symbol_group_items"
    ADD CONSTRAINT "client_symbol_group_items_symbolId_fkey"
    FOREIGN KEY ("symbolId") REFERENCES "symbols" ("id")
    ON DELETE SET NULL ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE "trading_groups"
  ADD COLUMN IF NOT EXISTS "clientSymbolGroupId" TEXT;

CREATE INDEX IF NOT EXISTS "trading_groups_clientSymbolGroupId_idx"
  ON "trading_groups" ("clientSymbolGroupId");

DO $$ BEGIN
  ALTER TABLE "trading_groups"
    ADD CONSTRAINT "trading_groups_clientSymbolGroupId_fkey"
    FOREIGN KEY ("clientSymbolGroupId") REFERENCES "client_symbol_groups" ("id")
    ON DELETE SET NULL ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Backfill: each trading group that already has inline mappings gets a pack
-- named "{group} symbols" and is attached to it.
DO $$
DECLARE
  tg RECORD;
  pack_id TEXT;
  pack_name TEXT;
BEGIN
  FOR tg IN
    SELECT id, "tenantId", name
    FROM trading_groups
    WHERE "clientSymbolGroupId" IS NULL
      AND EXISTS (
        SELECT 1 FROM trading_group_symbol_mappings m
        WHERE m."tradingGroupId" = trading_groups.id
      )
  LOOP
    pack_id := gen_random_uuid()::text;
    pack_name := tg.name || ' symbols';
    IF EXISTS (
      SELECT 1 FROM client_symbol_groups c
      WHERE c."tenantId" = tg."tenantId" AND c.name = pack_name
    ) THEN
      pack_name := tg.name || ' symbols (' || left(tg.id, 8) || ')';
    END IF;

    INSERT INTO client_symbol_groups (id, "tenantId", name, enabled, "createdAt", "updatedAt")
    VALUES (pack_id, tg."tenantId", pack_name, true, NOW(), NOW());

    INSERT INTO client_symbol_group_items (
      id, "groupId", "lpSymbol", "clientSymbol", "symbolId",
      "pricingMethod", "minSpreadPoints", "maxSpreadPoints",
      "commissionType", "commissionValue", enabled, "sortOrder",
      "createdAt", "updatedAt"
    )
    SELECT
      gen_random_uuid()::text,
      pack_id,
      m."lpSymbol",
      m."clientSymbol",
      m."symbolId",
      m."pricingMethod",
      m."minSpreadPoints",
      m."maxSpreadPoints",
      m."commissionType",
      m."commissionValue",
      m.enabled,
      m."sortOrder",
      NOW(),
      NOW()
    FROM trading_group_symbol_mappings m
    WHERE m."tradingGroupId" = tg.id;

    UPDATE trading_groups
    SET "clientSymbolGroupId" = pack_id
    WHERE id = tg.id;
  END LOOP;
END $$;
