param([switch]$Apply)
$ErrorActionPreference='Continue'
cd C:\burjex
# #2B + #14 activation on PROD. DRY-RUN by default (lists the plan, writes nothing).
# Re-run with  -Apply  to perform the writes (inside a transaction) + verify.
#   #2B: group 'standard'  MARKET -> INSTANT, instantDeviationPoints 20
#   #14: enabled CRYPTO symbols marginPercent -> 0.20 (20% = 5x)
#        SILVER (XAGUSD) marginPercent -> 0.05 (5% = 20x). GOLD left null per spec ('crypto/silver').
#   Scope: enabled=true only (disabled .E/.P/.S/.M variants untouched). Commodities + gold untouched.
function DExecProd($js){
  $b=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($js))
  docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip exec -T btrader-gateway node -e "eval(Buffer.from('$b','base64').toString())" 2>&1 | Out-String
}
$mode = if ($Apply) { "APPLY" } else { "DRYRUN" }

# JS in a SINGLE-quoted here-string so PowerShell never touches the ${...} / $transaction.
# __MODE__ is the only value injected from PowerShell (replaced below).
$js = @'
const { prisma } = require("@btrader/db");
const MODE = "__MODE__";
const CRYPTO_PCT = 0.20, METALS_PCT = 0.05, TOL = 20;
(async () => {
 try {
  const grp = await prisma.tradingGroup.findMany({ where: { name: "standard" },
    select: { id:true, name:true, executionMode:true, instantDeviationPoints:true } });
  const crypto = await prisma.symbol.findMany({ where: { enabled:true, class:"CRYPTO" },
    select: { symbol:true, marginPercent:true } });
  const metals = await prisma.symbol.findMany({ where: { enabled:true, symbol:"XAGUSD" },
    select: { symbol:true, marginPercent:true } });

  console.log("=== #2B PLAN: group 'standard' ===");
  for (const g of grp) console.log("  " + g.name + ": execMode " + g.executionMode + " -> INSTANT | instDevPts " + g.instantDeviationPoints + " -> " + TOL);
  console.log("\n=== #14 PLAN: CRYPTO -> " + CRYPTO_PCT + " (enabled: " + crypto.length + ") ===");
  console.log("  " + crypto.map(s=>s.symbol).join(", "));
  console.log("\n=== #14 PLAN: SILVER only (XAGUSD) -> " + METALS_PCT + " (matched: " + metals.length + ") ===");
  for (const s of metals) console.log("  " + s.symbol + ": " + (s.marginPercent==null?"null":s.marginPercent) + " -> " + METALS_PCT);
  console.log("  (gold XAU/GAU/GDI left null per 'crypto/silver' spec)");

  if (MODE !== "APPLY") { console.log("\n*** DRY RUN - nothing written. Re-run with -Apply to commit. ***"); process.exit(0); }

  const res = await prisma.$transaction(async (tx) => {
    const g = await tx.tradingGroup.updateMany({ where:{ name:"standard" }, data:{ executionMode:"INSTANT", instantDeviationPoints: TOL } });
    const c = await tx.symbol.updateMany({ where:{ enabled:true, class:"CRYPTO" }, data:{ marginPercent: CRYPTO_PCT } });
    const m = await tx.symbol.updateMany({ where:{ enabled:true, symbol:"XAGUSD" }, data:{ marginPercent: METALS_PCT } });
    return { g:g.count, c:c.count, m:m.count };
  });
  console.log("\n=== APPLIED: groups " + res.g + ", crypto " + res.c + ", metals " + res.m + " ===");

  const g2 = await prisma.tradingGroup.findMany({ where:{ name:"standard" }, select:{ name:true, executionMode:true, instantDeviationPoints:true } });
  const c2 = await prisma.symbol.count({ where:{ enabled:true, class:"CRYPTO", marginPercent: CRYPTO_PCT } });
  const cTot = await prisma.symbol.count({ where:{ enabled:true, class:"CRYPTO" } });
  const m2 = await prisma.symbol.count({ where:{ enabled:true, symbol:"XAGUSD", marginPercent: METALS_PCT } });
  const mTot = await prisma.symbol.count({ where:{ enabled:true, symbol:"XAGUSD" } });
  console.log("\n=== VERIFY ===");
  for (const g of g2) console.log("  standard: " + g.executionMode + " @ " + g.instantDeviationPoints + "pts  " + ((g.executionMode==="INSTANT"&&g.instantDeviationPoints===TOL)?"OK":"MISMATCH"));
  console.log("  crypto at " + CRYPTO_PCT + ": " + c2 + "/" + cTot + "  " + (c2===cTot?"OK":"MISMATCH"));
  console.log("  silver XAGUSD at " + METALS_PCT + ": " + m2 + "/" + mTot + "  " + (m2===mTot?"OK":"MISMATCH"));
 } catch (e) { console.log("ACTIVATE FAIL " + e.message); }
 process.exit(0);
})();
'@
$js = $js -replace '__MODE__', $mode
Write-Host ("MODE: $mode`n")
Write-Host (DExecProd $js)
