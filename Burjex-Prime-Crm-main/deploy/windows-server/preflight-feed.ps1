#Requires -Version 5.1
<#
.SYNOPSIS
  Post-bring-up feed health check for Windows Server (stack + bridge).

.DESCRIPTION
  Run AFTER:
    1. .\up.ps1          (Docker stack with --env-file)
    2. Bridge service up (.\setup-bridge-service.ps1 -Start)

  Verifies:
    - GET http://127.0.0.1:4300/health  -> ok + lastTickAt fresh
    - Windows service BurjexMt5Bridge is Running
    - Bridge config FeedUrl is localhost when stack is same-machine
    - Reminds: NEVER docker compose without --env-file

.EXAMPLE
  .\preflight-feed.ps1
  .\preflight-feed.ps1 -MaxTickAgeSec 30
  .\preflight-feed.ps1 -BridgeDir "C:\burjex\btrader\bridges\mt5-manager-python"
#>
param(
  [string]$HealthUrl = "http://127.0.0.1:4300/health",
  [int]$MaxTickAgeSec = 15,
  [string]$ServiceName = "BurjexMt5Bridge",
  [string]$BridgeDir = "",
  [string]$ConfigName = "config.json",
  [switch]$SkipBridgeService,
  [switch]$AllowRemoteFeedUrl
)

$ErrorActionPreference = "Stop"
$fail = 0
$warn = 0

function Write-Ok([string]$msg) { Write-Host "OK   $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) {
  Write-Host "WARN $msg" -ForegroundColor Yellow
  $script:warn++
}
function Write-Fail([string]$msg) {
  Write-Host "FAIL $msg" -ForegroundColor Red
  $script:fail++
}

Write-Host ""
Write-Host "=== Burjex feed preflight ===" -ForegroundColor Cyan
Write-Host @"

CRITICAL REMINDER - NEVER run bare compose:
  docker compose up -d
  docker compose up -d --force-recreate

ALWAYS use this pack (injects --env-file deploy\.env.prod.ip):
  .\up.ps1
  .\recreate.ps1
  .\restart.ps1 <service>
  .\ps.ps1
  .\logs.ps1 btrader-market-data

Missing --env-file -> empty BT_*/DATABASE_URL/REDIS_URL -> market-data crash-loop
-> :4300 timeouts -> price stutter (laptop->VPS gap/ruk-ruk).

CUTOVER: stop the laptop / old-PC bridge BEFORE starting this server's bridge.
Two bridges posting ticks = chaos (duplicate / fighting feed).

"@ -ForegroundColor DarkYellow

# -- 1) Ingest health ----------------------------------------------------------
Write-Host "-- ingest health ($HealthUrl)" -ForegroundColor Cyan
try {
  $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 8
  if ($resp.StatusCode -ne 200) {
    Write-Fail "HTTP $($resp.StatusCode) from $HealthUrl"
  } else {
    $body = $resp.Content | ConvertFrom-Json
    if (-not $body.ok) {
      Write-Fail "/health ok=false  body=$($resp.Content)"
    } else {
      Write-Ok "/health ok=true  received=$($body.received)  lastTickAt=$($body.lastTickAt)"
      $last = [int64]$body.lastTickAt
      if ($last -le 0) {
        Write-Fail "lastTickAt is 0 - no ticks accepted yet (is bridge running? MT5 connected?)"
      } else {
        # Adapter stores Date.now() ms wall clock (PS 5.1 safe epoch)
        $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $epochMs = [int64]([DateTime]::UtcNow - $epoch).TotalMilliseconds
        $ageSec = [math]::Round(($epochMs - $last) / 1000.0, 1)
        if ($ageSec -lt 0) { $ageSec = 0 }
        if ($ageSec -gt $MaxTickAgeSec) {
          Write-Fail ("lastTickAt stale: age={0}s (max {1}s) - feed gap / bridge stuck / market-data overloaded" -f $ageSec, $MaxTickAgeSec)
        } else {
          Write-Ok ("lastTickAt fresh: age={0}s (max {1}s)" -f $ageSec, $MaxTickAgeSec)
        }
      }
    }
  }
} catch {
  Write-Fail "Cannot reach $HealthUrl - $($_.Exception.Message)"
  Write-Host "       Is Docker up? Did you run .\up.ps1 (with env-file)?" -ForegroundColor DarkYellow
}

# -- 2) Bridge Windows service -------------------------------------------------
Write-Host ""
Write-Host "-- bridge service ($ServiceName)" -ForegroundColor Cyan
if ($SkipBridgeService) {
  Write-Warn "Skipped service check (-SkipBridgeService)"
} else {
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if (-not $svc) {
    Write-Fail "Service '$ServiceName' not found. Install with .\setup-bridge-service.ps1 -Start"
  } elseif ($svc.Status -ne 'Running') {
    Write-Fail "Service '$ServiceName' status=$($svc.Status) (want Running). Start: nssm start $ServiceName"
  } else {
    Write-Ok "Service '$ServiceName' is Running"
  }
}

