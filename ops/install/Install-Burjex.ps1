#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  Burjex full-stack bootstrap for Windows Server (C:\burjex).
  - Fresh secrets via bundled env.prod.ip
  - Same-machine fast feed: FeedUrl=http://127.0.0.1:4300
  - Does NOT touch Linux VPS 187.127.215.195
  - Always uses deploy\windows-server\*.ps1 (--env-file)
#>
param(
  [string]$PackUrl = "http://187.127.215.195:4200/_bpack_9055a418bf0f395e3a75506b/burjex-windows-pack.tgz",
  [string]$Root = "C:\burjex",
  [switch]$SkipDockerInstall,
  [switch]$SkipBridgeService
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Log = "C:\burjex-bootstrap.log"

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format o), $m
  Add-Content -Path $Log -Value $line
  Write-Host $line
}

function Assert-Admin {
  $ok = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $ok) { throw "Run elevated Administrator PowerShell." }
}

function Enable-WinRmBasic {
  Log "Enabling WinRM (for future remote automation)..."
  try {
    winrm quickconfig -q -force 2>$null | Out-Null
  } catch {}
  try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
    $rule = Get-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -ErrorAction SilentlyContinue
    if (-not $rule) {
      New-NetFirewallRule -Name "WINRM-HTTP-In-TCP-Burjex" -DisplayName "WinRM HTTP Burjex" `
        -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow | Out-Null
    } else {
      Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -ErrorAction SilentlyContinue
    }
    # Allow from any for bring-up (tighten later)
    Set-Item WSMan:\localhost\Service\RootSDDL -Value (Get-Item WSMan:\localhost\Service\RootSDDL).Value -ErrorAction SilentlyContinue
    Log "WinRM enabled on :5985"
  } catch {
    Log "WinRM enable warning: $($_.Exception.Message)"
  }
}

function Install-Prereqs {
  Log "Installing prerequisites (Python, VC redist, NSSM) via winget/choco where available..."

  # Python 3.12
  $py = Get-Command python -ErrorAction SilentlyContinue
  $needPy = $true
  if ($py) {
    try {
      $v = & python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
      if ($v -match '^3\.(10|11|12)$') { $needPy = $false; Log "Python OK: $v" }
    } catch {}
  }
  if ($needPy) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
      choco install python312 -y --no-progress
    } else {
      Log "WARN: Install Python 3.12 x64 manually (Add to PATH)."
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
  }

  # VC++ redistributable
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Microsoft.VCRedist.2015+.x64 --accept-package-agreements --accept-source-agreements --silent 2>$null
  }

  # NSSM
  $nssmDir = Join-Path $PSScriptRoot "tools\nssm"
  $nssmExe = Join-Path $Root "deploy\windows-server\tools\nssm\nssm.exe"
  if (-not (Test-Path $nssmExe)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $nssmExe) | Out-Null
    $zip = Join-Path $env:TEMP "nssm.zip"
    try {
      Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -UseBasicParsing
      Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP "nssm-extract") -Force
      $src = Get-ChildItem (Join-Path $env:TEMP "nssm-extract") -Recurse -Filter nssm.exe |
        Where-Object { $_.FullName -match "win64" } | Select-Object -First 1
      if ($src) { Copy-Item $src.FullName $nssmExe -Force; Log "NSSM installed: $nssmExe" }
    } catch {
      Log "NSSM download failed: $($_.Exception.Message) -- place nssm.exe manually later"
    }
  }
}

function Install-DockerDesktop {
  if ($SkipDockerInstall) { Log "SkipDockerInstall set"; return }
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    try {
      docker version 2>$null | Out-Null
      Log "Docker already present"
      return
    } catch {}
  }

  Log "Installing Docker Desktop (Linux containers / WSL2)..."
  # WSL + VirtualMachinePlatform
  try {
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    wsl --install --no-distribution 2>$null
    wsl --set-default-version 2 2>$null
  } catch {
    Log "WSL feature enable warning: $($_.Exception.Message)"
  }

  $installer = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
  if (-not (Test-Path $installer)) {
    Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" `
      -OutFile $installer -UseBasicParsing
  }
  Log "Running Docker Desktop installer (quiet)..."
  $p = Start-Process -FilePath $installer -ArgumentList "install","--quiet","--accept-license" -Wait -PassThru
  Log "Docker installer exit: $($p.ExitCode)"
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("Path","User")

  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Log "BLOCKED: Docker not on PATH yet -- reboot may be required, then re-run this script."
    @"
Docker Desktop install was started but docker CLI is not ready.
1) Reboot the server
2) Launch Docker Desktop once (Linux containers)
3) Re-run: powershell -ExecutionPolicy Bypass -File C:\burjex\Install-Burjex.ps1
"@ | Set-Content "C:\burjex-NEXT-STEPS.txt" -Encoding utf8
    throw "Docker not ready -- reboot and re-run bootstrap"
  }
}

