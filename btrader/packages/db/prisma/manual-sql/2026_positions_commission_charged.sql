-- Commission is debited from the balance when a trade is executed (not when it closes).
--
-- "commissionCharged" = commission already debited at open (negative when charged).
-- "commission"        = commission still to be realized at close. Positions that were open
--                       before this change keep their value here and are charged exactly once,
--                       at close, as before. New positions are stored with commission = 0.
--
-- Safe to run before the new engine is deployed: existing rows default to 0, so nothing changes
-- until the engine starts writing the column. Apply this BEFORE rolling out the engine.
ALTER TABLE positions
  ADD COLUMN IF NOT EXISTS "commissionCharged" DECIMAL(28, 8) NOT NULL DEFAULT 0;