# -- 3) Bridge FeedUrl sanity (same-machine) -----------------------------------
Write-Host ""
Write-Host "-- bridge FeedUrl (same-machine expect 127.0.0.1/localhost)" -ForegroundColor Cyan

function Resolve-BridgeDirLocal {
  param([string]$Hint)
  if ($Hint -and (Test-Path (Join-Path $Hint "mt5_bridge.py"))) {
    return (Resolve-Path $Hint).Path
  }
  $candidates = @(
    (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "btrader\bridges\mt5-manager-python"),
    "C:\burjex\btrader\bridges\mt5-manager-python",
    "D:\burjex\btrader\bridges\mt5-manager-python",
    "D:\Burjex-Prime-Crm-main\btrader\bridges\mt5-manager-python"
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "mt5_bridge.py")) { return (Resolve-Path $c).Path }
  }
  return $null
}

$bridge = Resolve-BridgeDirLocal -Hint $BridgeDir
if (-not $bridge) {
  Write-Warn "Could not locate bridge folder - skip FeedUrl check (pass -BridgeDir)"
} else {
  $configPath = Join-Path $bridge $ConfigName
  if (-not (Test-Path $configPath)) {
    Write-Fail "Missing $configPath - copy from config.windows-server.json.example"
  } else {
    try {
      $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
      $cfg = $raw | ConvertFrom-Json
      $feedUrl = [string]$cfg.FeedUrl
      Write-Host "     config: $configPath"
      Write-Host "     FeedUrl: $feedUrl"
      Write-Host ("     TickFlushMs: {0}  ReconcileEnabled: {1}  GroupsReconcileEnabled: {2}" -f $cfg.TickFlushMs, $cfg.ReconcileEnabled, $cfg.GroupsReconcileEnabled)

      $isLocal = $feedUrl -match '(?i)^https?://(127\.0\.0\.1|localhost)(:\d+)?(/.*)?$'
      if ($AllowRemoteFeedUrl) {
        if ($isLocal) { Write-Ok "FeedUrl is local (hybrid override allowed)" }
        else { Write-Warn "FeedUrl is remote ($feedUrl) - hybrid mode; ensure FEED_ALLOWED_IPS on target includes this host" }
      } else {
        if (-not $isLocal) {
          Write-Warn "FeedUrl='$feedUrl' is NOT 127.0.0.1/localhost while stack is expected local. Same-machine must use http://127.0.0.1:4300 (not public IP / not host.docker.internal). Use -AllowRemoteFeedUrl only for hybrid Linux-VPS ingest."
        } else {
          Write-Ok "FeedUrl targets localhost (same-machine path)"
        }
      }

      $flush = 0
      if ($null -ne $cfg.TickFlushMs) { $flush = [int]$cfg.TickFlushMs }
      if ($flush -le 0) {
        Write-Warn "TickFlushMs missing - bridge defaults may be slower; set TickFlushMs=50"
      } elseif ($flush -gt 100) {
        Write-Warn "TickFlushMs=$flush is high - prefer 50 for snappy quotes"
      } else {
        Write-Ok "TickFlushMs=$flush"
      }

      if ($cfg.ReconcileEnabled -eq $true) {
        Write-Warn "ReconcileEnabled=true - can fight admin symbol state; prefer false until cutover is stable"
      }
      if ($cfg.GroupsReconcileEnabled -eq $true) {
        Write-Warn "GroupsReconcileEnabled=true - prefer false for stable cutover"
      }
    } catch {
      Write-Fail "Cannot parse $configPath - $($_.Exception.Message)"
    }
  }
}

# -- 4) Env-file presence ------------------------------------------------------
Write-Host ""
Write-Host "-- env-file present for compose" -ForegroundColor Cyan
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) ".env.prod.ip"
if (Test-Path -LiteralPath $envFile) {
  Write-Ok "Found $envFile"
} else {
  Write-Fail "Missing $envFile - copy from .env.windows-server.example before .\up.ps1"
}

Write-Host ""
if ($fail -gt 0) {
  Write-Host ("PREFLIGHT FAILED ({0} fail, {1} warn)" -f $fail, $warn) -ForegroundColor Red
  exit 1
}
if ($warn -gt 0) {
  Write-Host ("PREFLIGHT OK WITH WARNINGS ({0} warn)" -f $warn) -ForegroundColor Yellow
  exit 0
}
Write-Host "PREFLIGHT PASSED - feed path looks healthy" -ForegroundColor Green
exit 0