function Expand-Pack {
  Log "Ensuring layout under $Root"
  New-Item -ItemType Directory -Force -Path $Root, "$Root\web\admin", "$Root\web\trader" | Out-Null

  $needFetch = -not (Test-Path "$Root\deploy\windows-server\up.ps1") -or
               -not (Test-Path "$Root\btrader") -or
               -not (Test-Path "$Root\Burjex-Prime-Crm-main")

  if ($needFetch) {
    Log "Downloading pack from $PackUrl"
    $tgz = Join-Path $env:TEMP "burjex-windows-pack.tgz"
    Invoke-WebRequest -Uri $PackUrl -OutFile $tgz -UseBasicParsing
    Log "Downloaded $((Get-Item $tgz).Length) bytes -- extracting..."
    # Prefer tar (Windows 10+/Server 2019+)
    Push-Location $Root
    tar -xzf $tgz
    Pop-Location
  } else {
    Log "Source trees already present -- skip download"
  }

  # Placeholders for Caddy static mounts
  if (-not (Test-Path "$Root\web\admin\index.html")) {
    Set-Content "$Root\web\admin\index.html" "<!doctype html><title>BTrader Admin</title><h1>Upload Flutter web build here</h1>" -Encoding utf8
  }
  if (-not (Test-Path "$Root\web\trader\index.html")) {
    Set-Content "$Root\web\trader\index.html" "<!doctype html><title>BTrader</title><h1>Upload Flutter web build here</h1>" -Encoding utf8
  }

  # Env + credentials from same pack directory as this script OR from downloaded sidecar
  $envSrc = Join-Path $PSScriptRoot "env.prod.ip"
  if (-not (Test-Path $envSrc)) { $envSrc = Join-Path $Root "deploy\.env.prod.ip.bundled" }
  if (Test-Path (Join-Path $PSScriptRoot "env.prod.ip")) {
    Copy-Item (Join-Path $PSScriptRoot "env.prod.ip") "$Root\deploy\.env.prod.ip" -Force
    Log "Installed deploy\.env.prod.ip from pack"
  }
  if (Test-Path (Join-Path $PSScriptRoot "CREDENTIALS.txt")) {
    Copy-Item (Join-Path $PSScriptRoot "CREDENTIALS.txt") "$Root\deploy\CREDENTIALS.txt" -Force
  }
  if (Test-Path (Join-Path $PSScriptRoot "bridge.config.json")) {
    $bridgeDir = "$Root\btrader\bridges\mt5-manager-python"
    New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
    Copy-Item (Join-Path $PSScriptRoot "bridge.config.json") "$bridgeDir\config.json" -Force
    Log "Installed bridge config.json (FeedUrl=http://127.0.0.1:4300)"
  }
}

function Open-Firewall {
  $fw = Join-Path $Root "deploy\windows-server\open-firewall.ps1"
  if (Test-Path $fw) {
    Log "Opening Windows Firewall ports..."
    & $fw
  }
}

function Start-Stack {
  $up = Join-Path $Root "deploy\windows-server\up.ps1"
  if (-not (Test-Path $up)) { throw "Missing $up" }
  Log "Starting Docker stack via up.ps1 (--env-file enforced)..."
  Push-Location (Split-Path $up)
  & $up
  Pop-Location
}

function Wait-Healthy {
  Log "Waiting for health endpoints..."
  $deadline = (Get-Date).AddMinutes(45)
  $ok4300 = $false
  $ok8000 = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:4300/health" -UseBasicParsing -TimeoutSec 5
      if ($r.StatusCode -eq 200) { $ok4300 = $true }
    } catch {}
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:8000/health/ready/" -UseBasicParsing -TimeoutSec 5
      if ($r.StatusCode -eq 200) { $ok8000 = $true }
    } catch {}
    if ($ok4300 -and $ok8000) { Log "Health OK: :4300 and :8000"; return }
    Start-Sleep -Seconds 15
  }
  Log "Health wait finished -- 4300=$ok4300 8000=$ok8000 (may still be building)"
}

