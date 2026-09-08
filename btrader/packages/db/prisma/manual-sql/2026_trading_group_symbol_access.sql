-- Instrument visibility per client trading group.
-- Apply automatically with:  pnpm --filter @btrader/db db:generate && prisma db push
-- (or run this SQL by hand if you manage the schema manually).
--
-- An empty set for a trading group = that group sees ALL enabled symbols
-- (backward compatible). One or more rows = it sees ONLY the listed symbol
-- groups, intersected with each symbol's `enabled` flag.

CREATE TABLE IF NOT EXISTS "trading_group_symbol_access" (
  "tradingGroupId" TEXT NOT NULL,
  "symbolGroupId"  TEXT NOT NULL,
  CONSTRAINT "trading_group_symbol_access_pkey" PRIMARY KEY ("tradingGroupId", "symbolGroupId")
);

CREATE INDEX IF NOT EXISTS "trading_group_symbol_access_symbolGroupId_idx"
  ON "trading_group_symbol_access" ("symbolGroupId");

ALTER TABLE "trading_group_symbol_access"
  ADD CONSTRAINT "trading_group_symbol_access_tradingGroupId_fkey"
  FOREIGN KEY ("tradingGroupId") REFERENCES "trading_groups" ("id")
  ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "trading_group_symbol_access"
  ADD CONSTRAINT "trading_group_symbol_access_symbolGroupId_fkey"
  FOREIGN KEY ("symbolGroupId") REFERENCES "symbol_groups" ("id")
  ON DELETE CASCADE ON UPDATE CASCADE;
