$ErrorActionPreference='Continue'
$B='http://localhost:5100/v1'; $T='demo'
cd C:\burjex
function DExecNode($js){
  $b=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($js))
  docker compose -f deploy/docker-compose.staging.yml --env-file deploy/.env.staging exec -T gateway-api node -e "eval(Buffer.from('$b','base64').toString())" 2>&1 | Out-String
}
function Pub($tid,$bid,$ask){
  $tick = 'const R=require("ioredis");const r=new R(process.env.REDIS_URL);r.publish("bt:' + $tid + ':ticks",JSON.stringify({symbol:"EURTEST",bid:' + $bid + ',ask:' + $ask + ',ts:Date.now()})).then(n=>{console.log("TICK->"+n);return r.quit()}).then(()=>process.exit(0));'
  (DExecNode $tick).Trim() | Out-Null
}
function Place($tok,$acct,$price){
  $ord = @{accountId=$acct; symbol='EURTEST'; side='BUY'; type='MARKET'; volume=0.1; price=$price; oneClick=$true} | ConvertTo-Json
  try {
    $r = Invoke-RestMethod -Uri "$B/orders" -Method Post -Headers @{'X-BT-Tenant'=$T;'Authorization'="Bearer $tok"} -ContentType 'application/json' -Body $ord
    return @{ ok=$true; body=$r }
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    $msg  = $_.ErrorDetails.Message
    return @{ ok=$false; status=$code; body=$msg }
  }
}

# 1. Seed: symbol EURTEST (5-digit, markup irrelevant), and TWO groups —
#    G_INSTANT (executionMode INSTANT, instantDeviationPoints 20) and
#    G_MARKET (executionMode MARKET) — each with its own account.
$seed = @'
const { prisma } = require("@btrader/db");
const bcrypt = require("bcryptjs");
(async () => {
  try {
    let t = await prisma.tenant.findFirst({ where: { slug: "demo" } });
    if (!t) t = await prisma.tenant.create({ data: { name: "Demo", slug: "demo" } });
    const symData = { class: "CRYPTO", baseCurrency: "EUR", quoteCurrency: "USD", digits: 5, pipSize: 0.0001,
      contractSize: 100000, minLot: 0.01, maxLot: 100, lotStep: 0.01, marginCurrency: "USD", marginRate: 1,
      slippagePoints: 0, spreadMarkup: 0, enabled: true };
    let sy = await prisma.symbol.findFirst({ where: { tenantId: t.id, symbol: "EURTEST" } });
    if (sy) sy = await prisma.symbol.update({ where: { id: sy.id }, data: symData });
    else   sy = await prisma.symbol.create({ data: { tenantId: t.id, symbol: "EURTEST", ...symData } });

    async function grp(name, mode, dev){
      let g = await prisma.tradingGroup.findFirst({ where: { tenantId: t.id, name } });
      const data = { markupPoints: 0, slippagePoints: 0, executionMode: mode, instantDeviationPoints: dev, enabled: true, defaultLeverage: 100 };
      if (g) g = await prisma.tradingGroup.update({ where: { id: g.id }, data });
      else   g = await prisma.tradingGroup.create({ data: { tenantId: t.id, name, ...data } });
      return g;
    }
    const gi = await grp("G_INSTANT_2B", "INSTANT", 20);
    const gm = await grp("G_MARKET_2B",  "MARKET",  0);

    async function acct(groupId, tag){
      const u = await prisma.user.create({ data: { tenantId: t.id, email: tag+Date.now()+"@t.local", role: "TRADER" } });
      const login = tag + Date.now().toString().slice(-6);
      const a = await prisma.account.create({ data: { tenantId: t.id, userId: u.id, login, groupId,
        passwordHash: await bcrypt.hash("Pass1234", 10), currency: "USD", leverage: 100, balance: 100000 } });
      return { login, id: a.id };
    }
    const ai = await acct(gi.id, "INST");
    const am = await acct(gm.id, "MKT");
    console.log("SEEDOK " + JSON.stringify({ tenantId: t.id,
      instLogin: ai.login, instAcct: ai.id, mktLogin: am.login, mktAcct: am.id,
      instMode: gi.executionMode, instDev: gi.instantDeviationPoints, mktMode: gm.executionMode }));
  } catch (e) { console.log("SEEDFAIL " + e.message); }
  process.exit(0);
})();
'@
$o = DExecNode $seed
if ($o -notmatch 'SEEDOK (\{.*\})') { Write-Host "SEED FAIL: $o" -ForegroundColor Red; return }
$s = $Matches[1] | ConvertFrom-Json; $TID=$s.tenantId
Write-Host ("seeded  tenant=$TID") -ForegroundColor Green
Write-Host ("  INSTANT group: mode=$($s.instMode) deviationPoints=$($s.instDev)  acct=$($s.instAcct)")
Write-Host ("  MARKET  group: mode=$($s.mktMode)  acct=$($s.mktAcct)")