function Bootstrap-Db {
  Log "DB bootstrap: prisma seed + CRM superuser (best effort)..."
  Push-Location (Join-Path $Root "deploy\windows-server")
  . .\_compose.ps1
  try {
    Invoke-BurjexCompose -ComposeArgs @(
      "run","--rm","btrader-gateway",
      "sh","-lc","cd /app/packages/db && npx prisma db push --skip-generate && npx prisma db seed"
    )
  } catch { Log "prisma seed warning: $($_.Exception.Message)" }

  # CRM superuser -- read from CREDENTIALS if present
  $credFile = Join-Path $Root "deploy\CREDENTIALS.txt"
  $user = "admin"
  $pass = $null
  if (Test-Path $credFile) {
    $txt = Get-Content $credFile -Raw
    if ($txt -match 'User:\s+(\S+)') { $user = $Matches[1] }
    if ($txt -match '(?m)^Pass:\s+(\S+)') { $pass = $Matches[1] }
  }
  if ($pass) {
    $py = @"
import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE','config.settings')
import django
django.setup()
from django.contrib.auth import get_user_model
U=get_user_model()
u,created=U.objects.get_or_create(username='$user', defaults={'is_staff':True,'is_superuser':True,'email':'admin@burjex.local'})
u.set_password('$pass')
u.is_staff=True; u.is_superuser=True; u.save()
print('superuser', u.username, 'created' if created else 'updated')
"@
    $py = $py -replace "`r",""
    try {
      Invoke-BurjexCompose -ComposeArgs @("exec","-T","crm-web","python","-c", $py)
    } catch { Log "createsuperuser warning: $($_.Exception.Message)" }
  }
  Pop-Location
}

function Setup-Bridge {
  if ($SkipBridgeService) { Log "SkipBridgeService set"; return }
  $bridgeDir = Join-Path $Root "btrader\bridges\mt5-manager-python"
  Log "Installing Python deps for MT5 bridge..."
  Push-Location $bridgeDir
  try {
    python -m pip install -r requirements.txt
    python -c "import MT5Manager; print('MT5Manager OK')"
  } catch {
    Log "MT5Manager import/install issue (MT5 terminal may be missing): $($_.Exception.Message)"
  }
  Pop-Location

  # Detect MT5
  $mt5 = @(
    "C:\Program Files\MetaTrader 5\terminal64.exe",
    "C:\Program Files (x86)\MetaTrader 5\terminal64.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1

  $setup = Join-Path $Root "deploy\windows-server\setup-bridge-service.ps1"
  if ($mt5) {
    Log "MT5 found: $mt5 -- installing NSSM service"
    & $setup -Start
  } else {
    Log "MT5 Terminal NOT installed -- preparing service config without Start"
    try { & $setup } catch { Log "setup-bridge-service (no start): $($_.Exception.Message)" }
    @"
NEXT HUMAN STEPS -- MT5
1) Install MetaTrader 5 Terminal / Manager API build for your broker on this server
2) Log in once interactively if required
3) Verify: python C:\burjex\btrader\bridges\mt5-manager-python\mt5_bridge.py
4) STOP laptop bridge completely (mandatory -- two bridges = chaos)
5) Elevated: cd C:\burjex\deploy\windows-server; .\setup-bridge-service.ps1 -Start
6) .\preflight-feed.ps1 -- lastTickAt must be fresh
"@ | Set-Content "C:\burjex-MT5-NEXT.txt" -Encoding utf8
    Log "Wrote C:\burjex-MT5-NEXT.txt"
  }
}

function Run-Preflight {
  $pf = Join-Path $Root "deploy\windows-server\preflight-feed.ps1"
  if (Test-Path $pf) {
    Log "Running preflight-feed.ps1..."
    try { & $pf } catch { Log "preflight: $($_.Exception.Message)" }
  }
}

# --- main -------------------------------------------------------------------
Assert-Admin
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Log "=== Burjex Windows bootstrap start ==="
Enable-WinRmBasic
Expand-Pack
Install-Prereqs
Install-DockerDesktop
Open-Firewall
Start-Stack
Wait-Healthy
Bootstrap-Db
Setup-Bridge
Run-Preflight
Log "=== Bootstrap finished ==="
Log "CREDENTIALS: C:\burjex\deploy\CREDENTIALS.txt"
Log "Do NOT stop old VPS. Do NOT point laptop bridge at this IP until cutover."
Log "CHANGE Administrator password now."
