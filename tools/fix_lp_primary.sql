SELECT code, enabled, "isPrimaryFeed", "staleMs", transport, "symbolSuffix", left("feedToken",12) AS tok FROM liquidity_providers;
UPDATE liquidity_providers
SET "isPrimaryFeed" = true,
    "staleMs" = 300000,
    enabled = true,
    "symbolSuffix" = COALESCE(NULLIF("symbolSuffix", ''), '.m.ME8.1')
WHERE enabled = true OR code = '00000';
SELECT code, enabled, "isPrimaryFeed", "staleMs", transport, "symbolSuffix", left("feedToken",12) AS tok FROM liquidity_providers;