# 2. Login both accounts.
$tokI = (Invoke-RestMethod -Uri "$B/auth/account-login" -Method Post -Headers @{'X-BT-Tenant'=$T} -ContentType 'application/json' -Body (@{login=$s.instLogin;password='Pass1234'}|ConvertTo-Json)).accessToken
$tokM = (Invoke-RestMethod -Uri "$B/auth/account-login" -Method Post -Headers @{'X-BT-Tenant'=$T} -ContentType 'application/json' -Body (@{login=$s.mktLogin;password='Pass1234'}|ConvertTo-Json)).accessToken

# point size for 5-digit = 0.00001; 20 pts = 0.0002. Tick1 ask=1.10010.
$askOld = 1.10010

Write-Host "`n=== TEST A: INSTANT, price unchanged -> HONOUR at clicked price ===" -ForegroundColor Cyan
Pub $TID 1.10000 1.10010; Start-Sleep -Seconds 1
$ra = Place $tokI $s.instAcct $askOld
if ($ra.ok) {
  $fill=[double]$ra.body.fillPrice
  Write-Host ("  order OK  filled=$fill  clicked=$askOld  (fillPrice==clicked => zero slippage)")
  if ([math]::Abs($fill-$askOld) -lt 1e-7) { Write-Host "  PASS - honoured exactly at clicked price, zero slippage" -ForegroundColor Green }
  else { Write-Host "  FAIL - expected fill==clicked==$askOld, got $fill" -ForegroundColor Red }
} else { Write-Host ("  FAIL - expected fill, got HTTP $($ra.status): $($ra.body)") -ForegroundColor Red }

Write-Host "`n=== TEST B: INSTANT, market jumped +100pts, stale click -> REQUOTE 409 ===" -ForegroundColor Cyan
Pub $TID 1.10100 1.10110; Start-Sleep -Seconds 1
$rb = Place $tokI $s.instAcct $askOld
if (-not $rb.ok -and $rb.status -eq 409) {
  $body = $rb.body | ConvertFrom-Json
  Write-Host ("  HTTP 409  code=$($body.code)  newPrice=$($body.details.newPrice)  requested=$($body.details.requestedPrice)")
  if ($body.code -eq 'BT_REQUOTE' -and [double]$body.details.newPrice -gt $askOld) { Write-Host "  PASS - requoted with the moved price, no fill" -ForegroundColor Green }
  else { Write-Host "  FAIL - 409 but not a proper REQUOTE payload" -ForegroundColor Red }
} else { Write-Host ("  FAIL - expected 409 REQUOTE, got ok=$($rb.ok) status=$($rb.status) body=$($rb.body)") -ForegroundColor Red }

Write-Host "`n=== TEST C: MARKET group, same +100pt jump, stale click -> FILLS AT MARKET (no requote) ===" -ForegroundColor Cyan
# tick still 1.10100/1.10110 from Test B.
$rc = Place $tokM $s.mktAcct $askOld
if ($rc.ok) {
  $fill=[double]$rc.body.fillPrice
  Write-Host ("  order OK  filled=$fill  (market ask=1.10110)")
  if ([math]::Abs($fill-1.10110) -lt 1e-6) { Write-Host "  PASS - MARKET group ignored the stale click, filled at market" -ForegroundColor Green }
  else { Write-Host "  FAIL - expected market fill ~1.10110, got $fill" -ForegroundColor Red }
} else { Write-Host ("  FAIL - MARKET group should fill, got HTTP $($rc.status): $($rc.body)") -ForegroundColor Red }

Write-Host "`n=== #2B SUMMARY ===" -ForegroundColor Cyan
Write-Host "A honour / B requote / C market-control above. All three PASS => Instant execution + per-group executionMode works."
