$ErrorActionPreference='Continue'
$B='http://localhost:5100/v1'; $T='demo'
cd C:\burjex
function DExecNode($js){
  $b=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($js))
  docker compose -f deploy/docker-compose.staging.yml --env-file deploy/.env.staging exec -T gateway-api node -e "eval(Buffer.from('$b','base64').toString())" 2>&1 | Out-String
}

# 1. Seed a CRYPTO symbol (marginPercent 0.10) + an account with LEVERAGE 5.
$seed = @'
const { prisma } = require("@btrader/db");
const bcrypt = require("bcryptjs");
(async () => {
  try {
    let t = await prisma.tenant.findFirst({ where: { slug: "demo" } });
    if (!t) t = await prisma.tenant.create({ data: { name: "Demo", slug: "demo" } });
    let sy = await prisma.symbol.findFirst({ where: { tenantId: t.id, symbol: "BTCUSD" } });
    const symData = { class: "CRYPTO", baseCurrency: "BTC", quoteCurrency: "USD", digits: 2, pipSize: 0.01,
      contractSize: 1, minLot: 0.01, maxLot: 100, lotStep: 0.01, marginCurrency: "USD", marginRate: 1,
      marginPercent: 0.10, enabled: true };
    if (sy) sy = await prisma.symbol.update({ where: { id: sy.id }, data: symData });
    else   sy = await prisma.symbol.create({ data: { tenantId: t.id, symbol: "BTCUSD", ...symData } });
    const u = await prisma.user.create({ data: { tenantId: t.id, email: "m14_"+Date.now()+"@t.local", role: "TRADER" } });
    const login = "M14" + Date.now().toString().slice(-7);
    const a = await prisma.account.create({ data: { tenantId: t.id, userId: u.id, login,
      passwordHash: await bcrypt.hash("Pass1234", 10), currency: "USD", leverage: 5, balance: 100000 } });
    console.log("SEEDOK " + JSON.stringify({ login, accountId: a.id, tenantId: t.id }));
  } catch (e) { console.log("SEEDFAIL " + e.message); }
  process.exit(0);
})();
'@
$o = DExecNode $seed
if ($o -notmatch 'SEEDOK (\{.*\})') { Write-Host "SEED FAIL: $o" -ForegroundColor Red; return }
$s = $Matches[1] | ConvertFrom-Json; $L=$s.login; $A=$s.accountId; $TID=$s.tenantId
Write-Host "seeded login=$L  account=$A  tenant=$TID  leverage=5  symbol=BTCUSD marginPercent=0.10" -ForegroundColor Green

# 2. Login for a session token.
$tok = (Invoke-RestMethod -Uri "$B/auth/account-login" -Method Post -Headers @{'X-BT-Tenant'=$T} -ContentType 'application/json' -Body (@{login=$L;password='Pass1234'}|ConvertTo-Json)).accessToken

# 3. Publish a fresh BTCUSD tick (bid 49990 / ask 50010) so the engine can fill.
$tick = 'const R=require("ioredis");const r=new R(process.env.REDIS_URL);r.publish("bt:' + $TID + ':ticks",JSON.stringify({symbol:"BTCUSD",bid:49990,ask:50010,ts:Date.now()})).then(n=>{console.log("TICK->"+n);return r.quit()}).then(()=>process.exit(0));'
Write-Host (DExecNode $tick).Trim()
Start-Sleep -Seconds 1

# 4. Place a market BUY 0.1 lot BTCUSD.
$ord = @{accountId=$A; symbol='BTCUSD'; side='BUY'; type='MARKET'; volume=0.1} | ConvertTo-Json
try {
  $r = Invoke-RestMethod -Uri "$B/orders" -Method Post -Headers @{'X-BT-Tenant'=$T;'Authorization'="Bearer $tok"} -ContentType 'application/json' -Body $ord
  Write-Host ("order OK: " + ($r | ConvertTo-Json -Compress)) -ForegroundColor Green
} catch { Write-Host ("ORDER FAILED: " + $_.ErrorDetails.Message) -ForegroundColor Red }

# 5. Read back the account's reserved margin.
$read = 'const{prisma}=require("@btrader/db");(async()=>{const a=await prisma.account.findUnique({where:{id:"'+$A+'"},select:{margin:true,leverage:true,balance:true,freeMargin:true}});console.log("ACCT "+JSON.stringify(a));process.exit(0)})();'
$aout = DExecNode $read
Write-Host $aout.Trim()

# 6. Verdict.
if ($aout -match 'ACCT (\{.*\})') {
  $acct = $Matches[1] | ConvertFrom-Json
  $margin = [double]$acct.margin
  Write-Host "`n=== #14 VERDICT ===" -ForegroundColor Cyan
  Write-Host "account leverage ............ 5"
  Write-Host "notional (0.1 x 1 x 50010) .. 5001"
  Write-Host "reserved margin ............. $margin"
  Write-Host "expected WITH #14 (10%) ..... ~500"
  Write-Host "would be WITHOUT #14 (/lev5)  ~1000"
  if ($margin -gt 450 -and $margin -lt 560) { Write-Host "`nPASS - crypto margin = 10% of notional, account leverage IGNORED (#14 works)" -ForegroundColor Green }
  elseif ($margin -gt 950 -and $margin -lt 1060) { Write-Host "`nFAIL - margin used leverage; marginPercent not applied" -ForegroundColor Red }
  else { Write-Host "`nUNEXPECTED margin ($margin) - inspect order/price setup" -ForegroundColor Yellow }
}
