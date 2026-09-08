$ErrorActionPreference='Continue'
cd C:\burjex
# READ-ONLY inspection of prod btrader DB: trading groups + crypto/metal symbols.
# No writes. Used to plan #2B (executionMode) + #14 (marginPercent) activation.
function DExecProd($js){
  $b=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($js))
  docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip exec -T btrader-gateway node -e "eval(Buffer.from('$b','base64').toString())" 2>&1 | Out-String
}

$q = @'
const { prisma } = require("@btrader/db");
(async () => {
  try {
    const groups = await prisma.tradingGroup.findMany({
      select: { name: true, enabled: true, executionMode: true, instantDeviationPoints: true,
                defaultBook: true, _count: { select: { accounts: true } } },
      orderBy: { name: "asc" },
    });
    console.log("=== TRADING GROUPS (name | enabled | execMode | instDevPts | book | #accts) ===");
    for (const g of groups) {
      console.log(`  ${g.name} | ${g.enabled} | ${g.executionMode} | ${g.instantDeviationPoints} | ${g.defaultBook} | ${g._count.accounts}`);
    }
    // Full class histogram first, so nothing hides in a misclassified bucket.
    const all = await prisma.symbol.findMany({
      select: { symbol: true, class: true, marginPercent: true, marginRate: true,
                contractSize: true, digits: true, enabled: true, leverageCap: true },
      orderBy: [{ class: "asc" }, { symbol: "asc" }],
    });
    const hist = {};
    for (const s of all) hist[s.class] = (hist[s.class]||0)+1;
    console.log("\n=== SYMBOL COUNT BY CLASS ===");
    for (const k of Object.keys(hist).sort()) console.log(`  ${k}: ${hist[k]}`);

    const syms = all.filter(s => ["CRYPTO","METALS","COMMODITIES"].includes(s.class)
      || /XAG|XAU|SILVER|BTC|ETH/i.test(s.symbol));
    console.log("\n=== CRYPTO / METAL / COMMODITY SYMBOLS (symbol | class | marginPercent | marginRate | contractSize | digits | levCap | enabled) ===");
    if (!syms.length) console.log("  (none matched)");
    for (const s of syms) {
      console.log(`  ${s.symbol} | ${s.class} | ${s.marginPercent==null?"null":s.marginPercent} | ${s.marginRate} | ${s.contractSize} | ${s.digits} | ${s.leverageCap==null?"-":s.leverageCap} | ${s.enabled}`);
    }
    console.log("\n=== totals ===");
    console.log("  groups: " + groups.length + " | total symbols: " + all.length + " | crypto/metal/commodity: " + syms.length);
  } catch (e) { console.log("INSPECT FAIL " + e.message); }
  process.exit(0);
})();
'@
Write-Host (DExecProd $q)
