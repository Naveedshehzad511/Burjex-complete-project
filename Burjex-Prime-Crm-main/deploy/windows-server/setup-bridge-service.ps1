#Requires -Version 5.1
<#
.SYNOPSIS
  Install mt5_bridge.py as a Windows Service (NSSM) so the feed survives RDP logoff.

.DESCRIPTION
  Prerequisites:
    - Python 3.10–3.12 (64-bit) on PATH or pass -PythonExe
    - pip install -r requirements.txt in the bridge folder (includes MT5Manager)
    - MT5 Terminal / Manager API available for that Python build
    - config.json next to mt5_bridge.py (copy from config.windows-server.json.example)
    - Docker stack already up so http://127.0.0.1:4300/health responds (same-machine mode)

  Run elevated (Administrator).

.EXAMPLE
  .\setup-bridge-service.ps1
  .\setup-bridge-service.ps1 -BridgeDir "C:\burjex\btrader\bridges\mt5-manager-python"
  .\setup-bridge-service.ps1 -Uninstall
#>
param(
  [string]$ServiceName = "BurjexMt5Bridge",
  [string]$BridgeDir = "",
  [string]$PythonExe = "",
  [string]$NssmExe = "",
  [string]$ConfigName = "config.json",
  [switch]$Uninstall,
  [switch]$Start
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $ok = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $ok) { throw "Run elevated (Administrator PowerShell)." }
}

function Resolve-BridgeDir {
  param([string]$Hint)
  if ($Hint -and (Test-Path (Join-Path $Hint "mt5_bridge.py"))) { return (Resolve-Path $Hint).Path }

  $candidates = @(
    (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "btrader\bridges\mt5-manager-python"),
    "C:\burjex\btrader\bridges\mt5-manager-python",
    "D:\burjex\btrader\bridges\mt5-manager-python"
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "mt5_bridge.py")) { return (Resolve-Path $c).Path }
  }
  throw "Could not find mt5_bridge.py. Pass -BridgeDir to the bridges\mt5-manager-python folder."
}

function Resolve-Python {
  param([string]$Hint)
  if ($Hint) {
    if (-not (Test-Path $Hint)) { throw "Python not found: $Hint" }
    return (Resolve-Path $Hint).Path
  }
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "python not on PATH. Install Python 3.10–3.12 x64 and re-open PowerShell, or pass -PythonExe."
}

function Ensure-Nssm {
  param([string]$Hint)
  if ($Hint -and (Test-Path $Hint)) { return (Resolve-Path $Hint).Path }

  $local = Join-Path $PSScriptRoot "tools\nssm\nssm.exe"
  if (Test-Path $local) { return (Resolve-Path $local).Path }

  $cmd = Get-Command nssm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  Write-Host @"

NSSM (Non-Sucking Service Manager) not found.

Download (manual, one-time):
  1. https://nssm.cc/download  → win64\nssm.exe
  2. Place at: $local
     (create folders as needed)
  3. Re-run this script.

Or install via Chocolatey (if you use it):  choco install nssm -y

"@ -ForegroundColor Yellow
  throw "nssm.exe required to install the service."
}

Assert-Admin

if ($Uninstall) {
  $nssm = Ensure-Nssm -Hint $NssmExe
  Write-Host "Stopping / removing service $ServiceName ..."
  & $nssm stop $ServiceName confirm 2>$null
  & $nssm remove $ServiceName confirm 2>$null
  Write-Host "Removed $ServiceName (if it existed)." -ForegroundColor Green
  exit 0
}

$bridge = Resolve-BridgeDir -Hint $BridgeDir
$python = Resolve-Python -Hint $PythonExe
$nssm = Ensure-Nssm -Hint $NssmExe
$script = Join-Path $bridge "mt5_bridge.py"
$config = Join-Path $bridge $ConfigName
$logDir = Join-Path $bridge "logs"

if (-not (Test-Path $config)) {
  $example = Join-Path (Split-Path $PSScriptRoot -Parent) "windows-server\config.windows-server.json.example"
  if (-not (Test-Path $example)) {
    $example = Join-Path $PSScriptRoot "config.windows-server.json.example"
  }
  throw @"
Missing $config

Copy and edit:
  Copy-Item '$example' '$config'
  # SAME-MACHINE: FeedUrl=http://127.0.0.1:4300  BridgeApiUrl=http://127.0.0.1:4100/v1
  # FeedToken = MT5_FEED_TOKEN from deploy\.env.prod.ip
  # BridgeToken = BRIDGE_TOKEN from deploy\.env.prod.ip
"@
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Write-Host "Bridge dir : $bridge"
Write-Host "Python     : $python"
Write-Host "Config     : $config"
Write-Host "NSSM       : $nssm"

# Remove previous registration if present
& $nssm stop $ServiceName confirm 2>$null
& $nssm remove $ServiceName confirm 2>$null

& $nssm install $ServiceName $python
if ($LASTEXITCODE -ne 0) { throw "nssm install failed" }

& $nssm set $ServiceName AppDirectory $bridge
# Quote path so spaces in BridgeDir are safe
& $nssm set $ServiceName AppParameters "`"$script`""
& $nssm set $ServiceName DisplayName "Burjex MT5 Bridge"
& $nssm set $ServiceName Description "MT5 Manager API → B-Trader ingest (ticks/candles). Survives logoff."
& $nssm set $ServiceName Start SERVICE_AUTO_START
& $nssm set $ServiceName AppStdout (Join-Path $logDir "bridge.out.log")
& $nssm set $ServiceName AppStderr (Join-Path $logDir "bridge.err.log")
& $nssm set $ServiceName AppRotateFiles 1
& $nssm set $ServiceName AppRotateBytes 5242880
& $nssm set $ServiceName AppExit Default Restart
& $nssm set $ServiceName AppRestartDelay 5000
# Allow service to see network before Docker finishes binding ports
& $nssm set $ServiceName DependOnService "com.docker.service"

Write-Host ""
Write-Host "Service installed: $ServiceName" -ForegroundColor Green
Write-Host "Logs: $logDir"
Write-Host ""
Write-Host "CUTOVER: stop the laptop / old-PC bridge BEFORE starting this service." -ForegroundColor Yellow
Write-Host "Two bridges = chaos (duplicate / fighting feed)." -ForegroundColor Yellow
Write-Host ""
Write-Host "Before start: confirm ingest health:"
Write-Host "  curl http://127.0.0.1:4300/health"
Write-Host "After start:  .\preflight-feed.ps1"
Write-Host ""

if ($Start) {
  & $nssm start $ServiceName
  Start-Sleep -Seconds 2
  & $nssm status $ServiceName
  Write-Host ""
  Write-Host "Next: .\preflight-feed.ps1" -ForegroundColor Cyan
} else {
  Write-Host "Start when ready (after laptop bridge is stopped):"
  Write-Host "  nssm start $ServiceName"
  Write-Host "  # or:  .\setup-bridge-service.ps1 -Start"
  Write-Host "  .\preflight-feed.ps1"
  Write-Host "  Get-Content '$logDir\bridge.out.log' -Wait -Tail 50"
}
